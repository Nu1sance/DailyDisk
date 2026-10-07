import Foundation

// MARK: - Discovery and sampling

public protocol VolumeDiscovering: Sendable {
    func discoverInternalAPFSVolumes() async throws -> VolumeTopology
}

public protocol SnapshotProviding: Sendable {
    func snapshots(volume: MonitoredVolume) async throws -> [SnapshotSample]
}

public protocol DeletedOpenFileProbing: Sendable {
    func deletedOpenFiles() async throws -> [DeletedOpenFile]
}

public protocol DailyDiskOverheadSampling: Sendable {
    func sample(storageDomainID: StorageDomain.ID) async throws -> DailyDiskOverheadSample
}

public protocol DiskUsageSampling: Sendable {
    func sample(storageDomain: StorageDomain) async throws -> StorageSample
    func snapshots(volume: MonitoredVolume) async throws -> [SnapshotSample]
}

// MARK: - FSEvents

public protocol EventHistorySession: Sendable {
    /// Delivers bounded, serialized batches through the FSEvents HistoryDone
    /// boundary. The consumer is never called concurrently or after return.
    /// Only the returned trusted fence may be persisted as a checkpoint.
    func replayHistoricalEvents(
        consume: @escaping @Sendable (EventBatch) async throws -> Void
    ) async throws -> EventCursorFence

    /// Flushes and delivers bounded batches that occurred while a full scan was
    /// running. The returned fence covers every event delivered before it.
    func flushLiveEvents(
        consume: @escaping @Sendable (EventBatch) async throws -> Void
    ) async throws -> EventCursorFence

    func replayHistoricalEvents(
        observer: any ScanWorkObserving,
        consume: @escaping @Sendable (EventBatch) async throws -> Void
    ) async throws -> EventCursorFence

    func flushLiveEvents(
        observer: any ScanWorkObserving,
        consume: @escaping @Sendable (EventBatch) async throws -> Void
    ) async throws -> EventCursorFence

    func stop() async
}

extension EventHistorySession {
    public func replayHistoricalEvents(
        observer: any ScanWorkObserving,
        consume: @escaping @Sendable (EventBatch) async throws -> Void
    ) async throws -> EventCursorFence {
        try await observer.checkpoint()
        return try await replayHistoricalEvents(consume: consume)
    }

    public func flushLiveEvents(
        observer: any ScanWorkObserving,
        consume: @escaping @Sendable (EventBatch) async throws -> Void
    ) async throws -> EventCursorFence {
        try await observer.checkpoint()
        return try await flushLiveEvents(consume: consume)
    }
}

public protocol EventHistoryReading: Sendable {
    func openSession(
        volume: MonitoredVolume,
        checkpoint: EventStreamCheckpoint?
    ) async throws -> any EventHistorySession
}

// MARK: - Filesystem inventory

public struct InventoryRecordBatch: Sendable {
    public static let maximumRecordCount = 1_024
    public let records: [InventoryRecord]

    public init(records: [InventoryRecord]) throws {
        guard records.count <= Self.maximumRecordCount else {
            throw ModelValidationError.inventoryBatchTooLarge
        }
        self.records = records
    }
}

public struct InventoryScanResult: Codable, Equatable, Sendable {
    public let coverage: ScanCoverage
    public let errors: [ScanErrorRecord]

    public init(coverage: ScanCoverage, errors: [ScanErrorRecord]) {
        self.coverage = coverage
        self.errors = errors
    }
}

public enum FileMetadataReadResult: Sendable {
    case record(InventoryRecord)
    case missing
    case excluded
    case inaccessible(code: Int32)
    case unavailable(code: Int32)
}

public protocol FileMetadataReading: Sendable {
    /// Reads one current volume-relative path without following symlinks and
    /// distinguishes policy exclusion from an actual missing path.
    func read(volume: MonitoredVolume, path: RelativePath) async throws -> FileMetadataReadResult
}

public protocol FileInventoryScanning: Sendable {
    /// Scans one mounted volume without following symlinks or crossing device
    /// boundaries. Records are delivered in bounded, serialized batches. The
    /// consumer is never called concurrently or retained after return.
    func scan(
        volume: MonitoredVolume,
        runID: ScanRun.ID,
        consume: @escaping @Sendable (InventoryRecordBatch) async throws -> Void
    ) async throws -> InventoryScanResult

    /// Scans one current directory subtree with the same safety and batching
    /// guarantees as a full-volume scan.
    func scanSubtree(
        volume: MonitoredVolume,
        root: RelativePath,
        runID: ScanRun.ID,
        consume: @escaping @Sendable (InventoryRecordBatch) async throws -> Void
    ) async throws -> InventoryScanResult

