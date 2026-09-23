import Foundation

// MARK: - Storage topology

public struct StorageDomain: Codable, Hashable, Sendable {
    public struct ID: Codable, Hashable, Sendable, CustomStringConvertible {
        public let rawValue: String

        public init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue }
    }

    public let id: ID
    public let containerIdentifier: String
    public let displayName: String
    public let isInternal: Bool

    public init(id: ID, containerIdentifier: String, displayName: String, isInternal: Bool) {
        self.id = id
        self.containerIdentifier = containerIdentifier
        self.displayName = displayName
        self.isInternal = isInternal
    }
}

public enum VolumeInventoryMode: String, Codable, CaseIterable, Sendable {
    case full
    case metricsOnly
}

public enum VolumeRole: String, Codable, CaseIterable, Sendable {
    case data
    case system
    case vm
    case preboot
    case recovery
    case update
    case hardware
    case unknown
}

public struct MonitoredVolume: Codable, Hashable, Sendable {
    public struct ID: Codable, Hashable, Sendable, CustomStringConvertible {
        public let rawValue: String

        public init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue }
    }

    public let id: ID
    public let storageDomainID: StorageDomain.ID
    public let filesystemUUID: UUID?
    public let volumeGroupUUID: UUID?
    public let eventStoreUUID: UUID?
    public let deviceID: UInt64
    public let mountPath: String?
    public let displayName: String
    public let role: VolumeRole
    public let isInternal: Bool
    public let isRemovable: Bool
    public let isReadOnly: Bool
    public let supportsPersistentEvents: Bool
    public let topologyFingerprint: String
    public let inventoryMode: VolumeInventoryMode

    public init(
        id: ID,
        storageDomainID: StorageDomain.ID,
        filesystemUUID: UUID?,
        volumeGroupUUID: UUID? = nil,
        eventStoreUUID: UUID?,
        deviceID: UInt64,
        mountPath: String?,
        displayName: String,
        role: VolumeRole,
        isInternal: Bool,
        isRemovable: Bool,
        isReadOnly: Bool,
        supportsPersistentEvents: Bool,
        topologyFingerprint: String,
        inventoryMode: VolumeInventoryMode = .full
    ) {
        self.id = id
        self.storageDomainID = storageDomainID
        self.filesystemUUID = filesystemUUID
        self.volumeGroupUUID = volumeGroupUUID
        self.eventStoreUUID = eventStoreUUID
        self.deviceID = deviceID
        self.mountPath = mountPath
        self.displayName = displayName
        self.role = role
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isReadOnly = isReadOnly
        self.supportsPersistentEvents = supportsPersistentEvents
        self.topologyFingerprint = topologyFingerprint
        self.inventoryMode = inventoryMode
    }
}

public struct StorageDomainScope: Codable, Equatable, Sendable {
    public let domain: StorageDomain
    public let volumes: [MonitoredVolume]

    public var volumeIDs: Set<MonitoredVolume.ID> { Set(volumes.map(\.id)) }

    public init(domain: StorageDomain, volumes: [MonitoredVolume]) throws {
        guard !volumes.isEmpty,
            volumes.allSatisfy({ $0.storageDomainID == domain.id }),
            Set(volumes.map(\.id)).count == volumes.count,
            volumes.filter({ $0.inventoryMode == .full }).count <= 1
        else {
            throw ModelValidationError.mismatchedStorageDomain
        }
        self.domain = domain
        self.volumes = volumes
    }

    private enum CodingKeys: String, CodingKey {
        case domain
        case volumes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            domain: container.decode(StorageDomain.self, forKey: .domain),
            volumes: container.decode([MonitoredVolume].self, forKey: .volumes)
        )
    }
}

public struct VolumeTopology: Codable, Equatable, Sendable {
    public let domains: [StorageDomain]
    public let volumes: [MonitoredVolume]
    public let discoveredAt: Date
    public let diagnostics: [String]

    public init(
        domains: [StorageDomain],
        volumes: [MonitoredVolume],
        discoveredAt: Date,
        diagnostics: [String] = []
    ) {
        self.domains = domains
        self.volumes = volumes
        self.discoveredAt = discoveredAt
        self.diagnostics = diagnostics
    }
}

// MARK: - Inventory

public struct RelativePath: Codable, Hashable, Sendable, CustomStringConvertible {
    public let bytes: Data

    public init(validating bytes: Data) throws {
        try PathPolicy.validate(relativePathBytes: bytes)
        self.bytes = bytes
    }

    public init(validating string: String) throws {
        try self.init(validating: Data(string.utf8))
    }

