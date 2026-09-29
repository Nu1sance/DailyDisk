import DailyDiskCore
import DailyDiskStore
import Foundation

public struct DailyDiskAgentRunner: Sendable {
    private enum ManualRequestOwnership {
        case claimed
        case recovered
    }

    public init() {}

    public func run(dryRun: Bool = false) async -> Int32 {
        if dryRun { return await DailyDiskScheduledRunner().run(dryRun: true) }
        do {
            let controlStore = try RunControlStore()
            try await controlStore.clearHelperIdle()
            var exitCode: Int32 = 0

            if let active = try await controlStore.activeRequest() {
                guard !SQLiteReportStore.writerIsActive() else {
                    // Another helper owns both the writer lease and this active
                    // request. Never terminalize state owned by that process.
                    return 0
                }
                if let terminalResult = await finishPersistedTerminalIfNeeded(
                    request: active,
                    controlStore: controlStore
                ) {
                    exitCode = max(exitCode, terminalResult)
                } else if try await controlStore.latestProgress()?.trigger == .scheduled {
                    exitCode = max(exitCode, await DailyDiskScheduledRunner().run(resuming: active))
                } else {
                    exitCode = max(
                        exitCode,
                        await runManual(
                            request: active,
                            resumedProgress: try await controlStore.latestProgress(),
                            ownership: .recovered,
                            controlStore: controlStore
                        )
                    )
                }
            } else if let request = try await controlStore.claimPendingRequest() {
                exitCode = max(
                    exitCode,
                    await runManual(
                        request: request,
                        resumedProgress: nil,
                        ownership: .claimed,
                        controlStore: controlStore
                    )
                )
            } else {
                exitCode = max(exitCode, await DailyDiskScheduledRunner().run())
            }

            // Every normal exit—scheduled, manual, recovered, success, cancel,
            // or failure—passes through this drain/idle handshake.
            while true {
                if try await controlStore.activeRequest() != nil {
                    return exitCode
                }
                if let request = try await controlStore.claimPendingRequest() {
                    exitCode = max(
                        exitCode,
                        await runManual(
                            request: request,
                            resumedProgress: nil,
                            ownership: .claimed,
                            controlStore: controlStore
                        )
                    )
                    continue
                }
                if try await controlStore.markHelperIdleIfNoPendingRequest() {
                    return exitCode
                }
            }
        } catch {
            return 1
        }
    }

    private func finishPersistedTerminalIfNeeded(
        request: DailyDiskRunRequest,
        controlStore: RunControlStore
    ) async -> Int32? {
        if let summary = try? await controlStore.latestSummary(),
            summary.requestID == request.requestID
        {
            try? await controlStore.complete(summary)
            return summary.terminalState == .failed ? 1 : 0
        }
        guard let progress = try? await controlStore.latestProgress(),
            progress.requestID == request.requestID,
            progress.phase.isTerminal
        else { return nil }
        let terminalState: DailyDiskRunTerminalState
        let errorCategory: ScanProgressErrorCategory?
        let failedDomains: Int
        switch progress.phase {
        case .completed:
            if let binding = try? await controlStore.runBinding(),
                binding.requestID == request.requestID,
                let reportReader = try? SQLiteReportStore(),
                (try? await reportReader.report(runID: binding.runID)) != nil
            {
                let summary = try? DailyDiskRunSummary(
                    requestID: request.requestID,
                    trigger: progress.trigger,
                    terminalState: .succeeded,
                    startedAt: progress.startedAt,
                    finishedAt: max(progress.updatedAt, Date()),
                    completedDomainCount: 1,
                    failedDomainCount: 0,
                    reportRunIDs: [binding.runID.rawValue]
                )
                if let summary { try? await controlStore.complete(summary) }
                return 0
            }
            let summary = try? DailyDiskRunSummary(
                requestID: request.requestID,
                trigger: progress.trigger,
                terminalState: request.action == .reclaimSpace ? .maintenanceCompleted : .succeeded,
                startedAt: progress.startedAt,
                finishedAt: max(progress.updatedAt, Date()),
                completedDomainCount: request.action == .reclaimSpace ? 0 : 1,
                failedDomainCount: 0,
                reportRunIDs: []
            )
            if let summary { try? await controlStore.complete(summary) }
            return 0
        case .cancelled:
            terminalState = .cancelled
            errorCategory = nil
            failedDomains = 0
        case .failed:
            terminalState = .failed
            errorCategory = progress.errorCategory ?? .unknown
            failedDomains = 1
        default:
            return nil
        }
        guard
            let summary = try? DailyDiskRunSummary(
                requestID: request.requestID,
                trigger: progress.trigger,
                terminalState: terminalState,
                startedAt: progress.startedAt,
                finishedAt: max(progress.updatedAt, Date()),
                completedDomainCount: 0,
                failedDomainCount: failedDomains,
                reportRunIDs: [],
                errorCategory: errorCategory
            )
        else { return 1 }
        try? await controlStore.complete(summary)
        return terminalState == .failed ? 1 : 0
    }