    func scan(
        volume: MonitoredVolume,
        runID: ScanRun.ID,
        observer: any ScanWorkObserving,
        consume: @escaping @Sendable (InventoryRecordBatch) async throws -> Void
    ) async throws -> InventoryScanResult

    func scanSubtree(
        volume: MonitoredVolume,
        root: RelativePath,
        runID: ScanRun.ID,
        observer: any ScanWorkObserving,
        consume: @escaping @Sendable (InventoryRecordBatch) async throws -> Void
    ) async throws -> InventoryScanResult
}

extension FileInventoryScanning {
    public func scan(
        volume: MonitoredVolume,
        runID: ScanRun.ID,
        observer: any ScanWorkObserving,
        consume: @escaping @Sendable (InventoryRecordBatch) async throws -> Void
    ) async throws -> InventoryScanResult {
        try await observer.checkpoint()
        return try await scan(volume: volume, runID: runID, consume: consume)
    }

    public func scanSubtree(
        volume: MonitoredVolume,
        root: RelativePath,
        runID: ScanRun.ID,
        observer: any ScanWorkObserving,
        consume: @escaping @Sendable (InventoryRecordBatch) async throws -> Void
    ) async throws -> InventoryScanResult {
        try await observer.checkpoint()
        return try await scanSubtree(volume: volume, root: root, runID: runID, consume: consume)
    }
}

// MARK: - Persistence

public struct InventoryState: Codable, Equatable, Sendable {
    public let checkpoint: Checkpoint
    public let activeGeneration: InventoryGeneration

    public init(checkpoint: Checkpoint, activeGeneration: InventoryGeneration) throws {
        guard checkpoint.volumeID == activeGeneration.volumeID,
            checkpoint.activeGenerationID == activeGeneration.id,
            activeGeneration.state == .active
        else {
            throw ModelValidationError.invalidInventoryState
        }
        self.checkpoint = checkpoint
        self.activeGeneration = activeGeneration
    }

    private enum CodingKeys: String, CodingKey {
        case checkpoint
        case activeGeneration
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            checkpoint: container.decode(Checkpoint.self, forKey: .checkpoint),
            activeGeneration: container.decode(InventoryGeneration.self, forKey: .activeGeneration)
        )
    }
}

public enum InventoryMutation: Codable, Equatable, Sendable {
    case upsert(InventoryRecord)
    case remove(volumeID: MonitoredVolume.ID, path: RelativePath)
}

public enum InventoryMutationTarget: Codable, Equatable, Sendable {
    /// The event-maintained expected state derived from the active generation.
    case expectedActive(volumeID: MonitoredVolume.ID)
    /// A full-scan generation that is not active yet.
    case stagingGeneration(InventoryGeneration.ID)
}

public struct InventoryDiff: Codable, Equatable, Sendable {
    public let expected: InventoryRecord?
    public let authoritative: InventoryRecord?

    public init(expected: InventoryRecord?, authoritative: InventoryRecord?) {
        self.expected = expected
        self.authoritative = authoritative
    }
}

public struct InventoryDiffBatch: Sendable {
    public static let maximumDifferenceCount = 1_024
    public let differences: [InventoryDiff]

    public init(differences: [InventoryDiff]) throws {
        guard differences.count <= Self.maximumDifferenceCount else {
            throw ModelValidationError.inventoryBatchTooLarge
        }
        self.differences = differences
    }
}

public struct CanonicalAttributionBatch: Sendable {
    public static let maximumAttributionCount = 1_024
    public let attributions: [CanonicalAttribution]

    public init(attributions: [CanonicalAttribution]) throws {
        guard attributions.count <= Self.maximumAttributionCount else {
            throw ModelValidationError.inventoryBatchTooLarge
        }
        self.attributions = attributions
    }
}

public struct ScanCommit: Codable, Equatable, Sendable {
    public let reusesActiveInventory: Bool
    public let comparesSnapshots: Bool
    public let runID: ScanRun.ID
    public let runKind: ScanRun.Kind
    public let scope: StorageDomainScope
    public let volumeID: MonitoredVolume.ID
    public let activatedGenerationID: InventoryGeneration.ID?
    public let previousCheckpoint: Checkpoint?
    public let checkpoint: Checkpoint
    public let eventFence: EventCursorFence?
    public let changes: [ChangeRecord]
    public let storageSamples: [StorageSample]
    public let snapshotSamples: [SnapshotSample]
    public let snapshotObservedVolumeIDs: Set<MonitoredVolume.ID>
    public let overheadSample: DailyDiskOverheadSample?
    public let coverage: ScanCoverage
    public let scanErrors: [ScanErrorRecord]