    private enum CodingKeys: String, CodingKey {
        case bytes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(validating: container.decode(Data.self, forKey: .bytes))
    }

    public static let root = try! RelativePath(validating: Data())

    public var displayString: String {
        bytes.isEmpty ? "." : String(decoding: bytes, as: UTF8.self)
    }

    public var description: String { displayString }
}

public enum FileKind: String, Codable, CaseIterable, Sendable {
    case regular
    case directory
    case symbolicLink
    case socket
    case fifo
    case characterDevice
    case blockDevice
    case unknown
}

public enum InventoryClassification: String, Codable, CaseIterable, Sendable {
    case ordinary
    case dailyDiskInternal
}

public struct FileIdentity: Codable, Hashable, Sendable {
    public let volumeID: MonitoredVolume.ID
    public let deviceID: UInt64
    public let inode: UInt64

    public init(volumeID: MonitoredVolume.ID, deviceID: UInt64, inode: UInt64) {
        self.volumeID = volumeID
        self.deviceID = deviceID
        self.inode = inode
    }
}

public struct FileFootprint: Codable, Equatable, Sendable {
    public let logicalBytes: Int64
    public let allocatedBytes: Int64

    public init(logicalBytes: Int64, allocatedBytes: Int64) throws {
        guard logicalBytes >= 0, allocatedBytes >= 0 else {
            throw ModelValidationError.negativeByteCount
        }
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
    }

    private enum CodingKeys: String, CodingKey {
        case logicalBytes
        case allocatedBytes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            logicalBytes: container.decode(Int64.self, forKey: .logicalBytes),
            allocatedBytes: container.decode(Int64.self, forKey: .allocatedBytes)
        )
    }

    public static let zero = try! FileFootprint(logicalBytes: 0, allocatedBytes: 0)
}

public struct InventoryObject: Codable, Equatable, Sendable {
    public let identity: FileIdentity
    public let kind: FileKind
    public let footprint: FileFootprint
    public let linkCount: UInt64
    public let modifiedAt: Date?
    public let metadataChangedAt: Date?

    public init(
        identity: FileIdentity,
        kind: FileKind,
        footprint: FileFootprint,
        linkCount: UInt64,
        modifiedAt: Date?,
        metadataChangedAt: Date?
    ) {
        self.identity = identity
        self.kind = kind
        self.footprint = footprint
        self.linkCount = linkCount
        self.modifiedAt = modifiedAt
        self.metadataChangedAt = metadataChangedAt
    }
}

public struct InventoryPath: Codable, Hashable, Sendable {
    public let volumeID: MonitoredVolume.ID
    public let relativePath: RelativePath
    public let parentPath: RelativePath?
    public let objectIdentity: FileIdentity
    public let classification: InventoryClassification

    public init(
        volumeID: MonitoredVolume.ID,
        relativePath: RelativePath,
        parentPath: RelativePath?,
        objectIdentity: FileIdentity,
        classification: InventoryClassification = .ordinary
    ) throws {
        guard objectIdentity.volumeID == volumeID else {
            throw ModelValidationError.inconsistentVolume
        }
        guard PathPolicy.parent(of: relativePath) == parentPath else {
            throw ModelValidationError.inconsistentParentPath
        }
        self.volumeID = volumeID
        self.relativePath = relativePath
        self.parentPath = parentPath
        self.objectIdentity = objectIdentity
        self.classification = classification
    }

    private enum CodingKeys: String, CodingKey {
        case volumeID
        case relativePath
        case parentPath
        case objectIdentity
        case classification
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            volumeID: container.decode(MonitoredVolume.ID.self, forKey: .volumeID),
            relativePath: container.decode(RelativePath.self, forKey: .relativePath),
            parentPath: container.decodeIfPresent(RelativePath.self, forKey: .parentPath),
            objectIdentity: container.decode(FileIdentity.self, forKey: .objectIdentity),
            classification: container.decode(InventoryClassification.self, forKey: .classification)
        )
    }
}

public struct InventoryRecord: Codable, Equatable, Sendable {
    public let object: InventoryObject
    public let path: InventoryPath

    public init(object: InventoryObject, path: InventoryPath) throws {
        guard object.identity == path.objectIdentity else {
            throw ModelValidationError.inconsistentObjectIdentity
        }
        self.object = object
        self.path = path
    }

    private enum CodingKeys: String, CodingKey {
        case object
        case path
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            object: container.decode(InventoryObject.self, forKey: .object),
            path: container.decode(InventoryPath.self, forKey: .path)
        )
    }
}

// MARK: - Runs and checkpoints

public struct ScanRun: Codable, Equatable, Sendable {
    public struct ID: Codable, Hashable, Sendable, CustomStringConvertible {
        public let rawValue: UUID

