import DailyDiskCore
import Darwin
import Foundation

public struct DailyDiskOverheadSampler: DailyDiskOverheadSampling {
    private let processRunner: any ProcessRunning
    private let rootURL: URL
    private let duURL: URL
    private let volumeDiscovery: any VolumeDiscovering
    private let now: @Sendable () -> Date

    public init(
        processRunner: any ProcessRunning = SystemProcessRunner(),
        rootURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DailyDisk", isDirectory: true),
        duURL: URL = URL(fileURLWithPath: "/usr/bin/du"),
        volumeDiscovery: any VolumeDiscovering = APFSVolumeProvider(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.processRunner = processRunner
        self.rootURL = rootURL
        self.duURL = duURL
        self.volumeDiscovery = volumeDiscovery
        self.now = now
    }

    public func sample(storageDomainID: StorageDomain.ID) async throws -> DailyDiskOverheadSample {
        let topology = try await volumeDiscovery.discoverInternalAPFSVolumes()
        let rootDeviceID = try actualDeviceID(for: rootURL)
        let owningVolume = topology.volumes.first {
            $0.inventoryMode == .full && $0.deviceID == rootDeviceID
        }
        guard owningVolume?.storageDomainID == storageDomainID else {
            throw DailyDiskOverheadError.rootOutsideStorageDomain(storageDomainID)
        }
        guard FileManager.default.fileExists(atPath: rootURL.path) else {
            return try DailyDiskOverheadSample(
                storageDomainID: storageDomainID,
                sampledAt: now(),
                allocatedBytes: 0
            )
        }
        let result = try await processRunner.run(
            ProcessRequest(
                executableURL: duURL,
                arguments: ["-sk", rootURL.path],
                timeoutSeconds: 30
            )
        )
        let data = try result.requireSuccess(executable: duURL.path)
        guard let firstLine = String(data: data, encoding: .utf8)?.split(separator: "\n").first,
            let blockString = firstLine.split(whereSeparator: { $0 == "\t" || $0 == " " }).first,
            let kibibytes = Int64(blockString),
            kibibytes >= 0
        else {
            throw DailyDiskOverheadError.invalidDUOutput
        }
        return try DailyDiskOverheadSample(
            storageDomainID: storageDomainID,
            sampledAt: now(),
            allocatedBytes: AccountingMath.multiply(kibibytes, 1_024)
        )
    }

    private func actualDeviceID(for url: URL) throws -> UInt64 {
        var candidate = url
        while !FileManager.default.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else {
                throw DailyDiskOverheadError.cannotResolveRoot
            }
            candidate = parent
        }
        let resolved = candidate.resolvingSymlinksInPath()
        var status = Darwin.stat()
        guard stat(resolved.path, &status) == 0 else {
            throw DailyDiskOverheadError.cannotResolveRoot
        }
        return UInt64(UInt32(bitPattern: status.st_dev))
    }
}

public enum DailyDiskOverheadError: Error, Equatable, Sendable {
    case invalidDUOutput
    case rootOutsideStorageDomain(StorageDomain.ID)
    case cannotResolveRoot
}