    public init(
        runID: ScanRun.ID,
        runKind: ScanRun.Kind,
        scope: StorageDomainScope,
        volumeID: MonitoredVolume.ID,
        activatedGenerationID: InventoryGeneration.ID?,
        previousCheckpoint: Checkpoint?,
        checkpoint: Checkpoint,
        eventFence: EventCursorFence?,
        changes: [ChangeRecord],
        storageSamples: [StorageSample],
        snapshotSamples: [SnapshotSample],
        snapshotObservedVolumeIDs: Set<MonitoredVolume.ID> = [],
        overheadSample: DailyDiskOverheadSample? = nil,
        coverage: ScanCoverage = ScanCoverage(
            visitedPathCount: 0,
            indexedObjectCount: 0,
            unreadablePathCount: 0,
            transientErrorCount: 0
        ),
        scanErrors: [ScanErrorRecord] = [],
        comparesSnapshots: Bool = false,
        reusesActiveInventory: Bool = false
    ) throws {
        guard !comparesSnapshots || (runKind != .incremental && changes.allSatisfy { $0.source == .snapshotComparison })
        else {
            throw ModelValidationError.invalidScanCommit
        }
        guard
            !reusesActiveInventory
                || (comparesSnapshots && previousCheckpoint != nil
                    && activatedGenerationID == nil
                    && previousCheckpoint?.activeGenerationID == checkpoint.activeGenerationID)
        else {
            throw ModelValidationError.invalidScanCommit
        }
        self.reusesActiveInventory = reusesActiveInventory
        self.comparesSnapshots = comparesSnapshots
        guard let scopedVolume = scope.volumes.first(where: { $0.id == volumeID }),
            checkpoint.volumeID == volumeID,
            checkpoint.eventStoreUUID == scopedVolume.eventStoreUUID,
            checkpoint.topologyFingerprint == scopedVolume.topologyFingerprint,
            previousCheckpoint.map({ $0.volumeID == volumeID }) ?? true,
            changes.allSatisfy({ $0.volumeID == volumeID && $0.runID == runID }),
            storageSamples.allSatisfy({ $0.storageDomainID == scope.domain.id }),
            snapshotSamples.allSatisfy({ scope.volumeIDs.contains($0.volumeID) }),
            snapshotObservedVolumeIDs.isSubset(of: scope.volumeIDs),
            overheadSample.map({ $0.storageDomainID == scope.domain.id }) ?? true,
            scanErrors.allSatisfy({
                $0.runID == runID && ($0.volumeID == nil || scope.volumeIDs.contains($0.volumeID!))
            })
        else {
            throw ModelValidationError.invalidScanCommit
        }
        try ChangeSetValidator.validateAttributionTransfers(in: changes)
        if scopedVolume.supportsPersistentEvents {
            guard checkpoint.lastCommittedEventID != nil,
                eventFence?.highestFullyDeliveredEventID != nil
            else {
                throw ModelValidationError.invalidScanCommit
            }
        }

        switch runKind {
        case .incremental:
            guard activatedGenerationID == nil,
                let previousCheckpoint,
                previousCheckpoint.activeGenerationID == checkpoint.activeGenerationID,
                previousCheckpoint.eventStoreUUID == checkpoint.eventStoreUUID,
                previousCheckpoint.topologyFingerprint == checkpoint.topologyFingerprint,
                Self.cursorDidNotRegress(
                    from: previousCheckpoint.lastCommittedEventID,
                    to: checkpoint.lastCommittedEventID
                ),
                eventFence?.phase == .liveFlush
            else {
                throw ModelValidationError.invalidScanCommit
            }
        case .full, .recovery:
            let fullScanCursorIsValid =
                previousCheckpoint.map {
                    $0.eventStoreUUID != checkpoint.eventStoreUUID
                        || Self.cursorDidNotRegress(
                            from: $0.lastCommittedEventID,
                            to: checkpoint.lastCommittedEventID
                        )
                } ?? true
            guard reusesActiveInventory || activatedGenerationID == checkpoint.activeGenerationID,
                fullScanCursorIsValid,
                eventFence.map({ $0.phase == .liveFlush }) ?? true
            else {
                throw ModelValidationError.invalidScanCommit
            }
            if scopedVolume.supportsPersistentEvents, eventFence == nil {
                throw ModelValidationError.invalidScanCommit
            }
        }

        let checkpointAdvanced =
            previousCheckpoint.map {
                $0.eventStoreUUID != checkpoint.eventStoreUUID
                    || $0.lastCommittedEventID != checkpoint.lastCommittedEventID
            } ?? (checkpoint.eventStoreUUID != nil || checkpoint.lastCommittedEventID != nil)
        if checkpointAdvanced && eventFence == nil {
            throw ModelValidationError.invalidScanCommit
        }

        if let eventFence {
            guard eventFence.trust == .trusted,
                eventFence.volumeID == volumeID,
                eventFence.eventStoreUUID == checkpoint.eventStoreUUID,
                eventFence.highestFullyDeliveredEventID == checkpoint.lastCommittedEventID
            else {
                throw ModelValidationError.invalidScanCommit
            }
        }

        self.runID = runID
        self.runKind = runKind
        self.scope = scope
        self.volumeID = volumeID
        self.activatedGenerationID = activatedGenerationID
        self.previousCheckpoint = previousCheckpoint
        self.checkpoint = checkpoint
        self.eventFence = eventFence
        self.changes = changes
        self.storageSamples = storageSamples
        self.snapshotSamples = snapshotSamples
        self.snapshotObservedVolumeIDs = snapshotObservedVolumeIDs
        self.overheadSample = overheadSample
        self.coverage = coverage
        self.scanErrors = scanErrors
    }

