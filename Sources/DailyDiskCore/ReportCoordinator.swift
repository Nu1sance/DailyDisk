import Foundation

public struct ReportGenerationResult: Sendable {
    public let report: DailyReport
    public let artifacts: ReportArtifacts
    public let currentSample: StorageSample

    public init(report: DailyReport, artifacts: ReportArtifacts, currentSample: StorageSample) {
        self.report = report
        self.artifacts = artifacts
        self.currentSample = currentSample
    }
}

public struct DailyReportCoordinator: Sendable {
    private let store: any InventoryStoring
    private let diagnosticsCoordinator: PhysicalDiagnosticsCoordinator
    private let reportWriter: any ReportWriting
    private let clock: any Clock

    public init(
        store: any InventoryStoring,
        diagnosticsCoordinator: PhysicalDiagnosticsCoordinator,
        reportWriter: any ReportWriting,
        clock: any Clock = SystemClock()
    ) {
        self.store = store
        self.diagnosticsCoordinator = diagnosticsCoordinator
        self.reportWriter = reportWriter
        self.clock = clock
    }

    public func generate(
        basis: PersistedReportBasis,
        scope: StorageDomainScope
    ) async throws -> ReportGenerationResult {
        try await generate(
            runID: basis.runID,
            checkpointDate: basis.checkpointDate,
            scope: scope,
            changes: basis.changes,
            currentStorageSample: basis.currentStorageSample,
            currentSnapshots: basis.currentSnapshots,
            snapshotObservedVolumeIDs: basis.snapshotObservedVolumeIDs,
            currentOverhead: basis.currentOverhead,
            coverage: basis.coverage,
            scanErrors: basis.scanErrors,
            progressTracker: nil
        )
    }

    public func generate(
        outcome: IncrementalScanOutcome,
        scope: StorageDomainScope
    ) async throws -> ReportGenerationResult {
        let unreadable = UInt64(outcome.scanErrors.filter { $0.kind.preservesOpaqueInventory }.count)
        let transient = UInt64(outcome.scanErrors.filter { $0.kind == .disappearedDuringScan }.count)
        let checkpointDate: Date
        if let value = outcome.checkpoint.lastSuccessfulIncrementalAt {
            checkpointDate = value
        } else {
            checkpointDate = await clock.now()
        }
        return try await generate(
            runID: outcome.runID,
            checkpointDate: checkpointDate,
            scope: scope,
            changes: outcome.changes,
            currentStorageSample: outcome.storageSample,
            currentSnapshots: outcome.snapshotSamples,
            snapshotObservedVolumeIDs: outcome.snapshotObservedVolumeIDs,
            currentOverhead: outcome.overheadSample,
            coverage: ScanCoverage(
                visitedPathCount: UInt64(max(0, outcome.affectedPathCount)),
                indexedObjectCount: 0,
                unreadablePathCount: unreadable,
                transientErrorCount: transient
            ),
            scanErrors: outcome.scanErrors,
            progressTracker: nil
        )
    }

    public func generate(
        outcome: IncrementalScanOutcome,
        scope: StorageDomainScope,
        progressTracker: any ScanProgressTracking
    ) async throws -> ReportGenerationResult {
        let unreadable = UInt64(outcome.scanErrors.filter { $0.kind.preservesOpaqueInventory }.count)
        let transient = UInt64(outcome.scanErrors.filter { $0.kind == .disappearedDuringScan }.count)
        let checkpointDate: Date
        if let value = outcome.checkpoint.lastSuccessfulIncrementalAt {
            checkpointDate = value
        } else {
            checkpointDate = await clock.now()
        }
        return try await generate(
            runID: outcome.runID,
            checkpointDate: checkpointDate,
            scope: scope,
            changes: outcome.changes,
            currentStorageSample: outcome.storageSample,
            currentSnapshots: outcome.snapshotSamples,
            snapshotObservedVolumeIDs: outcome.snapshotObservedVolumeIDs,
            currentOverhead: outcome.overheadSample,
            coverage: ScanCoverage(
                visitedPathCount: UInt64(max(0, outcome.affectedPathCount)),
                indexedObjectCount: 0,
                unreadablePathCount: unreadable,
                transientErrorCount: transient
            ),
            scanErrors: outcome.scanErrors,
            progressTracker: progressTracker
        )
    }

