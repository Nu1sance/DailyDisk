import DailyDiskCore
import Foundation

public struct VolumeCapacityHints: Equatable, Sendable {
    public let importantUsageAvailableBytes: Int64?
    public let opportunisticUsageAvailableBytes: Int64?

    public init(importantUsageAvailableBytes: Int64?, opportunisticUsageAvailableBytes: Int64?) {
        self.importantUsageAvailableBytes = importantUsageAvailableBytes
        self.opportunisticUsageAvailableBytes = opportunisticUsageAvailableBytes
    }
}

public protocol VolumeCapacityHintProviding: Sendable {
    func capacityHints(mountPath: String) throws -> VolumeCapacityHints
}

public struct FoundationVolumeCapacityHintProvider: VolumeCapacityHintProviding {
    public init() {}

    public func capacityHints(mountPath: String) throws -> VolumeCapacityHints {
        let values = try URL(fileURLWithPath: mountPath).resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityForOpportunisticUsageKey,
        ])
        return VolumeCapacityHints(
            importantUsageAvailableBytes: values.volumeAvailableCapacityForImportantUsage.map { Int64($0) },
            opportunisticUsageAvailableBytes: values.volumeAvailableCapacityForOpportunisticUsage.map { Int64($0) }
        )
    }
}

public struct APFSDiskUsageSampler: DiskUsageSampling {
    private let processRunner: any ProcessRunning
    private let diskArbitration: any DiskArbitrationProviding
    private let capacityHints: any VolumeCapacityHintProviding
    private let snapshotProvider: any SnapshotProviding
    private let diskutilURL: URL
    private let now: @Sendable () -> Date

    public init(
        processRunner: any ProcessRunning = SystemProcessRunner(),
        diskArbitration: any DiskArbitrationProviding = SystemDiskArbitrationAdapter(),
        capacityHints: any VolumeCapacityHintProviding = FoundationVolumeCapacityHintProvider(),
        snapshotProvider: any SnapshotProviding = APFSSnapshotProvider(),
        diskutilURL: URL = URL(fileURLWithPath: "/usr/sbin/diskutil"),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.processRunner = processRunner
        self.diskArbitration = diskArbitration
        self.capacityHints = capacityHints
        self.snapshotProvider = snapshotProvider
        self.diskutilURL = diskutilURL
        self.now = now
    }

    public func sample(storageDomain: StorageDomain) async throws -> StorageSample {
        let result = try await processRunner.run(
            ProcessRequest(executableURL: diskutilURL, arguments: ["apfs", "list", "-plist"])
        )
        let data = try result.requireSuccess(executable: diskutilURL.path)
        let parsed = try DiskutilAPFSParser.parse(data)
        guard
            let container = parsed.containers.first(where: {
                $0.uuid.uuidString.caseInsensitiveCompare(storageDomain.id.rawValue) == .orderedSame
            })
        else {
            throw APFSDiscoveryError.storageDomainNotFound(storageDomain.id)
        }

        let usedBytes = try AccountingMath.subtract(container.capacityBytes, container.freeBytes)
        let mounted = try await diskArbitration.mountedVolumes()
        let preferredDevices = container.volumes
            .sorted { lhs, rhs in
                let lhsRank = lhs.roles.contains { $0.caseInsensitiveCompare("Data") == .orderedSame } ? 0 : 1
                let rhsRank = rhs.roles.contains { $0.caseInsensitiveCompare("Data") == .orderedSame } ? 0 : 1
                return (lhsRank, lhs.uuid.uuidString) < (rhsRank, rhs.uuid.uuidString)
            }
            .map(\.deviceIdentifier)
        let eligibleMounts = mounted.filter {
            $0.filesystemKind?.lowercased() == "apfs" && $0.isInternal && !$0.isRemovable
        }
        let preferredSet = Set(preferredDevices)
        let startupDataMount = eligibleMounts.first {
            $0.mountPath == "/System/Volumes/Data" && preferredSet.contains($0.bsdName)
        }
        let mount =
            startupDataMount
            ?? preferredDevices.lazy.compactMap { device in
                eligibleMounts.first(where: { $0.bsdName == device })
            }.first
        let hints: VolumeCapacityHints
        if let mount {
            hints =
                (try? capacityHints.capacityHints(mountPath: mount.mountPath))
                ?? VolumeCapacityHints(importantUsageAvailableBytes: nil, opportunisticUsageAvailableBytes: nil)
        } else {
            hints = VolumeCapacityHints(importantUsageAvailableBytes: nil, opportunisticUsageAvailableBytes: nil)
        }

        return try StorageSample(
            storageDomainID: storageDomain.id,
            sampledAt: now(),
            capacityBytes: container.capacityBytes,
            usedBytes: usedBytes,
            availableBytes: container.freeBytes,
            importantUsageAvailableBytes: hints.importantUsageAvailableBytes,
            opportunisticUsageAvailableBytes: hints.opportunisticUsageAvailableBytes
        )
    }

    public func snapshots(volume: MonitoredVolume) async throws -> [SnapshotSample] {
        try await snapshotProvider.snapshots(volume: volume)
    }
}
