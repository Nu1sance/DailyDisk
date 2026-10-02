import Foundation

public struct IncrementalScanOutcome: Sendable {
    public let runID: ScanRun.ID
    public let checkpoint: Checkpoint
    public let changes: [ChangeRecord]
    public let storageSample: StorageSample
    public let affectedPathCount: Int
    public let snapshotSamples: [SnapshotSample]
    public let snapshotObservedVolumeIDs: Set<MonitoredVolume.ID>
    public let overheadSample: DailyDiskOverheadSample?
    public let scanErrors: [ScanErrorRecord]

    public init(
        runID: ScanRun.ID,
        checkpoint: Checkpoint,
        changes: [ChangeRecord],
        storageSample: StorageSample,
        affectedPathCount: Int,
        snapshotSamples: [SnapshotSample],
        snapshotObservedVolumeIDs: Set<MonitoredVolume.ID>,
        overheadSample: DailyDiskOverheadSample?,
        scanErrors: [ScanErrorRecord]
    ) {
        self.runID = runID
        self.checkpoint = checkpoint
        self.changes = changes
        self.storageSample = storageSample
        self.affectedPathCount = affectedPathCount
        self.snapshotSamples = snapshotSamples
        self.snapshotObservedVolumeIDs = snapshotObservedVolumeIDs
        self.overheadSample = overheadSample
        self.scanErrors = scanErrors
    }
}

public struct IncrementalScanner: Sendable {
    private let store: any InventoryStoring
    private let eventReader: any EventHistoryReading
    private let metadataReader: any FileMetadataReading
    private let subtreeScanner: any FileInventoryScanning
    private let diskUsageSampler: any DiskUsageSampling
    private let overheadSampler: (any DailyDiskOverheadSampling)?
    private let clock: any Clock

    public init(
        store: any InventoryStoring,
        eventReader: any EventHistoryReading,
        metadataReader: any FileMetadataReading,
        subtreeScanner: any FileInventoryScanning,
        diskUsageSampler: any DiskUsageSampling,
        overheadSampler: (any DailyDiskOverheadSampling)? = nil,
        clock: any Clock = SystemClock()
    ) {
        self.store = store
        self.eventReader = eventReader
        self.metadataReader = metadataReader
        self.subtreeScanner = subtreeScanner
        self.diskUsageSampler = diskUsageSampler
        self.overheadSampler = overheadSampler
        self.clock = clock
    }

    public func run(
        volume: MonitoredVolume,
        scope: StorageDomainScope
    ) async throws -> IncrementalScanOutcome {
        try await run(
            volume: volume,
            scope: scope,
            trigger: .scheduled,
            progressTracker: NoopScanProgressTracker()
        )
    }