    private static func cursorDidNotRegress(from previous: UInt64?, to current: UInt64?) -> Bool {
        switch (previous, current) {
        case (.none, _):
            true
        case (.some, .none):
            false
        case (.some(let previous), .some(let current)):
            current >= previous
        }
    }

    private enum CodingKeys: String, CodingKey {
        case runID
        case runKind
        case scope
        case volumeID
        case reusesActiveInventory
        case comparesSnapshots
        case activatedGenerationID
        case previousCheckpoint
        case checkpoint
        case eventFence
        case changes
        case storageSamples
        case snapshotSamples
        case snapshotObservedVolumeIDs
        case overheadSample
        case coverage
        case scanErrors
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            runID: container.decode(ScanRun.ID.self, forKey: .runID),
            runKind: container.decode(ScanRun.Kind.self, forKey: .runKind),
            scope: container.decode(StorageDomainScope.self, forKey: .scope),
            volumeID: container.decode(MonitoredVolume.ID.self, forKey: .volumeID),
            activatedGenerationID: container.decodeIfPresent(
                InventoryGeneration.ID.self,
                forKey: .activatedGenerationID
            ),
            previousCheckpoint: container.decodeIfPresent(Checkpoint.self, forKey: .previousCheckpoint),
            checkpoint: container.decode(Checkpoint.self, forKey: .checkpoint),
            eventFence: container.decodeIfPresent(EventCursorFence.self, forKey: .eventFence),
            changes: container.decode([ChangeRecord].self, forKey: .changes),
            storageSamples: container.decode([StorageSample].self, forKey: .storageSamples),
            snapshotSamples: container.decode([SnapshotSample].self, forKey: .snapshotSamples),
            snapshotObservedVolumeIDs: container.decodeIfPresent(
                Set<MonitoredVolume.ID>.self,
                forKey: .snapshotObservedVolumeIDs
            ) ?? [],
            overheadSample: container.decodeIfPresent(DailyDiskOverheadSample.self, forKey: .overheadSample),
            coverage: container.decodeIfPresent(ScanCoverage.self, forKey: .coverage)
                ?? ScanCoverage(
                    visitedPathCount: 0,
                    indexedObjectCount: 0,
                    unreadablePathCount: 0,
                    transientErrorCount: 0
                ),
            scanErrors: container.decodeIfPresent([ScanErrorRecord].self, forKey: .scanErrors) ?? [],
            comparesSnapshots: container.decodeIfPresent(Bool.self, forKey: .comparesSnapshots) ?? false,
            reusesActiveInventory: container.decodeIfPresent(Bool.self, forKey: .reusesActiveInventory) ?? false
        )
    }
}

public struct ReportCommit: Codable, Equatable, Sendable {
    public let publishedAt: Date
    public let runID: ScanRun.ID
    public let scope: StorageDomainScope
    public let changes: [ChangeRecord]
    public let previousStorageSample: StorageSample?
    public let currentStorageSample: StorageSample
    public let previousOverheadSample: DailyDiskOverheadSample?
    public let currentOverheadSample: DailyDiskOverheadSample?
    public let dailyDiskOverheadDelta: Int64
    public let report: DailyReport