        public init(_ rawValue: UUID = UUID()) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue.uuidString }
    }

    public enum Kind: String, Codable, CaseIterable, Sendable {
        case incremental
        case full
        case recovery
    }

    public enum Status: String, Codable, CaseIterable, Sendable {
        case running
        case succeeded
        case failed
        case interrupted
    }

    public enum Reason: String, Codable, CaseIterable, Sendable {
        case initialBaseline
        case dailySchedule
        case weeklyReconciliation
        case eventHistoryLost
        case eventStoreChanged
        case topologyChanged
        case inventoryDrift
        case manual
    }

    public let id: ID
    public let kind: Kind
    public let reason: Reason
    public let status: Status
    public let startedAt: Date
    public let finishedAt: Date?
    public let errorCount: Int

    public init(
        id: ID = ID(),
        kind: Kind,
        reason: Reason,
        status: Status,
        startedAt: Date,
        finishedAt: Date? = nil,
        errorCount: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.reason = reason
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.errorCount = errorCount
    }
}

public struct InventoryGeneration: Codable, Equatable, Sendable {
    public struct ID: Codable, Hashable, Sendable, CustomStringConvertible {
        public let rawValue: UUID

        public init(_ rawValue: UUID = UUID()) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue.uuidString }
    }

    public enum State: String, Codable, CaseIterable, Sendable {
        case staging
        case active
        case retired
    }

    public let id: ID
    public let volumeID: MonitoredVolume.ID
    public let createdByRunID: ScanRun.ID
    public let state: State
    public let createdAt: Date

    public init(
        id: ID = ID(),
        volumeID: MonitoredVolume.ID,
        createdByRunID: ScanRun.ID,
        state: State,
        createdAt: Date
    ) {
        self.id = id
        self.volumeID = volumeID
        self.createdByRunID = createdByRunID
        self.state = state
        self.createdAt = createdAt
    }
}

public struct Checkpoint: Codable, Equatable, Sendable {
    public let volumeID: MonitoredVolume.ID
    public let eventStoreUUID: UUID?
    public let lastCommittedEventID: UInt64?
    public let activeGenerationID: InventoryGeneration.ID
    public let topologyFingerprint: String
    public let lastSuccessfulIncrementalAt: Date?
    public let lastSuccessfulFullScanAt: Date

    public init(
        volumeID: MonitoredVolume.ID,
        eventStoreUUID: UUID?,
        lastCommittedEventID: UInt64?,
        activeGenerationID: InventoryGeneration.ID,
        topologyFingerprint: String,
        lastSuccessfulIncrementalAt: Date?,
        lastSuccessfulFullScanAt: Date
    ) {
        self.volumeID = volumeID
        self.eventStoreUUID = eventStoreUUID
        self.lastCommittedEventID = lastCommittedEventID
        self.activeGenerationID = activeGenerationID
        self.topologyFingerprint = topologyFingerprint
        self.lastSuccessfulIncrementalAt = lastSuccessfulIncrementalAt
        self.lastSuccessfulFullScanAt = lastSuccessfulFullScanAt
    }
}

// MARK: - Filesystem events

public struct EventStreamCheckpoint: Codable, Equatable, Sendable {
    public let eventStoreUUID: UUID
    public let lastEventID: UInt64?

    public init(eventStoreUUID: UUID, lastEventID: UInt64?) {
        self.eventStoreUUID = eventStoreUUID
        self.lastEventID = lastEventID
    }
}

public struct FileSystemEventFlags: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    // Values intentionally match FSEventStreamEventFlags in CoreServices so
    // unknown native bits can survive persistence and later reprocessing.
    public static let mustScanSubdirectories = Self(rawValue: 0x0000_0001)
    public static let userDropped = Self(rawValue: 0x0000_0002)
    public static let kernelDropped = Self(rawValue: 0x0000_0004)
    public static let eventIDsWrapped = Self(rawValue: 0x0000_0008)
    public static let historyDone = Self(rawValue: 0x0000_0010)
    public static let rootChanged = Self(rawValue: 0x0000_0020)
    public static let mounted = Self(rawValue: 0x0000_0040)
    public static let unmounted = Self(rawValue: 0x0000_0080)
    public static let created = Self(rawValue: 0x0000_0100)
    public static let removed = Self(rawValue: 0x0000_0200)
    public static let inodeMetadataModified = Self(rawValue: 0x0000_0400)
    public static let renamed = Self(rawValue: 0x0000_0800)
    public static let modified = Self(rawValue: 0x0000_1000)
    public static let finderInfoModified = Self(rawValue: 0x0000_2000)
    public static let ownerChanged = Self(rawValue: 0x0000_4000)
    public static let extendedAttributesModified = Self(rawValue: 0x0000_8000)
    public static let isFile = Self(rawValue: 0x0001_0000)
    public static let isDirectory = Self(rawValue: 0x0002_0000)
    public static let isSymbolicLink = Self(rawValue: 0x0004_0000)
    public static let ownEvent = Self(rawValue: 0x0008_0000)
    public static let isHardLink = Self(rawValue: 0x0010_0000)
    public static let isLastHardLink = Self(rawValue: 0x0020_0000)
    public static let itemCloned = Self(rawValue: 0x0040_0000)
}