    public func run(
        volume: MonitoredVolume,
        scope: StorageDomainScope,
        trigger: DailyDiskRunTrigger,
        progressTracker: any ScanProgressTracking
    ) async throws -> IncrementalScanOutcome {
        guard scope.volumeIDs.contains(volume.id), volume.inventoryMode == .full else {
            throw IncrementalScanError.invalidVolumeScope
        }
        guard let state = try await store.state(for: volume.id),
            let eventStoreUUID = state.checkpoint.eventStoreUUID
        else {
            ScanProbe.emit(.rejection, reason: .missingCheckpoint)
            throw IncrementalScanError.missingCheckpoint
        }
        guard state.checkpoint.topologyFingerprint == volume.topologyFingerprint else {
            ScanProbe.emit(.rejection, reason: .topologyChanged)
            throw IncrementalScanError.recoveryRequired(["Volume topology fingerprint changed"])
        }

        let startedAt = await clock.now()
        try await progressTracker.transition(to: .preparing, mode: .incremental)
        try await progressTracker.transition(to: .discoveringStorage, mode: .incremental)
        let run = ScanRun(
            kind: .incremental,
            reason: trigger == .manual ? .manual : .dailySchedule,
            status: .running,
            startedAt: startedAt
        )
        return try await ScanProbe.$context.withValue(ScanProbe.context.attempt(run.id, role: "incremental")) {
            ScanProbe.emit(.attemptStarted)
            ScanProbe.checkpoint(.checkpointRead, state.checkpoint)
            try await store.begin(run: run)
            try await progressTracker.bindRun(run.id)
            let target = InventoryMutationTarget.expectedActive(volumeID: volume.id)
            let mutator = IncrementalInventoryMutator(
                store: store,
                metadataReader: metadataReader,
                subtreeScanner: subtreeScanner
            )
            let progress = IncrementalProgress()
            var session: (any EventHistorySession)?

            do {
                let openedSession = try await eventReader.openSession(
                    volume: volume,
                    checkpoint: EventStreamCheckpoint(
                        eventStoreUUID: eventStoreUUID,
                        lastEventID: state.checkpoint.lastCommittedEventID
                    )
                )
                session = openedSession

                try await progressTracker.transition(to: .replayingEvents, mode: .incremental)
                let rawHistoryFence = try await openedSession.replayHistoricalEvents(
                    observer: progressTracker
                ) { batch in
                    let result = try await mutator.apply(
                        batch: batch,
                        volume: volume,
                        target: target,
                        runID: run.id,
                        observer: progressTracker
                    )
                    await progress.record(result)
                }
                _ = await progress.normalize(fence: rawHistoryFence)
                try await requireTrusted(progress)

                try await progressTracker.transition(to: .catchingUpEvents, mode: .incremental)
                let rawLiveFence = try await openedSession.flushLiveEvents(
                    observer: progressTracker
                ) { batch in
                    let result = try await mutator.apply(
                        batch: batch,
                        volume: volume,
                        target: target,
                        runID: run.id,
                        observer: progressTracker
                    )
                    await progress.record(result)
                }
                let liveFence = await progress.normalize(fence: rawLiveFence)
                try await requireTrusted(progress)

                try await progressTracker.transition(to: .sealingInventory, mode: .incremental)
                try await store.finalizeCanonicalAttribution(
                    target: target,
                    runID: run.id,
                    observer: progressTracker,
                    consume: { _ in }
                )
                let changes = try await store.deriveIncrementalChanges(
                    target: target,
                    runID: run.id,
                    observer: progressTracker
                )
                try await progressTracker.transition(to: .collectingDiagnostics, mode: .incremental)
                let diagnosticSamples = await collectDiagnosticSamples(
                    scope: scope,
                    runID: run.id,
                    progress: progress
                )
                let sample = try await diskUsageSampler.sample(storageDomain: scope.domain)
                let finishedAt = await clock.now()
                guard let committedEventStoreUUID = liveFence.eventStoreUUID else {
                    ScanProbe.emit(.rejection, reason: .journalUnavailable)
                    throw IncrementalScanError.recoveryRequired(["FSEvents journal identity disappeared"])
                }
                let persistedErrors = await progress.scanErrors
                let affectedPathCount = await progress.affectedPathCount
                let persistedCoverage = ScanCoverage(
                    visitedPathCount: UInt64(max(0, affectedPathCount)),
                    indexedObjectCount: 0,
                    unreadablePathCount: UInt64(persistedErrors.filter { $0.kind.preservesOpaqueInventory }.count),
                    transientErrorCount: UInt64(
                        persistedErrors.filter { $0.kind == .disappearedDuringScan }.count
                    )
                )
                let checkpoint = Checkpoint(
                    volumeID: volume.id,
                    eventStoreUUID: committedEventStoreUUID,
                    lastCommittedEventID: liveFence.highestFullyDeliveredEventID,
                    activeGenerationID: state.activeGeneration.id,
                    topologyFingerprint: volume.topologyFingerprint,
                    lastSuccessfulIncrementalAt: finishedAt,
                    lastSuccessfulFullScanAt: state.checkpoint.lastSuccessfulFullScanAt
                )
                let commit = try ScanCommit(
                    runID: run.id,
                    runKind: .incremental,
                    scope: scope,
                    volumeID: volume.id,
                    activatedGenerationID: nil,
                    previousCheckpoint: state.checkpoint,
                    checkpoint: checkpoint,
                    eventFence: liveFence,
                    changes: changes,
                    storageSamples: [sample],
                    snapshotSamples: diagnosticSamples.snapshots,
                    snapshotObservedVolumeIDs: diagnosticSamples.observedVolumeIDs,
                    overheadSample: diagnosticSamples.overhead,
                    coverage: persistedCoverage,
                    scanErrors: persistedErrors
                )
                try await progressTracker.transition(to: .committing, mode: .incremental)
                ScanProbe.checkpoint(.commitProposed, commit.checkpoint)
                try await store.commit(commit, finishedAt: finishedAt)
                if ScanProbe.context.recorder != nil {
                    ScanProbe.checkpoint(.commitSucceeded, (try? await store.state(for: volume.id))?.checkpoint)
                }
                return IncrementalScanOutcome(
                    runID: run.id,
                    checkpoint: checkpoint,
                    changes: changes,
                    storageSample: sample,
                    affectedPathCount: affectedPathCount,
                    snapshotSamples: diagnosticSamples.snapshots,
                    snapshotObservedVolumeIDs: diagnosticSamples.observedVolumeIDs,
                    overheadSample: diagnosticSamples.overhead,
                    scanErrors: persistedErrors
                )
            } catch {
                let error: any Error =
                    (error as? EventReplayInvalidated).map {
                        IncrementalScanError.recoveryRequired($0.reasons)
                    } ?? error
                ScanProbe.emit(
                    .attemptFailed,
                    fields: [
                        "cancelled": String(isScanCancellation(error)),
                        "failureType": String(reflecting: type(of: error)),
                    ])
                if let session { await session.stop() }
                await ScanProbe.context.recorder?.flush()
                let finishedAt = await clock.now()
                if isScanCancellation(error) {
                    try? await progressTracker.transition(to: .cancelling, mode: .incremental)
                    do {
                        try await store.interrupt(runID: run.id, finishedAt: finishedAt)
                        try? await progressTracker.transition(to: .cancelled, mode: .incremental)
                    } catch let cleanupError {
                        throw IncrementalScanError.cleanupFailed(
                            primary: String(describing: error),
                            cleanup: String(describing: cleanupError)
                        )
                    }
                    throw error
                }
                try? await progressTracker.transition(to: .cleaningUpFailedRun, mode: .incremental)
                let record = ScanErrorRecord(
                    runID: run.id,
                    volumeID: volume.id,
                    kind: error is IncrementalScanError ? .eventHistory : .other,
                    path: nil,
                    errorCode: nil,
                    message: String(describing: error)
                )
                do {
                    try await store.fail(runID: run.id, errors: [record], finishedAt: finishedAt)
                } catch let cleanupError {
                    throw IncrementalScanError.cleanupFailed(
                        primary: String(describing: error),
                        cleanup: String(describing: cleanupError)
                    )
                }
                throw error
            }
        }
    }