    private func runManual(
        request: DailyDiskRunRequest,
        resumedProgress: ScanProgressSnapshot?,
        ownership: ManualRequestOwnership,
        controlStore: RunControlStore
    ) async -> Int32 {
        if request.action == .reclaimSpace {
            return await SpaceMaintenanceRunner().run(
                request: request, resumedProgress: resumedProgress, control: controlStore)
        }
        let startedAt = resumedProgress?.startedAt ?? Date()
        let resumedRunID =
            resumedProgress == nil
            ? nil : try? await controlStore.runBinding()?.runID
        do {
            let store = try SQLiteInventoryStore()
            if resumedProgress == nil {
                await controlStore.publish(
                    try ScanProgressSnapshot(
                        requestID: request.requestID, trigger: .manual, mode: nil,
                        phase: .preparing, startedAt: startedAt, updatedAt: Date()
                    )
                )
            }
            try await store.prepare()
            let reportReader = try SQLiteReportStore()
            let discovery = APFSVolumeProvider()
            let coordinator = DailyDiskRunCoordinator(
                store: store,
                reportReader: reportReader,
                discovery: discovery,
                eventReader: FSEventHistoryReader(),
                metadataReader: POSIXFileMetadataReader(),
                fileScanner: FileInventoryScanner(),
                diskUsageSampler: APFSDiskUsageSampler(),
                overheadSampler: DailyDiskOverheadSampler(volumeDiscovery: discovery),
                reportCoordinator: DailyReportCoordinator(
                    store: store,
                    diagnosticsCoordinator: PhysicalDiagnosticsCoordinator(
                        deletedOpenFileProbe: DeletedOpenFileProbe()
                    ),
                    reportWriter: LocalReportWriter()
                ),
                progressFactory: { requestID, trigger, runStartedAt, domainCount in
                    if let resumedProgress {
                        return try ScanProgressTracker(
                            resuming: resumedProgress,
                            reporter: controlStore,
                            cancellationChecker: controlStore,
                            commitBoundary: controlStore,
                            runBindingRecorder: controlStore
                        )
                    }
                    return try ScanProgressTracker(
                        context: ScanProgressContext(
                            requestID: requestID,
                            trigger: trigger,
                            startedAt: runStartedAt,
                            domainCount: domainCount > 0 ? domainCount : nil
                        ),
                        reporter: controlStore,
                        cancellationChecker: controlStore,
                        commitBoundary: controlStore,
                        runBindingRecorder: controlStore
                    )
                },
                retentionHandler: {
                    let managedRoot = SQLiteInventoryStore.defaultDatabaseURL
                        .deletingLastPathComponent()
                    _ = try RetentionPolicy.default.prune(managedRoot: managedRoot)
                    try await store.pruneRetiredGenerations()
                },
                spaceMaintenance: { tracker in
                    try await store.maintainSpace(observer: tracker)
                }
            )
            let summary = await coordinator.run(
                mode: .manual(
                    requestID: request.requestID,
                    requestedMode: request.requestedMode,
                    resumeCommittedRunID: resumedProgress.map {
                        $0.phase == .committing || $0.phase == .publishingReport
                            ? resumedRunID
                            : nil
                    } ?? nil
                ),
                startedAt: startedAt
            )
            try await controlStore.complete(summary)
            switch summary.terminalState {
            case .maintenanceCompleted, .succeeded, .cancelled:
                return 0
            case .failed, .skippedNotDue, .blockedByWriter:
                return 1
            }
        } catch is WriterLeaseError {
            // Lease contention is attachment, never ownership. Another helper
            // may have acquired the lease between claim/recovery and setup;
            // only the lease winner may terminalize the active request.
            _ = ownership
            return 0
        } catch {
            let summary = try? DailyDiskRunSummary(
                requestID: request.requestID,
                trigger: .manual,
                terminalState: .failed,
                startedAt: startedAt,
                finishedAt: Date(),
                completedDomainCount: 0,
                failedDomainCount: 1,
                reportRunIDs: [],
                errorCategory: .unknown
            )
            if let summary { try? await controlStore.complete(summary) }
            return 1
        }
    }
}