public struct FileSystemEvent: Codable, Hashable, Sendable {
    public let id: UInt64
    public let volumeID: MonitoredVolume.ID
    public let path: RelativePath
    public let flags: FileSystemEventFlags

    public init(id: UInt64, volumeID: MonitoredVolume.ID, path: RelativePath, flags: FileSystemEventFlags) {
        self.id = id
        self.volumeID = volumeID
        self.path = path
        self.flags = flags
    }
}

public enum EventHistoryTrust: String, Codable, Sendable {
    case trusted
    case subtreeRescanRequired
    case fullScanRequired
}

public struct EventBatch: Codable, Equatable, Sendable {
    public static let maximumEventCount = 4_096

    public let events: [FileSystemEvent]

    public init(events: [FileSystemEvent]) throws {
        guard events.count <= Self.maximumEventCount else {
            throw ModelValidationError.eventBatchTooLarge
        }
        self.events = events
    }

    private enum CodingKeys: String, CodingKey {
        case events
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(events: container.decode([FileSystemEvent].self, forKey: .events))
    }
}

public struct EventCursorFence: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, CaseIterable, Sendable {
        case historyDone
        case liveFlush
    }

    public let volumeID: MonitoredVolume.ID
    public let eventStoreUUID: UUID?
    public let highestFullyDeliveredEventID: UInt64?
    public let phase: Phase
    public let trust: EventHistoryTrust
    public let diagnostic: String?

    public init(
        volumeID: MonitoredVolume.ID,
        eventStoreUUID: UUID?,
        highestFullyDeliveredEventID: UInt64?,
        phase: Phase,
        trust: EventHistoryTrust,
        diagnostic: String? = nil
    ) {
        self.volumeID = volumeID
        self.eventStoreUUID = eventStoreUUID
        self.highestFullyDeliveredEventID = highestFullyDeliveredEventID
        self.phase = phase
        self.trust = trust
        self.diagnostic = diagnostic
    }
}

// MARK: - Changes and reports

public enum ChangeSource: String, Codable, CaseIterable, Sendable {
    case baseline
    case fsevents
    case reconciliation
}

public enum ChangeKind: String, Codable, CaseIterable, Sendable {
    case baseline
    case eventCreated
    case eventRemoved
    case eventModified
    case eventMoved
    case eventLinkAdded
    case eventLinkRemoved
    case eventAttributionTransfer
    case reconciliationAddition
    case reconciliationRemoval
    case reconciliationCorrection
    case reconciliationAttributionTransfer

    public var source: ChangeSource {
        switch self {
        case .baseline:
            .baseline
        case .eventCreated, .eventRemoved, .eventModified, .eventMoved, .eventLinkAdded, .eventLinkRemoved,
            .eventAttributionTransfer:
            .fsevents
        case .reconciliationAddition, .reconciliationRemoval, .reconciliationCorrection,
            .reconciliationAttributionTransfer:
            .reconciliation
        }
    }
}

public enum AttributionTransferDirection: String, Codable, CaseIterable, Sendable {
    case debit
    case credit
}

public enum ChangeEffect: Codable, Equatable, Sendable {
    /// A first-link creation, last-link removal, or object-size change.
    case objectTransition(before: FileFootprint?, after: FileFootprint?)
    /// One side of a canonical attribution transfer. A valid transfer is
    /// persisted as a debit and matching credit for the same object.
    case attributionTransfer(footprint: FileFootprint, direction: AttributionTransferDirection)
    /// A path/link mutation that does not allocate or release object blocks.
    case pathOnly
}

public struct ChangeRecord: Codable, Equatable, Sendable {
    public let runID: ScanRun.ID
    public let volumeID: MonitoredVolume.ID
    public let objectIdentity: FileIdentity
    public let kind: ChangeKind
    public let pathBefore: RelativePath?
    public let pathAfter: RelativePath?
    public let transferID: UUID?
    public let effect: ChangeEffect
    public let logicalDelta: Int64
    public let allocatedDelta: Int64
    public let classification: InventoryClassification

