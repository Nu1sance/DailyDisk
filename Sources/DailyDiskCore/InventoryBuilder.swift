import Foundation

public struct InventoryMetadata: Equatable, Sendable {
    public let deviceID: UInt64
    public let inode: UInt64
    public let kind: FileKind
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let linkCount: UInt64
    public let modifiedAt: Date?
    public let metadataChangedAt: Date?

    public init(
        deviceID: UInt64,
        inode: UInt64,
        kind: FileKind,
        logicalBytes: Int64,
        allocatedBytes: Int64,
        linkCount: UInt64,
        modifiedAt: Date?,
        metadataChangedAt: Date?
    ) throws {
        guard logicalBytes >= 0, allocatedBytes >= 0 else {
            throw ModelValidationError.negativeByteCount
        }
        self.deviceID = deviceID
        self.inode = inode
        self.kind = kind
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.linkCount = linkCount
        self.modifiedAt = modifiedAt
        self.metadataChangedAt = metadataChangedAt
    }
}

public enum InventoryBuilder {
    public static func makeRecord(
        volumeID: MonitoredVolume.ID,
        path: RelativePath,
        metadata: InventoryMetadata,
        classification: InventoryClassification
    ) throws -> InventoryRecord {
        let identity = FileIdentity(
            volumeID: volumeID,
            deviceID: metadata.deviceID,
            inode: metadata.inode
        )
        let object = InventoryObject(
            identity: identity,
            kind: metadata.kind,
            footprint: try FileFootprint(
                logicalBytes: metadata.logicalBytes,
                allocatedBytes: metadata.allocatedBytes
            ),
            linkCount: metadata.linkCount,
            modifiedAt: metadata.modifiedAt,
            metadataChangedAt: metadata.metadataChangedAt
        )
        let inventoryPath = try InventoryPath(
            volumeID: volumeID,
            relativePath: path,
            parentPath: PathPolicy.parent(of: path),
            objectIdentity: identity,
            classification: classification
        )
        return try InventoryRecord(object: object, path: inventoryPath)
    }
}
