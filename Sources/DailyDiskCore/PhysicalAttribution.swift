import Foundation

public struct DeletedOpenFile: Codable, Equatable, Sendable {
    public let processID: Int32
    public let command: String
    public let fileDescriptor: String
    public let device: String
    public let inode: String
    public let logicalBytes: Int64
    public let path: String

    public init(
        processID: Int32,
        command: String,
        fileDescriptor: String,
        device: String,
        inode: String,
        logicalBytes: Int64,
        path: String
    ) throws {
        guard logicalBytes >= 0 else { throw ModelValidationError.negativeByteCount }
        self.processID = processID
        self.command = command
        self.fileDescriptor = fileDescriptor
        self.device = device
        self.inode = inode
        self.logicalBytes = logicalBytes
        self.path = path
    }

    public var identityKey: String { "\(device):\(inode)" }

    public var nativeDeviceID: UInt64? {
        if device.lowercased().hasPrefix("0x") {
            return UInt64(device.dropFirst(2), radix: 16)
        }
        return UInt64(device)
    }
}

public struct DailyDiskOverheadSample: Codable, Equatable, Sendable {
    public let storageDomainID: StorageDomain.ID
    public let sampledAt: Date
    public let allocatedBytes: Int64

    public init(
        storageDomainID: StorageDomain.ID,
        sampledAt: Date,
        allocatedBytes: Int64
    ) throws {
        guard allocatedBytes >= 0 else { throw ModelValidationError.negativeByteCount }
        self.storageDomainID = storageDomainID
        self.sampledAt = sampledAt
        self.allocatedBytes = allocatedBytes
    }
}

public enum PhysicalAttributionCause: String, Codable, CaseIterable, Hashable, Sendable {
    case snapshotSetChanged
    case deletedOpenFiles
    case inaccessiblePaths
    case apfsSharedBlocksOrMetadata
}

public struct PhysicalAttributionDiagnosis: Codable, Equatable, Sendable {
    public let physicalUnattributedDelta: Int64?
    public let snapshotCountDelta: Int
    public let uniqueDeletedOpenLogicalBytes: Int64
    public let unreadablePathCount: UInt64
    public let likelyCauses: [PhysicalAttributionCause]
    public let notes: [String]

    public init(
        physicalUnattributedDelta: Int64?,
        snapshotCountDelta: Int,
        uniqueDeletedOpenLogicalBytes: Int64,
        unreadablePathCount: UInt64,
        likelyCauses: [PhysicalAttributionCause],
        notes: [String]
    ) {
        self.physicalUnattributedDelta = physicalUnattributedDelta
        self.snapshotCountDelta = snapshotCountDelta
        self.uniqueDeletedOpenLogicalBytes = uniqueDeletedOpenLogicalBytes
        self.unreadablePathCount = unreadablePathCount
        self.likelyCauses = likelyCauses
        self.notes = notes
    }
}

public struct PhysicalDiagnosticsCoordinator: Sendable {
    private let deletedOpenFileProbe: any DeletedOpenFileProbing

    public init(deletedOpenFileProbe: any DeletedOpenFileProbing) {
        self.deletedOpenFileProbe = deletedOpenFileProbe
    }

    public func diagnose(
        accounting: AccountingSummary,
        scope: StorageDomainScope,
        previousSnapshots: [SnapshotSample],
        currentSnapshots: [SnapshotSample],
        unreadablePathCount: UInt64
    ) async throws -> PhysicalAttributionDiagnosis {
        let openFiles = try await deletedOpenFileProbe.deletedOpenFiles()
        return try PhysicalAttribution.analyze(
            accounting: accounting,
            previousSnapshots: previousSnapshots,
            currentSnapshots: currentSnapshots,
            deletedOpenFiles: openFiles,
            monitoredDeviceIDs: Set(scope.volumes.map(\.deviceID).filter { $0 != 0 }),
            unreadablePathCount: unreadablePathCount
        )
    }
}

public enum PhysicalAttribution {
    public static func analyze(
        accounting: AccountingSummary,
        previousSnapshots: [SnapshotSample],
        currentSnapshots: [SnapshotSample],
        deletedOpenFiles: [DeletedOpenFile],
        monitoredDeviceIDs: Set<UInt64>,
        unreadablePathCount: UInt64
    ) throws -> PhysicalAttributionDiagnosis {
        let previousIDs = Set(previousSnapshots.map(snapshotIdentity))
        let currentIDs = Set(currentSnapshots.map(snapshotIdentity))
        let snapshotCountDelta = currentIDs.count - previousIDs.count

        var uniqueOpenSizes: [String: Int64] = [:]
        for file in deletedOpenFiles where file.nativeDeviceID.map(monitoredDeviceIDs.contains) == true {
            uniqueOpenSizes[file.identityKey] = max(uniqueOpenSizes[file.identityKey] ?? 0, file.logicalBytes)
        }
        let deletedBytes = try AccountingMath.sum(uniqueOpenSizes.values)
        var causes: [PhysicalAttributionCause] = []
        var notes: [String] = []
        if previousIDs != currentIDs {
            causes.append(.snapshotSetChanged)
            notes.append("APFS snapshot membership changed; shared snapshot blocks cannot be summed safely")
        }
        if deletedBytes > 0 {
            causes.append(.deletedOpenFiles)
            notes.append("Deleted files are still held open; logical size is an estimate, not unique APFS blocks")
        }
        if unreadablePathCount > 0 {
            causes.append(.inaccessiblePaths)
            notes.append("Some paths were inaccessible and cannot be assigned to ordinary inventory")
        }
        if accounting.physicalUnattributedDelta != nil,
            accounting.physicalUnattributedDelta != 0
        {
            causes.append(.apfsSharedBlocksOrMetadata)
            notes.append("Remaining difference may include APFS clones, shared extents, metadata, or purgeable space")
        }
        return PhysicalAttributionDiagnosis(
            physicalUnattributedDelta: accounting.physicalUnattributedDelta,
            snapshotCountDelta: snapshotCountDelta,
            uniqueDeletedOpenLogicalBytes: deletedBytes,
            unreadablePathCount: unreadablePathCount,
            likelyCauses: Array(Set(causes)).sorted { $0.rawValue < $1.rawValue },
            notes: notes
        )
    }

    private static func snapshotIdentity(_ sample: SnapshotSample) -> String {
        "\(sample.volumeID.rawValue):\(sample.snapshotUUID?.uuidString ?? sample.name)"
    }
}