    public var source: ChangeSource { kind.source }

    public init(
        runID: ScanRun.ID,
        volumeID: MonitoredVolume.ID,
        objectIdentity: FileIdentity,
        kind: ChangeKind,
        pathBefore: RelativePath?,
        pathAfter: RelativePath?,
        transferID: UUID? = nil,
        effect: ChangeEffect,
        classification: InventoryClassification = .ordinary
    ) throws {
        guard objectIdentity.volumeID == volumeID else {
            throw ModelValidationError.inconsistentVolume
        }
        try Self.validate(
            kind: kind,
            pathBefore: pathBefore,
            pathAfter: pathAfter,
            transferID: transferID,
            effect: effect
        )

        let deltas = try Self.deltas(for: effect)
        self.runID = runID
        self.volumeID = volumeID
        self.objectIdentity = objectIdentity
        self.kind = kind
        self.pathBefore = pathBefore
        self.pathAfter = pathAfter
        self.transferID = transferID
        self.effect = effect
        self.logicalDelta = deltas.logical
        self.allocatedDelta = deltas.allocated
        self.classification = classification
    }

    private enum CodingKeys: String, CodingKey {
        case runID
        case volumeID
        case objectIdentity
        case kind
        case pathBefore
        case pathAfter
        case transferID
        case effect
        case logicalDelta
        case allocatedDelta
        case classification
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            runID: container.decode(ScanRun.ID.self, forKey: .runID),
            volumeID: container.decode(MonitoredVolume.ID.self, forKey: .volumeID),
            objectIdentity: container.decode(FileIdentity.self, forKey: .objectIdentity),
            kind: container.decode(ChangeKind.self, forKey: .kind),
            pathBefore: container.decodeIfPresent(RelativePath.self, forKey: .pathBefore),
            pathAfter: container.decodeIfPresent(RelativePath.self, forKey: .pathAfter),
            transferID: container.decodeIfPresent(UUID.self, forKey: .transferID),
            effect: container.decode(ChangeEffect.self, forKey: .effect),
            classification: container.decode(InventoryClassification.self, forKey: .classification)
        )

        let encodedLogicalDelta = try container.decode(Int64.self, forKey: .logicalDelta)
        let encodedAllocatedDelta = try container.decode(Int64.self, forKey: .allocatedDelta)
        guard encodedLogicalDelta == logicalDelta, encodedAllocatedDelta == allocatedDelta else {
            throw ModelValidationError.inconsistentDerivedDelta
        }
    }

    private static func validate(
        kind: ChangeKind,
        pathBefore: RelativePath?,
        pathAfter: RelativePath?,
        transferID: UUID?,
        effect: ChangeEffect
    ) throws {
        let isTransferEffect: Bool
        if case .attributionTransfer = effect {
            isTransferEffect = true
        } else {
            isTransferEffect = false
        }
        guard isTransferEffect == (transferID != nil) else {
            throw ModelValidationError.invalidChangeCombination
        }

        let isValid: Bool
        switch (kind, effect) {
        case (.baseline, .objectTransition(before: nil, after: .some)):
            isValid = pathBefore == nil && pathAfter != nil
        case (.eventCreated, .objectTransition(before: nil, after: .some)),
            (.reconciliationAddition, .objectTransition(before: nil, after: .some)):
            isValid = pathBefore == nil && pathAfter != nil
        case (.eventRemoved, .objectTransition(before: .some, after: nil)),
            (.reconciliationRemoval, .objectTransition(before: .some, after: nil)):
            isValid = pathBefore != nil && pathAfter == nil
        case (.eventModified, .objectTransition(before: .some, after: .some)),
            (.reconciliationCorrection, .objectTransition(before: .some, after: .some)):
            isValid = pathBefore != nil && pathAfter != nil
        case (.eventMoved, .pathOnly):
            isValid = pathBefore != nil && pathAfter != nil
        case (.eventLinkAdded, .pathOnly):
            isValid = pathBefore == nil && pathAfter != nil
        case (.eventLinkRemoved, .pathOnly):
            isValid = pathBefore != nil && pathAfter == nil
        case (.eventAttributionTransfer, .attributionTransfer),
            (.reconciliationAttributionTransfer, .attributionTransfer):
            isValid = pathBefore != nil && pathAfter != nil
        default:
            isValid = false
        }
        guard isValid else {
            throw ModelValidationError.invalidChangeCombination
        }
    }

    private static func deltas(for effect: ChangeEffect) throws -> (logical: Int64, allocated: Int64) {
        switch effect {
        case .objectTransition(let before, let after):
            return (
                try AccountingMath.subtract(after?.logicalBytes ?? 0, before?.logicalBytes ?? 0),
                try AccountingMath.subtract(after?.allocatedBytes ?? 0, before?.allocatedBytes ?? 0)
            )
        case .attributionTransfer(let footprint, let direction):
            switch direction {
            case .credit:
                return (footprint.logicalBytes, footprint.allocatedBytes)
            case .debit:
                return (
                    try AccountingMath.subtract(0, footprint.logicalBytes),
                    try AccountingMath.subtract(0, footprint.allocatedBytes)
                )
            }
        case .pathOnly:
            return (0, 0)
        }
    }
}

