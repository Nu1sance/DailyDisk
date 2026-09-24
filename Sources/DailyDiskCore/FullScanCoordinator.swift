import Foundation

public enum FullScanMode: Sendable {
    case initial
    case scheduled
    case recovery(RecoveryTrigger)
}

public struct FullScanOutcome: Sendable {
    public let runID: ScanRun.ID
    public let checkpoint: Checkpoint
    public let reconciliation: ReconciliationResult
    public let storageSample: StorageSample
    public let coverage: ScanCoverage
    public let snapshotSamples: [SnapshotSample]
    public let snapshotObservedVolumeIDs: Set<MonitoredVolume.ID>
    public let overheadSample: DailyDiskOverheadSample?
    public let scanErrors: [ScanErrorRecord]

    public init(
        runID: ScanRun.ID,
        checkpoint: Checkpoint,
        reconciliation: ReconciliationResult,
        storageSample: StorageSample,
        coverage: ScanCoverage,
        snapshotSamples: [SnapshotSample],
        snapshotObservedVolumeIDs: Set<MonitoredVolume.ID>,
        overheadSample: DailyDiskOverheadSample?,
        scanErrors: [ScanErrorRecord]
    ) {
        self.runID = runID
        self.checkpoint = checkpoint
        self.reconciliation = reconciliation
        self.storageSample = storageSample
        self.coverage = coverage
        self.snapshotSamples = snapshotSamples
        self.snapshotObservedVolumeIDs = snapshotObservedVolumeIDs
        self.overheadSample = overheadSample
        self.scanErrors = scanErrors
    }
}

public struct FullScanCoordinator: Sendable {
    private let store: any InventoryStoring
    private let eventReader: any EventHistoryReading
    private let metadataReader: any FileMetadataReading
    private let fullScanner: any FileInventoryScanning
    private let diskUsageSampler: any DiskUsageSampling
    private let overheadSampler: (any DailyDiskOverheadSampling)?
    private let volumeDiscovery: any VolumeDiscovering
    private let clock: any Clock
    private let maximumRecoveryAttempts: Int

    public init(
        store: any InventoryStoring,
        eventReader: any EventHistoryReading,
        metadataReader: any FileMetadataReading,
        fullScanner: any FileInventoryScanning,
        diskUsageSampler: any DiskUsageSampling,
        overheadSampler: (any DailyDiskOverheadSampling)? = nil,
        volumeDiscovery: any VolumeDiscovering,
        clock: any Clock = SystemClock(),
        maximumRecoveryAttempts: Int = 2
    ) {
        self.store = store
        self.eventReader = eventReader
        self.metadataReader = metadataReader
        self.fullScanner = fullScanner
        self.diskUsageSampler = diskUsageSampler
        self.overheadSampler = overheadSampler
        self.volumeDiscovery = volumeDiscovery
        self.clock = clock
        self.maximumRecoveryAttempts = maximumRecoveryAttempts
    }

    public func run(
        volume: MonitoredVolume,
        scope: StorageDomainScope,
        mode: FullScanMode
    ) async throws -> FullScanOutcome {
        try await run(
            volume: volume,
            scope: scope,
            mode: mode,
            trigger: .scheduled,
            progressTracker: NoopScanProgressTracker()
        )
    }

    public func run(
        volume: MonitoredVolume,
        scope: StorageDomainScope,
        mode: FullScanMode,
        trigger: DailyDiskRunTrigger,
        progressTracker: any ScanProgressTracking
    ) async throws -> FullScanOutcome {
        try await execute(
            volume: volume,
            scope: scope,
            mode: mode,
            trigger: trigger,
            progressTracker: progressTracker,
            recoveryAttempt: 0
        )
    }