    public init(
        runID: ScanRun.ID,
        scope: StorageDomainScope,
        changes: [ChangeRecord],
        previousStorageSample: StorageSample?,
        currentStorageSample: StorageSample,
        previousOverheadSample: DailyDiskOverheadSample?,
        currentOverheadSample: DailyDiskOverheadSample?,
        report: DailyReport,
        publishedAt: Date = Date()
    ) throws {
        guard publishedAt.timeIntervalSince1970.isFinite else { throw ModelValidationError.invalidReportCommit }
        self.publishedAt = publishedAt
        guard changes.allSatisfy({ $0.runID == runID }),
            report.runID == runID,
            report.storageDomainID == scope.domain.id
        else {
            throw ModelValidationError.invalidReportCommit
        }
        guard
            currentOverheadSample.map({
                $0.storageDomainID == scope.domain.id
                    && $0.sampledAt <= currentStorageSample.sampledAt
            }) ?? true,
            previousOverheadSample.map({ previous in
                previous.storageDomainID == scope.domain.id
                    && previousStorageSample.map({ previous.sampledAt <= $0.sampledAt }) == true
            }) ?? true
        else {
            throw ModelValidationError.invalidReportCommit
        }
        let overheadDelta: Int64
        switch (previousOverheadSample, currentOverheadSample) {
        case (.some(let previous), .some(let current)):
            guard previous.sampledAt < current.sampledAt else {
                throw ModelValidationError.invalidReportCommit
            }
            overheadDelta = try AccountingMath.subtract(current.allocatedBytes, previous.allocatedBytes)
        case (.none, .some), (.none, .none):
            overheadDelta = 0
        case (.some, .none):
            throw ModelValidationError.invalidReportCommit
        }
        let accounting = try SpaceAccounting.summarize(
            changes: changes,
            scope: scope,
            previousSample: previousStorageSample,
            currentSample: currentStorageSample,
            additionalDailyDiskOverheadDelta: overheadDelta
        )
        let reconciliation = try SpaceAccounting.reconciliationBreakdown(from: changes)
        guard accounting == report.accounting, reconciliation == report.reconciliation else {
            throw ModelValidationError.invalidReportCommit
        }
        self.runID = runID
        self.scope = scope
        self.changes = changes
        self.previousStorageSample = previousStorageSample
        self.currentStorageSample = currentStorageSample
        self.previousOverheadSample = previousOverheadSample
        self.currentOverheadSample = currentOverheadSample
        dailyDiskOverheadDelta = overheadDelta
        self.report = report
    }

    private enum CodingKeys: String, CodingKey {
        case runID
        case scope
        case changes
        case previousStorageSample
        case currentStorageSample
        case previousOverheadSample
        case currentOverheadSample
        case report
        case publishedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            runID: container.decode(ScanRun.ID.self, forKey: .runID),
            scope: container.decode(StorageDomainScope.self, forKey: .scope),
            changes: container.decode([ChangeRecord].self, forKey: .changes),
            previousStorageSample: container.decodeIfPresent(StorageSample.self, forKey: .previousStorageSample),
            currentStorageSample: container.decode(StorageSample.self, forKey: .currentStorageSample),
            previousOverheadSample: container.decodeIfPresent(
                DailyDiskOverheadSample.self,
                forKey: .previousOverheadSample
            ),
            currentOverheadSample: container.decodeIfPresent(
                DailyDiskOverheadSample.self,
                forKey: .currentOverheadSample
            ),
            report: container.decode(DailyReport.self, forKey: .report),
            publishedAt: container.decodeIfPresent(Date.self, forKey: .publishedAt) ?? Date()
        )
    }
}

public struct PersistedReportBasis: Sendable {
    public let runID: ScanRun.ID
    public let checkpointDate: Date
    public let changes: [ChangeRecord]
    public let currentStorageSample: StorageSample
    public let currentSnapshots: [SnapshotSample]
    public let snapshotObservedVolumeIDs: Set<MonitoredVolume.ID>
    public let currentOverhead: DailyDiskOverheadSample?
    public let coverage: ScanCoverage
    public let scanErrors: [ScanErrorRecord]

    public init(
        runID: ScanRun.ID,
        checkpointDate: Date,
        changes: [ChangeRecord],
        currentStorageSample: StorageSample,
        currentSnapshots: [SnapshotSample],
        snapshotObservedVolumeIDs: Set<MonitoredVolume.ID>,
        currentOverhead: DailyDiskOverheadSample?,
        coverage: ScanCoverage,
        scanErrors: [ScanErrorRecord]
    ) {
        self.runID = runID
        self.checkpointDate = checkpointDate
        self.changes = changes
        self.currentStorageSample = currentStorageSample
        self.currentSnapshots = currentSnapshots
        self.snapshotObservedVolumeIDs = snapshotObservedVolumeIDs
        self.currentOverhead = currentOverhead
        self.coverage = coverage
        self.scanErrors = scanErrors
    }
}