public struct ReconciliationBreakdown: Codable, Equatable, Sendable {
    public let missedAdditions: Int64
    public let staleRemovals: Int64
    public let sizeCorrections: Int64
    public let attributionTransfers: Int64
    public let affectedRecords: Int

    public init(
        missedAdditions: Int64,
        staleRemovals: Int64,
        sizeCorrections: Int64,
        attributionTransfers: Int64,
        affectedRecords: Int
    ) {
        self.missedAdditions = missedAdditions
        self.staleRemovals = staleRemovals
        self.sizeCorrections = sizeCorrections
        self.attributionTransfers = attributionTransfers
        self.affectedRecords = affectedRecords
    }

    public var correction: Int64 {
        get throws {
            try AccountingMath.sum([missedAdditions, staleRemovals, sizeCorrections, attributionTransfers])
        }
    }
}

public struct StorageSample: Codable, Equatable, Sendable {
    public let storageDomainID: StorageDomain.ID
    public let sampledAt: Date
    public let capacityBytes: Int64
    public let usedBytes: Int64
    public let availableBytes: Int64
    public let importantUsageAvailableBytes: Int64?
    public let opportunisticUsageAvailableBytes: Int64?

    public init(
        storageDomainID: StorageDomain.ID,
        sampledAt: Date,
        capacityBytes: Int64,
        usedBytes: Int64,
        availableBytes: Int64,
        importantUsageAvailableBytes: Int64? = nil,
        opportunisticUsageAvailableBytes: Int64? = nil
    ) throws {
        let values = [
            capacityBytes,
            usedBytes,
            availableBytes,
            importantUsageAvailableBytes ?? 0,
            opportunisticUsageAvailableBytes ?? 0,
        ]
        guard values.allSatisfy({ $0 >= 0 }) else {
            throw ModelValidationError.negativeByteCount
        }
        self.storageDomainID = storageDomainID
        self.sampledAt = sampledAt
        self.capacityBytes = capacityBytes
        self.usedBytes = usedBytes
        self.availableBytes = availableBytes
        self.importantUsageAvailableBytes = importantUsageAvailableBytes
        self.opportunisticUsageAvailableBytes = opportunisticUsageAvailableBytes
    }

    private enum CodingKeys: String, CodingKey {
        case storageDomainID
        case sampledAt
        case capacityBytes
        case usedBytes
        case availableBytes
        case importantUsageAvailableBytes
        case opportunisticUsageAvailableBytes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            storageDomainID: container.decode(StorageDomain.ID.self, forKey: .storageDomainID),
            sampledAt: container.decode(Date.self, forKey: .sampledAt),
            capacityBytes: container.decode(Int64.self, forKey: .capacityBytes),
            usedBytes: container.decode(Int64.self, forKey: .usedBytes),
            availableBytes: container.decode(Int64.self, forKey: .availableBytes),
            importantUsageAvailableBytes: container.decodeIfPresent(Int64.self, forKey: .importantUsageAvailableBytes),
            opportunisticUsageAvailableBytes: container.decodeIfPresent(
                Int64.self,
                forKey: .opportunisticUsageAvailableBytes
            )
        )
    }
}

public struct SnapshotSample: Codable, Equatable, Sendable {
    public let volumeID: MonitoredVolume.ID
    public let sampledAt: Date
    public let snapshotUUID: UUID?
    public let name: String
    public let createdAt: Date?
    public let isPurgeable: Bool?
    public let allocatedBytesEstimate: Int64?

    public init(
        volumeID: MonitoredVolume.ID,
        sampledAt: Date,
        snapshotUUID: UUID?,
        name: String,
        createdAt: Date?,
        isPurgeable: Bool?,
        allocatedBytesEstimate: Int64?
    ) throws {
        guard allocatedBytesEstimate.map({ $0 >= 0 }) ?? true else {
            throw ModelValidationError.negativeByteCount
        }
        self.volumeID = volumeID
        self.sampledAt = sampledAt
        self.snapshotUUID = snapshotUUID
        self.name = name
        self.createdAt = createdAt
        self.isPurgeable = isPurgeable
        self.allocatedBytesEstimate = allocatedBytesEstimate
    }