    private func execute(
        volume: MonitoredVolume,
        scope: StorageDomainScope,
        mode: FullScanMode,
        trigger: DailyDiskRunTrigger,
        progressTracker: any ScanProgressTracking,
        recoveryAttempt: Int
    ) async throws -> FullScanOutcome {
        guard scope.volumeIDs.contains(volume.id), volume.inventoryMode == .full else {
            throw FullScanError.invalidVolumeScope
        }
        let previousState = try await store.state(for: volume.id)
        switch mode {
        case .initial where previousState != nil:
            throw FullScanError.invalidMode
        case .scheduled where previousState == nil:
            throw FullScanError.invalidMode
        default:
            break
        }

        let startedAt = await clock.now()
        let executionMode = executionMode(for: mode)
        try await progressTracker.transition(to: .preparing, mode: executionMode)
        if case .recovery = mode {
            try await progressTracker.transition(to: .recoveringInterruptedRun, mode: executionMode)
        }
        try await progressTracker.transition(to: .discoveringStorage, mode: executionMode)
        let runKind: ScanRun.Kind = if case .recovery = mode { .recovery } else { .full }
        let run = ScanRun(
            kind: runKind,
            reason: trigger == .manual ? .manual : reason(for: mode),
            status: .running,
            startedAt: startedAt
        )
        try await store.begin(run: run)
        try await progressTracker.bindRun(run.id)
        let progress = FullScanProgress()
        var session: (any EventHistorySession)?

        do {
            let checkpoint: EventStreamCheckpoint?
            if usesCommittedHistory(mode),
                let previous = previousState?.checkpoint,
                let uuid = previous.eventStoreUUID
            {
                checkpoint = EventStreamCheckpoint(
                    eventStoreUUID: uuid,
                    lastEventID: previous.lastCommittedEventID
                )
            } else {
                checkpoint = nil
            }
            let openedSession = try await eventReader.openSession(volume: volume, checkpoint: checkpoint)
            session = openedSession

            let expectedTarget = InventoryMutationTarget.expectedActive(volumeID: volume.id)
            let expectedMutator = IncrementalInventoryMutator(
                store: store,
                metadataReader: metadataReader,
                subtreeScanner: fullScanner
            )
            try await progressTracker.transition(to: .replayingEvents, mode: executionMode)
            let historicalFence = try await openedSession.replayHistoricalEvents(
                observer: progressTracker
            ) { batch in
                guard usesCommittedHistory(mode) else { return }
                let result = try await expectedMutator.apply(
                    batch: batch,
                    volume: volume,
                    target: expectedTarget,
                    runID: run.id,
                    observer: progressTracker
                )
                await progress.record(result)
            }
            _ = await progress.normalize(fence: historicalFence)
            if await progress.requiresRecovery {
                throw FullScanError.restartRecovery(await progress.reasons)
            }

            let rawStartFence = try await openedSession.flushLiveEvents(
                observer: progressTracker
            ) { batch in
                guard previousState != nil else { return }
                let result = try await expectedMutator.apply(
                    batch: batch,
                    volume: volume,
                    target: expectedTarget,
                    runID: run.id,
                    observer: progressTracker
                )
                await progress.record(result)
            }
            let startFence = await progress.normalize(fence: rawStartFence)
            if await progress.requiresRecovery {
                throw FullScanError.restartRecovery(await progress.reasons)
            }
            guard let startUUID = startFence.eventStoreUUID,
                let startEventID = startFence.highestFullyDeliveredEventID
            else {
                throw FullScanError.restartRecovery(["Unable to establish pre-scan FSEvents cursor"])
            }

            await openedSession.stop()
            session = nil
            let generation = try await store.createStagingGeneration(
                volumeID: volume.id,
                runID: run.id,
                at: await clock.now()
            )
            let authoritativeTarget = InventoryMutationTarget.stagingGeneration(generation.id)
            try await progressTracker.transition(to: .scanningFiles, mode: executionMode)
            let fullResult = try await fullScanner.scan(
                volume: volume,
                runID: run.id,
                observer: progressTracker
            ) { batch in
                try await store.append(records: batch.records, to: generation.id)
            }
            await progress.append(errors: fullResult.errors)
            let opaqueRoots = fullResult.errors.compactMap { error in
                error.kind.preservesOpaqueInventory ? error.path : nil
            }
            if previousState != nil, !opaqueRoots.isEmpty {
                try await progressTracker.transition(to: .preservingOpaqueInventory, mode: executionMode)
                try await store.preserveOpaqueSubtrees(
                    roots: opaqueRoots,
                    from: expectedTarget,
                    to: authoritativeTarget,
                    for: run.id,
                    observer: progressTracker
                )
            }

            let authoritativeMutator = IncrementalInventoryMutator(
                store: store,
                metadataReader: metadataReader,
                subtreeScanner: fullScanner
            )
            let catchupSession = try await eventReader.openSession(
                volume: volume,
                checkpoint: EventStreamCheckpoint(
                    eventStoreUUID: startUUID,
                    lastEventID: startEventID
                )
            )
            session = catchupSession
            try await progressTracker.transition(to: .catchingUpEvents, mode: executionMode)
            let catchupHistoryFence = try await catchupSession.replayHistoricalEvents(
                observer: progressTracker
            ) { batch in
                let authoritativeResult = try await authoritativeMutator.apply(
                    batch: batch,
                    volume: volume,
                    target: authoritativeTarget,
                    runID: run.id,
                    observer: progressTracker
                )
                await progress.record(authoritativeResult)
                if previousState != nil {
                    try await store.copyMutations(
                        from: authoritativeTarget,
                        to: expectedTarget,
                        for: run.id,
                        observer: progressTracker
                    )
                }
            }
            _ = await progress.normalize(fence: catchupHistoryFence)
            if await progress.requiresRecovery {
                throw FullScanError.restartRecovery(await progress.reasons)
            }
            let rawLiveFence = try await catchupSession.flushLiveEvents(
                observer: progressTracker
            ) { batch in
                let authoritativeResult = try await authoritativeMutator.apply(
                    batch: batch,
                    volume: volume,
                    target: authoritativeTarget,
                    runID: run.id,
                    observer: progressTracker
                )
                await progress.record(authoritativeResult)
                if previousState != nil {
                    try await store.copyMutations(
                        from: authoritativeTarget,
                        to: expectedTarget,
                        for: run.id,
                        observer: progressTracker
                    )
                }
            }
            let liveFence = await progress.normalize(fence: rawLiveFence)
            if await progress.requiresRecovery {
                throw FullScanError.restartRecovery(await progress.reasons)
            }

            await catchupSession.stop()
            session = nil
            try await progressTracker.transition(to: .sealingInventory, mode: executionMode)
            if previousState != nil {
                try await store.finalizeCanonicalAttribution(
                    target: expectedTarget,
                    runID: run.id,
                    observer: progressTracker,
                    consume: { _ in }
                )
            }
            try await store.finalizeCanonicalAttribution(
                target: authoritativeTarget,
                runID: run.id,
                observer: progressTracker,
                consume: { _ in }
            )

            try await progressTracker.transition(to: .reconciling, mode: executionMode)
            let eventChanges: [ChangeRecord]
            let reconciliationChanges: [ChangeRecord]
            if previousState != nil {
                eventChanges = try await store.deriveIncrementalChanges(
                    target: expectedTarget,
                    runID: run.id,
                    observer: progressTracker
                )
                reconciliationChanges = try await store.deriveReconciliationChanges(
                    expected: expectedTarget,
                    authoritative: authoritativeTarget,
                    runID: run.id,
                    observer: progressTracker
                )
            } else {
                eventChanges = []
                reconciliationChanges = []
            }
            let reconciliation = try ReconciliationResult(
                eventChanges: eventChanges,
                reconciliationChanges: reconciliationChanges
            )
            try await progressTracker.transition(to: .collectingDiagnostics, mode: executionMode)
            let diagnosticSamples = await collectDiagnosticSamples(
                scope: scope,
                runID: run.id,
                progress: progress
            )
            let sample = try await diskUsageSampler.sample(storageDomain: scope.domain)
            let finishedAt = await clock.now()
            guard let eventStoreUUID = liveFence.eventStoreUUID else {
                throw FullScanError.restartRecovery(["FSEvents journal identity disappeared during full scan"])
            }
            let newCheckpoint = Checkpoint(
                volumeID: volume.id,
                eventStoreUUID: eventStoreUUID,
                lastCommittedEventID: liveFence.highestFullyDeliveredEventID,
                activeGenerationID: generation.id,
                topologyFingerprint: volume.topologyFingerprint,
                lastSuccessfulIncrementalAt: previousState?.checkpoint.lastSuccessfulIncrementalAt,
                lastSuccessfulFullScanAt: finishedAt
            )
            let commit = try ScanCommit(
                runID: run.id,
                runKind: runKind,
                scope: scope,
                volumeID: volume.id,
                activatedGenerationID: generation.id,
                previousCheckpoint: previousState?.checkpoint,
                checkpoint: newCheckpoint,
                eventFence: liveFence,
                changes: reconciliation.allChanges,
                storageSamples: [sample],
                snapshotSamples: diagnosticSamples.snapshots,
                snapshotObservedVolumeIDs: diagnosticSamples.observedVolumeIDs,
                overheadSample: diagnosticSamples.overhead,
                coverage: fullResult.coverage,
                scanErrors: await progress.scanErrors
            )
            try await progressTracker.transition(to: .committing, mode: executionMode)
            try await store.commit(commit, finishedAt: finishedAt)
            return FullScanOutcome(
                runID: run.id,
                checkpoint: newCheckpoint,
                reconciliation: reconciliation,
                storageSample: sample,
                coverage: fullResult.coverage,
                snapshotSamples: diagnosticSamples.snapshots,
                snapshotObservedVolumeIDs: diagnosticSamples.observedVolumeIDs,
                overheadSample: diagnosticSamples.overhead,
                scanErrors: await progress.scanErrors
            )
        } catch {
            if let session { await session.stop() }
            let finishedAt = await clock.now()
            if isScanCancellation(error) {
                try? await progressTracker.transition(to: .cancelling, mode: executionMode)
                do {
                    try await store.interrupt(runID: run.id, finishedAt: finishedAt)
                    try? await progressTracker.transition(to: .cancelled, mode: executionMode)
                } catch let cleanupError {
                    throw FullScanError.cleanupFailed(
                        primary: String(describing: error),
                        cleanup: String(describing: cleanupError)
                    )
                }
                throw error
            }
            try? await progressTracker.transition(to: .cleaningUpFailedRun, mode: executionMode)
            let scanFailureRecords = (error as? any InventoryScanFailure)?.scanFailureRecords ?? []
            let errorRecord = ScanErrorRecord(
                runID: run.id,
                volumeID: volume.id,
                kind: error is FullScanError ? .eventHistory : .other,
                path: nil,
                errorCode: nil,
                message: scanFailureRecords.isEmpty
                    ? String(describing: error) : "Full inventory was incomplete; see structured scan errors"
            )
            do {
                try await store.fail(runID: run.id, errors: scanFailureRecords + [errorRecord], finishedAt: finishedAt)
            } catch let cleanupError {
                throw FullScanError.cleanupFailed(
                    primary: String(describing: error),
                    cleanup: String(describing: cleanupError)
                )
            }

            if case FullScanError.restartRecovery = error,
                recoveryAttempt < maximumRecoveryAttempts
            {
                let refreshed = try await refreshedVolumeAndScope(
                    originalVolume: volume,
                    originalScope: scope
                )
                return try await execute(
                    volume: refreshed.volume,
                    scope: refreshed.scope,
                    mode: .recovery(.eventHistoryLost),
                    trigger: trigger,
                    progressTracker: progressTracker,
                    recoveryAttempt: recoveryAttempt + 1
                )
            }
            throw error
        }
    }