public protocol InventoryStoring: Sendable {
    func prepare() async throws
    func register(scope: StorageDomainScope) async throws
    func recoverInterruptedRuns(at date: Date) async throws
    func interrupt(runID: ScanRun.ID, finishedAt: Date) async throws
    func activeRuns() async throws -> [ScanRun]
    func scanRun(id: ScanRun.ID) async throws -> ScanRun?
    func state(for volumeID: MonitoredVolume.ID) async throws -> InventoryState?
    func begin(run: ScanRun) async throws

    func beginFullComparison(volumeID: MonitoredVolume.ID, runID: ScanRun.ID) async throws -> Bool
    func observeFullComparison(records: [InventoryRecord], volumeID: MonitoredVolume.ID, runID: ScanRun.ID) async throws
    func finishFullComparison(
        opaqueRoots: [RelativePath], volumeID: MonitoredVolume.ID, runID: ScanRun.ID,
        observer: any ScanWorkObserving) async throws

    func createStagingGeneration(
        volumeID: MonitoredVolume.ID,
        runID: ScanRun.ID,
        at date: Date
    ) async throws -> InventoryGeneration

    func append(
        records: [InventoryRecord],
        to generationID: InventoryGeneration.ID
    ) async throws

    func stage(
        mutations: [InventoryMutation],
        target: InventoryMutationTarget,
        for runID: ScanRun.ID
    ) async throws

    /// Stages removal of a path and every indexed descendant. Used when a
    /// directory disappears before current metadata can be read.
    func stageRemovalSubtree(
        root: RelativePath,
        target: InventoryMutationTarget,
        for runID: ScanRun.ID
    ) async throws

    func stageRemovalSubtree(
        root: RelativePath,
        target: InventoryMutationTarget,
        for runID: ScanRun.ID,
        observer: any ScanWorkObserving
    ) async throws

    /// Copies one sealed-boundary filesystem mutation plan between run targets
    /// without re-reading the live filesystem.
    func copyMutations(
        from source: InventoryMutationTarget,
        to destination: InventoryMutationTarget,
        for runID: ScanRun.ID
    ) async throws

    func copyMutations(
        from source: InventoryMutationTarget,
        to destination: InventoryMutationTarget,
        for runID: ScanRun.ID,
        observer: any ScanWorkObserving
    ) async throws

    /// Preserves previously indexed opaque subtrees when a full scan cannot
    /// enumerate them with current user permissions.
    func preserveOpaqueSubtrees(
        roots: [RelativePath],
        from source: InventoryMutationTarget,
        to destination: InventoryMutationTarget,
        for runID: ScanRun.ID
    ) async throws

    func preserveOpaqueSubtrees(
        roots: [RelativePath],
        from source: InventoryMutationTarget,
        to destination: InventoryMutationTarget,
        for runID: ScanRun.ID,
        observer: any ScanWorkObserving
    ) async throws

    /// Reads through the run's staged overlay, so a later incremental batch can
    /// observe mutations staged by an earlier batch without exposing them to
    /// other runs.
    func records(
        target: InventoryMutationTarget,
        runID: ScanRun.ID,
        paths: [RelativePath]
    ) async throws -> [InventoryRecord]

    func paths(
        target: InventoryMutationTarget,
        runID: ScanRun.ID,
        objectIdentity: FileIdentity
    ) async throws -> [RelativePath]

    /// Derives the exact FSEvents ledger from the sealed active overlay. The
    /// result is bounded by changed identities/paths, not total inventory size.
    func deriveIncrementalChanges(
        target: InventoryMutationTarget,
        runID: ScanRun.ID
    ) async throws -> [ChangeRecord]

    func deriveIncrementalChanges(
        target: InventoryMutationTarget,
        runID: ScanRun.ID,
        observer: any ScanWorkObserving
    ) async throws -> [ChangeRecord]

    func deriveReconciliationChanges(
        expected: InventoryMutationTarget,
        authoritative: InventoryMutationTarget,
        runID: ScanRun.ID
    ) async throws -> [ChangeRecord]

    func deriveReconciliationChanges(
        expected: InventoryMutationTarget,
        authoritative: InventoryMutationTarget,
        runID: ScanRun.ID,
        observer: any ScanWorkObserving
    ) async throws -> [ChangeRecord]

    /// Recomputes one canonical attribution per object from the run's
    /// post-mutation view. Stores enforce a unique target/object key.
    func finalizeCanonicalAttribution(
        target: InventoryMutationTarget,
        runID: ScanRun.ID,
        consume: @escaping @Sendable (CanonicalAttributionBatch) async throws -> Void
    ) async throws