    private enum CodingKeys: String, CodingKey {
        case volumeID
        case sampledAt
        case snapshotUUID
        case name
        case createdAt
        case isPurgeable
        case allocatedBytesEstimate
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            volumeID: container.decode(MonitoredVolume.ID.self, forKey: .volumeID),
            sampledAt: container.decode(Date.self, forKey: .sampledAt),
            snapshotUUID: container.decodeIfPresent(UUID.self, forKey: .snapshotUUID),
            name: container.decode(String.self, forKey: .name),
            createdAt: container.decodeIfPresent(Date.self, forKey: .createdAt),
            isPurgeable: container.decodeIfPresent(Bool.self, forKey: .isPurgeable),
            allocatedBytesEstimate: container.decodeIfPresent(Int64.self, forKey: .allocatedBytesEstimate)
        )
    }
}

public struct ScanCoverage: Codable, Equatable, Sendable {
    public let visitedPathCount: UInt64
    public let indexedObjectCount: UInt64
    public let unreadablePathCount: UInt64
    public let transientErrorCount: UInt64

    public init(
        visitedPathCount: UInt64,
        indexedObjectCount: UInt64,
        unreadablePathCount: UInt64,
        transientErrorCount: UInt64
    ) {
        self.visitedPathCount = visitedPathCount
        self.indexedObjectCount = indexedObjectCount
        self.unreadablePathCount = unreadablePathCount
        self.transientErrorCount = transientErrorCount
    }
}

public struct ScanErrorRecord: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case permissionDenied
        case contentUnavailable
        case disappearedDuringScan
        case crossedVolumeBoundary
        case invalidMetadata
        case eventHistory
        case database
        case other

        public var preservesOpaqueInventory: Bool {
            self == .permissionDenied || self == .contentUnavailable
        }
    }

    public let runID: ScanRun.ID
    public let volumeID: MonitoredVolume.ID?
    public let kind: Kind
    public let path: RelativePath?
    public let errorCode: Int32?
    public let message: String

    public init(
        runID: ScanRun.ID,
        volumeID: MonitoredVolume.ID?,
        kind: Kind,
        path: RelativePath?,
        errorCode: Int32?,
        message: String
    ) {
        self.runID = runID
        self.volumeID = volumeID
        self.kind = kind
        self.path = path
        self.errorCode = errorCode
        self.message = message
    }
}

public struct RankedPathChange: Codable, Equatable, Sendable {
    public let path: RelativePath
    public let allocatedDelta: Int64
    public let logicalDelta: Int64

    public init(path: RelativePath, allocatedDelta: Int64, logicalDelta: Int64) {
        self.path = path
        self.allocatedDelta = allocatedDelta
        self.logicalDelta = logicalDelta
    }
}

public struct AccountingSummary: Codable, Equatable, Sendable {
    public let eventAttributedDelta: Int64
    public let reconciliationCorrection: Int64
    public let reconciledIndexedDelta: Int64
    public let dailyDiskOverheadDelta: Int64
    public let physicalUsedDelta: Int64?
    public let physicalUnattributedDelta: Int64?

    public init(
        eventAttributedDelta: Int64,
        reconciliationCorrection: Int64,
        reconciledIndexedDelta: Int64,
        dailyDiskOverheadDelta: Int64,
        physicalUsedDelta: Int64?,
        physicalUnattributedDelta: Int64?
    ) throws {
        guard try AccountingMath.add(eventAttributedDelta, reconciliationCorrection) == reconciledIndexedDelta else {
            throw ModelValidationError.inconsistentAccountingSummary
        }

        if let physicalUsedDelta {
            let expected = try AccountingMath.subtract(
                try AccountingMath.subtract(physicalUsedDelta, reconciledIndexedDelta),
                dailyDiskOverheadDelta
            )
            guard physicalUnattributedDelta == expected else {
                throw ModelValidationError.inconsistentAccountingSummary
            }
        } else if physicalUnattributedDelta != nil {
            throw ModelValidationError.inconsistentAccountingSummary
        }

        self.eventAttributedDelta = eventAttributedDelta
        self.reconciliationCorrection = reconciliationCorrection
        self.reconciledIndexedDelta = reconciledIndexedDelta
        self.dailyDiskOverheadDelta = dailyDiskOverheadDelta
        self.physicalUsedDelta = physicalUsedDelta
        self.physicalUnattributedDelta = physicalUnattributedDelta
    }