    private func collectDiagnosticSamples(
        scope: StorageDomainScope,
        runID: ScanRun.ID,
        progress: FullScanProgress
    ) async -> FullDiagnosticSamples {
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
        return FullDiagnosticSamples(
            snapshots: snapshots,
            observedVolumeIDs: observedVolumeIDs,
            overhead: overhead
        )
    }

    private func executionMode(for mode: FullScanMode) -> ScanExecutionMode {
        switch mode {
        case .initial: .initialFull
        case .scheduled: .scheduledFull
        case .recovery: .recoveryFull
        }
    }

    private func usesCommittedHistory(_ mode: FullScanMode) -> Bool {
        switch mode {
        case .scheduled:
            true
        case .recovery(.inventoryDrift), .recovery(.interruptedFullScan):
            true
        case .initial, .recovery:
            false
        }
    }

    private func refreshedVolumeAndScope(
        originalVolume: MonitoredVolume,
        originalScope: StorageDomainScope
    ) async throws -> (volume: MonitoredVolume, scope: StorageDomainScope) {
        let topology = try await volumeDiscovery.discoverInternalAPFSVolumes()
        guard
            let volume = topology.volumes.first(where: {
                $0.filesystemUUID == originalVolume.filesystemUUID || $0.id == originalVolume.id
            }), let domain = topology.domains.first(where: { $0.id == volume.storageDomainID })
        else {
            throw FullScanError.topologyRefreshFailed
        }
        let scope = try StorageDomainScope(
            domain: domain,
            volumes: topology.volumes.filter { $0.storageDomainID == domain.id }
        )
        try await store.register(scope: scope)
        return (volume, scope)
    }