    func finalizeCanonicalAttribution(
        target: InventoryMutationTarget,
        runID: ScanRun.ID,
        observer: any ScanWorkObserving,
        consume: @escaping @Sendable (CanonicalAttributionBatch) async throws -> Void
    ) async throws

    /// Streams a bounded diff between two run-scoped, post-mutation views. The
    /// consumer is serialized and not retained after return.
    func diff(
        expected: InventoryMutationTarget,
        authoritative: InventoryMutationTarget,
        runID: ScanRun.ID,
        consume: @escaping @Sendable (InventoryDiffBatch) async throws -> Void
    ) async throws

    func diff(
        expected: InventoryMutationTarget,
        authoritative: InventoryMutationTarget,
        runID: ScanRun.ID,
        observer: any ScanWorkObserving,
        consume: @escaping @Sendable (InventoryDiffBatch) async throws -> Void
    ) async throws

    /// Atomically applies staged mutations/generation activation, the exact
    /// trusted event fence/checkpoint, change ledger, samples, report, and
    /// successful run state.
    func commit(_ commit: ScanCommit, finishedAt: Date) async throws

    /// Idempotently persists a report only after its referenced run ledger and
    /// samples are committed. `ReportCommit` proves it derives from that basis.
    func deriveSnapshotChanges(
        authoritative: InventoryMutationTarget, runID: ScanRun.ID, observer: any ScanWorkObserving
    ) async throws -> [ChangeRecord]

    func commitReport(_ commit: ReportCommit) async throws

    func report(
        runID: ScanRun.ID,
        storageDomainID: StorageDomain.ID
    ) async throws -> DailyReport?

    func latestUnreportedBasis(
        storageDomainID: StorageDomain.ID
    ) async throws -> PersistedReportBasis?

    func latestStorageSample(
        storageDomainID: StorageDomain.ID,
        before date: Date
    ) async throws -> StorageSample?

    func latestSnapshotSamples(
        volumeIDs: Set<MonitoredVolume.ID>,
        before date: Date
    ) async throws -> [SnapshotSample]

    func latestOverheadSample(
        storageDomainID: StorageDomain.ID,
        before date: Date
    ) async throws -> DailyDiskOverheadSample?

    func fail(
        runID: ScanRun.ID,
        errors: [ScanErrorRecord],
        finishedAt: Date
    ) async throws
}

extension InventoryStoring {
    public func beginFullComparison(volumeID: MonitoredVolume.ID, runID: ScanRun.ID) async throws -> Bool { false }
    public func observeFullComparison(records: [InventoryRecord], volumeID: MonitoredVolume.ID, runID: ScanRun.ID)
        async throws
    {
        throw ModelValidationError.invalidScanCommit
    }
    public func finishFullComparison(
        opaqueRoots: [RelativePath], volumeID: MonitoredVolume.ID, runID: ScanRun.ID,
        observer: any ScanWorkObserving
    ) async throws { throw ModelValidationError.invalidScanCommit }

    public func stageRemovalSubtree(
        root: RelativePath,
        target: InventoryMutationTarget,
        for runID: ScanRun.ID,
        observer: any ScanWorkObserving
    ) async throws {
        try await observer.checkpoint()
        try await stageRemovalSubtree(root: root, target: target, for: runID)
    }

    public func copyMutations(
        from source: InventoryMutationTarget,
        to destination: InventoryMutationTarget,
        for runID: ScanRun.ID,
        observer: any ScanWorkObserving
    ) async throws {
        try await observer.checkpoint()
        try await copyMutations(from: source, to: destination, for: runID)
    }

    public func preserveOpaqueSubtrees(
        roots: [RelativePath],
        from source: InventoryMutationTarget,
        to destination: InventoryMutationTarget,
        for runID: ScanRun.ID,
        observer: any ScanWorkObserving
    ) async throws {
        try await observer.checkpoint()
        try await preserveOpaqueSubtrees(roots: roots, from: source, to: destination, for: runID)
    }

    public func deriveIncrementalChanges(
        target: InventoryMutationTarget,
        runID: ScanRun.ID,
        observer: any ScanWorkObserving
    ) async throws -> [ChangeRecord] {
        try await observer.checkpoint()
        return try await deriveIncrementalChanges(target: target, runID: runID)
    }

    public func deriveReconciliationChanges(
        expected: InventoryMutationTarget,
        authoritative: InventoryMutationTarget,
        runID: ScanRun.ID,
        observer: any ScanWorkObserving
    ) async throws -> [ChangeRecord] {
        try await observer.checkpoint()
        return try await deriveReconciliationChanges(
            expected: expected,
            authoritative: authoritative,
            runID: runID
        )
    }