    public func generate(
        outcome: FullScanOutcome,
        scope: StorageDomainScope
    ) async throws -> ReportGenerationResult {
        try await generate(
            runID: outcome.runID,
            checkpointDate: outcome.checkpoint.lastSuccessfulFullScanAt,
            scope: scope,
            changes: outcome.reconciliation.allChanges,
            currentStorageSample: outcome.storageSample,
            currentSnapshots: outcome.snapshotSamples,
            snapshotObservedVolumeIDs: outcome.snapshotObservedVolumeIDs,
            currentOverhead: outcome.overheadSample,
            coverage: outcome.coverage,
            scanErrors: outcome.scanErrors,
            progressTracker: nil
        )
    }

    public func generate(
        outcome: FullScanOutcome,
        scope: StorageDomainScope,
        progressTracker: any ScanProgressTracking
    ) async throws -> ReportGenerationResult {
        try await generate(
            runID: outcome.runID,
            checkpointDate: outcome.checkpoint.lastSuccessfulFullScanAt,
            scope: scope,
            changes: outcome.reconciliation.allChanges,
            currentStorageSample: outcome.storageSample,
            currentSnapshots: outcome.snapshotSamples,
            snapshotObservedVolumeIDs: outcome.snapshotObservedVolumeIDs,
            currentOverhead: outcome.overheadSample,
            coverage: outcome.coverage,
            scanErrors: outcome.scanErrors,
            progressTracker: progressTracker
        )
    }

    private func generate(
        runID: ScanRun.ID,
        checkpointDate: Date,
        scope: StorageDomainScope,
        changes: [ChangeRecord],
        currentStorageSample: StorageSample,
        currentSnapshots: [SnapshotSample],
        snapshotObservedVolumeIDs: Set<MonitoredVolume.ID>,
        currentOverhead: DailyDiskOverheadSample?,
        coverage: ScanCoverage,
        scanErrors: [ScanErrorRecord],
        progressTracker: (any ScanProgressTracking)?
    ) async throws -> ReportGenerationResult {
        if let progressTracker {
            try await progressTracker.transition(to: .publishingReport, mode: nil)
        }
        guard scope.volumes.filter({ $0.inventoryMode == .full }).count == 1 else {
            throw ReportCoordinatorError.invalidInventoryScope
        }
        if let existing = try await store.report(
            runID: runID,
            storageDomainID: scope.domain.id
        ) {
            return ReportGenerationResult(
                report: existing,
                artifacts: try await reportWriter.write(report: existing),
                currentSample: currentStorageSample
            )
        }
        let previousStorageSample = try await store.latestStorageSample(
            storageDomainID: scope.domain.id,
            before: currentStorageSample.sampledAt
        )
        let storedPreviousSnapshots = try await store.latestSnapshotSamples(
            volumeIDs: snapshotObservedVolumeIDs,
            before: checkpointDate
        )
        let previousSnapshots =
            previousStorageSample == nil
            ? currentSnapshots : storedPreviousSnapshots
        let previousOverhead: DailyDiskOverheadSample?
        if let currentOverhead {
            previousOverhead = try await store.latestOverheadSample(
                storageDomainID: scope.domain.id,
                before: currentOverhead.sampledAt
            )
        } else {
            previousOverhead = nil
        }
        if let existingArtifactReport = try await reportWriter.existingReport(runID: runID) {
            let commit = try ReportCommit(
                runID: runID,
                scope: scope,
                changes: changes,
                previousStorageSample: previousStorageSample,
                currentStorageSample: currentStorageSample,
                previousOverheadSample: previousOverhead,
                currentOverheadSample: currentOverhead,
                report: existingArtifactReport
            )
            try await store.commitReport(commit)
            return ReportGenerationResult(
                report: existingArtifactReport,
                artifacts: try await reportWriter.write(report: existingArtifactReport),
                currentSample: currentStorageSample
            )
        }
        let overheadDelta: Int64
        if let previousOverhead, let currentOverhead {
            overheadDelta = try AccountingMath.subtract(
                currentOverhead.allocatedBytes,
                previousOverhead.allocatedBytes
            )
        } else {
            overheadDelta = 0
        }
        let accounting = try SpaceAccounting.summarize(
            changes: changes,
            scope: scope,
            previousSample: previousStorageSample,
            currentSample: currentStorageSample,
            additionalDailyDiskOverheadDelta: overheadDelta
        )
        let reconciliation = try SpaceAccounting.reconciliationBreakdown(from: changes)
        var diagnostics = scanErrors.map(safeDiagnosticMessage)
        if snapshotObservedVolumeIDs != scope.volumeIDs {
            diagnostics.append("Snapshot comparison is partial because one or more volumes were unavailable")
        }
        let physicalDiagnosis: PhysicalAttributionDiagnosis?
        do {
            physicalDiagnosis = try await diagnosticsCoordinator.diagnose(
                accounting: accounting,
                scope: scope,
                previousSnapshots: previousSnapshots,
                currentSnapshots: currentSnapshots,
                unreadablePathCount: coverage.unreadablePathCount
            )
        } catch {
            physicalDiagnosis = try PhysicalAttribution.analyze(
                accounting: accounting,
                previousSnapshots: previousSnapshots,
                currentSnapshots: currentSnapshots,
                deletedOpenFiles: [],
                monitoredDeviceIDs: Set(scope.volumes.map(\.deviceID).filter { $0 != 0 }),
                unreadablePathCount: coverage.unreadablePathCount
            )
            diagnostics.append("Deleted-open-file diagnostics unavailable")
        }

        let ranked = try rankedPathChanges(changes)
        let report = try DailyReport(
            runID: runID,
            generatedAt: checkpointDate,
            storageDomainID: scope.domain.id,
            accounting: accounting,
            reconciliation: reconciliation,
            coverage: coverage,
            largestGrowth: Array(ranked.filter { $0.allocatedDelta > 0 }.prefix(10)),
            largestShrinkage: Array(ranked.reversed().filter { $0.allocatedDelta < 0 }.prefix(10)),
            physicalDiagnosis: physicalDiagnosis,
            diagnostics: diagnostics
        )
        let commit = try ReportCommit(
            runID: runID,
            scope: scope,
            changes: changes,
            previousStorageSample: previousStorageSample,
            currentStorageSample: currentStorageSample,
            previousOverheadSample: previousOverhead,
            currentOverheadSample: currentOverhead,
            report: report
        )
        let artifacts = try await reportWriter.write(report: report)
        try await store.commitReport(commit)
        return ReportGenerationResult(
            report: report,
            artifacts: artifacts,
            currentSample: currentStorageSample
        )
    }