    private func collectDiagnosticSamples(
        scope: StorageDomainScope,
        runID: ScanRun.ID,
        progress: IncrementalProgress
    ) async -> DiagnosticSamples {
        var snapshots: [SnapshotSample] = []
        var observedVolumeIDs: Set<MonitoredVolume.ID> = []
        for candidate in scope.volumes {
            do {
                snapshots.append(contentsOf: try await diskUsageSampler.snapshots(volume: candidate))
                observedVolumeIDs.insert(candidate.id)
            } catch {
                await progress.append(
                    error: ScanErrorRecord(
                        runID: runID,
                        volumeID: candidate.id,
                        kind: .other,
                        path: nil,
                        errorCode: nil,
                        message: "Snapshot diagnostics unavailable"
                    )
                )
            }
        }
        let overhead: DailyDiskOverheadSample?
        if let overheadSampler {
            do {
                overhead = try await overheadSampler.sample(storageDomainID: scope.domain.id)
            } catch {
                overhead = nil
                await progress.append(
                    error: ScanErrorRecord(
                        runID: runID,
                        volumeID: nil,
                        kind: .other,
                        path: nil,
                        errorCode: nil,
                        message: "DailyDisk overhead sampling unavailable"
                    )
                )
            }
        } else {
            overhead = nil
        }
        return DiagnosticSamples(
            snapshots: snapshots,
            observedVolumeIDs: observedVolumeIDs,
            overhead: overhead
        )
    }

    private func requireTrusted(_ progress: IncrementalProgress) async throws {
        let assessment = await progress.assessment
        guard assessment.trust == .trusted else {
            if ScanProbe.context.trace?.snapshot.codes.isEmpty != false {
                ScanProbe.emit(.rejection, reason: .unknown)
            }
            throw IncrementalScanError.recoveryRequired(assessment.reasons)
        }
    }
}

private struct DiagnosticSamples: Sendable {
    let snapshots: [SnapshotSample]
    let observedVolumeIDs: Set<MonitoredVolume.ID>
    let overhead: DailyDiskOverheadSample?
}

private actor IncrementalProgress {
    private(set) var assessment = EventTrustAssessment(trust: .trusted)
    private(set) var affectedPathCount = 0
    private var repairedSubtreeRequirementCount = 0
    private(set) var scanErrors: [ScanErrorRecord] = []

    func record(_ result: InventoryMutationResult) {
        assessment = assessment.merging(result.assessment)
        affectedPathCount += result.affectedPathCount
        repairedSubtreeRequirementCount += result.repairedSubtreeRequirementCount
        scanErrors.append(contentsOf: result.scanErrors)
    }

    func append(error: ScanErrorRecord) {
        scanErrors.append(error)
    }

    func normalize(fence: EventCursorFence) -> EventCursorFence {
        if fence.trust == .subtreeRescanRequired, repairedSubtreeRequirementCount > 0 {
            repairedSubtreeRequirementCount = 0
            return EventCursorFence(
                volumeID: fence.volumeID,
                eventStoreUUID: fence.eventStoreUUID,
                highestFullyDeliveredEventID: fence.highestFullyDeliveredEventID,
                phase: fence.phase,
                trust: .trusted,
                diagnostic: "Required subtree scan completed"
            )
        }
        assessment = assessment.merging(
            EventTrustAssessment(
                trust: fence.trust,
                reasons: fence.diagnostic.map { [$0] } ?? []
            )
        )
        return fence
    }
}

public enum IncrementalScanError: Error, Equatable, Sendable {
    case invalidVolumeScope
    case missingCheckpoint
    case recoveryRequired([String])
    case cleanupFailed(primary: String, cleanup: String)
}