    public func finalizeCanonicalAttribution(
        target: InventoryMutationTarget,
        runID: ScanRun.ID,
        observer: any ScanWorkObserving,
        consume: @escaping @Sendable (CanonicalAttributionBatch) async throws -> Void
    ) async throws {
        try await observer.checkpoint()
        try await finalizeCanonicalAttribution(target: target, runID: runID, consume: consume)
    }

    public func diff(
        expected: InventoryMutationTarget,
        authoritative: InventoryMutationTarget,
        runID: ScanRun.ID,
        observer: any ScanWorkObserving,
        consume: @escaping @Sendable (InventoryDiffBatch) async throws -> Void
    ) async throws {
        try await observer.checkpoint()
        try await diff(
            expected: expected,
            authoritative: authoritative,
            runID: runID,
            consume: consume
        )
    }
}

// MARK: - Reports and notifications

public struct ReportArtifacts: Codable, Equatable, Sendable {
    public let jsonURL: URL
    public let markdownURL: URL

    public init(jsonURL: URL, markdownURL: URL) {
        self.jsonURL = jsonURL
        self.markdownURL = markdownURL
    }
}

public protocol ReportWriting: Sendable {
    func existingReport(runID: ScanRun.ID) async throws -> DailyReport?
    func write(report: DailyReport) async throws -> ReportArtifacts
}

extension ReportWriting {
    public func existingReport(runID: ScanRun.ID) async throws -> DailyReport? { nil }
}

public struct NotificationMessage: Codable, Equatable, Sendable {
    public enum Severity: String, Codable, CaseIterable, Sendable {
        case information
        case warning
        case critical
    }

    public let identifier: String
    public let title: String
    public let body: String
    public let severity: Severity

    // Optional for compatibility with previously encoded delivery payloads.
    public let playsSound: Bool?
    public let badgeCount: Int?
    public let reportRunID: UUID?
    public let badgeOnly: Bool?

    public init(
        identifier: String, title: String, body: String, severity: Severity,
        playsSound: Bool? = nil, badgeCount: Int? = nil, reportRunID: UUID? = nil, badgeOnly: Bool? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.severity = severity
        self.playsSound = playsSound
        self.badgeCount = badgeCount
        self.reportRunID = reportRunID
        self.badgeOnly = badgeOnly
    }

}

public protocol NotificationSending: Sendable {
    func send(_ message: NotificationMessage) async throws
}

// MARK: - Progress and cancellation

public protocol ScanWorkObserving: Sendable {
    func checkpoint(_ delta: ScanProgressDelta) async throws
}

extension ScanWorkObserving {
    public func checkpoint() async throws {
        try await checkpoint(ScanProgressDelta())
    }
}

public func withScanCancellationMonitoring<T: Sendable>(
    observer: any ScanWorkObserving,
    pollingInterval: Duration = .milliseconds(100),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            while true {
                try await observer.checkpoint()
                try await Task.sleep(for: pollingInterval)
            }
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw CancellationError()
        }
        return result
    }
}

public struct TaskOnlyScanWorkObserver: ScanWorkObserving {
    public init() {}

    public func checkpoint(_ delta: ScanProgressDelta) async throws {
        try Task.checkCancellation()
    }
}

public protocol ScanProgressReporting: Sendable {
    func publish(_ snapshot: ScanProgressSnapshot) async
}

public protocol ScanCancellationChecking: Sendable {
    func checkCancellation(requestID: UUID) async throws
}

public struct NoopScanProgressReporter: ScanProgressReporting {
    public init() {}
    public func publish(_ snapshot: ScanProgressSnapshot) async {}
}

public struct TaskScanCancellationChecker: ScanCancellationChecking {
    public init() {}

    public func checkCancellation(requestID: UUID) async throws {
        try Task.checkCancellation()
    }
}

// MARK: - Environment

public protocol Clock: Sendable {
    func now() async -> Date
}

public struct SystemClock: Clock {
    public init() {}

    public func now() async -> Date { Date() }
}

public struct ProcessRequest: Codable, Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]?
    public let timeoutSeconds: Double

    public init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeoutSeconds: Double = 30
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct ProcessResult: Codable, Equatable, Sendable {
    public let terminationStatus: Int32
    public let standardOutput: Data
    public let standardError: Data

    public init(terminationStatus: Int32, standardOutput: Data, standardError: Data) {
        self.terminationStatus = terminationStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol ProcessRunning: Sendable {
    func run(_ request: ProcessRequest) async throws -> ProcessResult
}

/// An authoritative scan failure can retain structured private diagnostics for recovery UI.
public protocol InventoryScanFailure: Error {
    var scanFailureRecords: [ScanErrorRecord] { get }
}