    private func safeDiagnosticMessage(_ error: ScanErrorRecord) -> String {
        switch error.kind {
        case .permissionDenied: "One or more paths were not readable"
        case .contentUnavailable: "Cloud or provider content was unavailable; previous inventory was preserved"
        case .disappearedDuringScan: "Files changed while the scan was running"
        case .crossedVolumeBoundary: "A nested filesystem boundary was skipped"
        case .invalidMetadata: "Filesystem metadata was invalid"
        case .eventHistory: "FSEvents history was unavailable"
        case .database: "Database processing reported an error"
        case .other: "A scan diagnostic was recorded"
        }
    }

    private func rankedPathChanges(_ changes: [ChangeRecord]) throws -> [RankedPathChange] {
        struct Delta {
            var logical: Int64 = 0
            var allocated: Int64 = 0
        }
        var values: [RelativePath: Delta] = [:]
        for change in changes where change.classification == .ordinary {
            let path: RelativePath?
            if case .attributionTransfer(_, .debit) = change.effect {
                path = change.pathBefore
            } else {
                path = change.pathAfter ?? change.pathBefore
            }
            guard let path else { continue }
            for candidate in [path] + PathPolicy.ancestors(of: path) {
                var delta = values[candidate, default: Delta()]
                delta.logical = try AccountingMath.add(delta.logical, change.logicalDelta)
                delta.allocated = try AccountingMath.add(delta.allocated, change.allocatedDelta)
                values[candidate] = delta
            }
        }
        return values.map {
            RankedPathChange(
                path: $0.key,
                allocatedDelta: $0.value.allocated,
                logicalDelta: $0.value.logical
            )
        }.sorted { lhs, rhs in
            if lhs.allocatedDelta != rhs.allocatedDelta {
                return lhs.allocatedDelta > rhs.allocatedDelta
            }
            return lhs.path.bytes.lexicographicallyPrecedes(rhs.path.bytes)
        }
    }
}

public enum ReportCoordinatorError: Error, Equatable, Sendable {
    case invalidInventoryScope
}