    private func reason(for mode: FullScanMode) -> ScanRun.Reason {
        switch mode {
        case .initial: .initialBaseline
        case .scheduled: .weeklyReconciliation
        case .recovery(let trigger):
            switch trigger {
            case .eventHistoryLost: .eventHistoryLost
            case .eventStoreChanged: .eventStoreChanged
            case .topologyChanged: .topologyChanged
            case .inventoryDrift, .interruptedFullScan: .inventoryDrift
            }
        }
    }
}

private struct FullDiagnosticSamples: Sendable {
    let snapshots: [SnapshotSample]
    let observedVolumeIDs: Set<MonitoredVolume.ID>
    let overhead: DailyDiskOverheadSample?
}

private actor FullScanProgress {
    private var assessment = EventTrustAssessment(trust: .trusted)
    private var repairedSubtreeRequirementCount = 0
    private(set) var scanErrors: [ScanErrorRecord] = []

    var requiresRecovery: Bool { assessment.trust != .trusted }
    var reasons: [String] { assessment.reasons }

    func record(_ result: InventoryMutationResult) {
        assessment = assessment.merging(result.assessment)
        repairedSubtreeRequirementCount += result.repairedSubtreeRequirementCount
        scanErrors.append(contentsOf: result.scanErrors)
    }

    func append(errors: [ScanErrorRecord]) {
        scanErrors.append(contentsOf: errors)
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

public enum FullScanError: Error, Equatable, Sendable {
    case invalidVolumeScope
    case invalidMode
    case restartRecovery([String])
    case incompleteAuthoritativeScan(unreadablePaths: UInt64)
    case topologyRefreshFailed
    case cleanupFailed(primary: String, cleanup: String)
}