    private enum CodingKeys: String, CodingKey {
        case eventAttributedDelta
        case reconciliationCorrection
        case reconciledIndexedDelta
        case dailyDiskOverheadDelta
        case physicalUsedDelta
        case physicalUnattributedDelta
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            eventAttributedDelta: container.decode(Int64.self, forKey: .eventAttributedDelta),
            reconciliationCorrection: container.decode(Int64.self, forKey: .reconciliationCorrection),
            reconciledIndexedDelta: container.decode(Int64.self, forKey: .reconciledIndexedDelta),
            dailyDiskOverheadDelta: container.decode(Int64.self, forKey: .dailyDiskOverheadDelta),
            physicalUsedDelta: container.decodeIfPresent(Int64.self, forKey: .physicalUsedDelta),
            physicalUnattributedDelta: container.decodeIfPresent(Int64.self, forKey: .physicalUnattributedDelta)
        )
    }
}

public struct DailyReport: Codable, Equatable, Sendable {
    public let runID: ScanRun.ID
    public let generatedAt: Date
    public let storageDomainID: StorageDomain.ID
    public let accounting: AccountingSummary
    public let reconciliation: ReconciliationBreakdown?
    public let coverage: ScanCoverage
    public let largestGrowth: [RankedPathChange]
    public let largestShrinkage: [RankedPathChange]
    public let physicalDiagnosis: PhysicalAttributionDiagnosis?
    public let diagnostics: [String]

    public init(
        runID: ScanRun.ID,
        generatedAt: Date,
        storageDomainID: StorageDomain.ID,
        accounting: AccountingSummary,
        reconciliation: ReconciliationBreakdown?,
        coverage: ScanCoverage,
        largestGrowth: [RankedPathChange],
        largestShrinkage: [RankedPathChange],
        physicalDiagnosis: PhysicalAttributionDiagnosis? = nil,
        diagnostics: [String]
    ) throws {
        if let reconciliation {
            guard try reconciliation.correction == accounting.reconciliationCorrection else {
                throw ModelValidationError.inconsistentReconciliationBreakdown
            }
        } else if accounting.reconciliationCorrection != 0 {
            throw ModelValidationError.inconsistentReconciliationBreakdown
        }
        if let physicalDiagnosis {
            guard physicalDiagnosis.physicalUnattributedDelta == accounting.physicalUnattributedDelta,
                physicalDiagnosis.unreadablePathCount == coverage.unreadablePathCount
            else {
                throw ModelValidationError.inconsistentPhysicalDiagnosis
            }
        }
        self.runID = runID
        self.generatedAt = generatedAt
        self.storageDomainID = storageDomainID
        self.accounting = accounting
        self.reconciliation = reconciliation
        self.coverage = coverage
        self.largestGrowth = largestGrowth
        self.largestShrinkage = largestShrinkage
        self.physicalDiagnosis = physicalDiagnosis
        self.diagnostics = diagnostics
    }

    private enum CodingKeys: String, CodingKey {
        case runID
        case generatedAt
        case storageDomainID
        case accounting
        case reconciliation
        case coverage
        case largestGrowth
        case largestShrinkage
        case physicalDiagnosis
        case diagnostics
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            runID: container.decode(ScanRun.ID.self, forKey: .runID),
            generatedAt: container.decode(Date.self, forKey: .generatedAt),
            storageDomainID: container.decode(StorageDomain.ID.self, forKey: .storageDomainID),
            accounting: container.decode(AccountingSummary.self, forKey: .accounting),
            reconciliation: container.decodeIfPresent(ReconciliationBreakdown.self, forKey: .reconciliation),
            coverage: container.decode(ScanCoverage.self, forKey: .coverage),
            largestGrowth: container.decode([RankedPathChange].self, forKey: .largestGrowth),
            largestShrinkage: container.decode([RankedPathChange].self, forKey: .largestShrinkage),
            physicalDiagnosis: container.decodeIfPresent(
                PhysicalAttributionDiagnosis.self,
                forKey: .physicalDiagnosis
            ),
            diagnostics: container.decode([String].self, forKey: .diagnostics)
        )
    }
}

public enum ModelValidationError: Error, Equatable, Sendable {
    case negativeByteCount
    case inconsistentVolume
    case inconsistentParentPath
    case inconsistentObjectIdentity
    case inconsistentDerivedDelta
    case invalidChangeCombination
    case inconsistentAccountingSummary
    case inconsistentReconciliationBreakdown
    case mismatchedStorageDomain
    case invalidSampleChronology
    case eventBatchTooLarge
    case invalidScanCommit
    case invalidInventoryState
    case unbalancedAttributionTransfer
    case invalidReportCommit
    case inventoryBatchTooLarge
    case inconsistentPhysicalDiagnosis
}
