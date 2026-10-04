import DailyDiskCore
import DailyDiskStore
import Foundation

public struct DailyDiskScheduledRunner: Sendable {
    public init() {}

    public func run(
        dryRun: Bool = false,
        resuming request: DailyDiskRunRequest? = nil
    ) async -> Int32 {
        let logger = try? StructuredLogger()
        if dryRun {
            try? await logger?.log(level: .info, event: "scheduled-dry-run")
            return 0
        }

        do {
            let admission = try RunControlStore()
            guard let updateLease = try await admission.acquireHelperUpdateLease() else { return 0 }
            defer { withExtendedLifetime(updateLease) {} }
            let store = try SQLiteInventoryStore()
            try await store.prepare()
            let control = try RunControlStore()
            let runRequest = try request ?? DailyDiskRunRequest()
            let resumedProgress = request == nil ? nil : try await control.latestProgress()
            if request == nil {
                do {
                    try await control.beginScheduledRun(runRequest)
                } catch RunControlStoreError.runAlreadyActive {
                    // A GUI request arrived while the scheduled worker acquired its lease.
                    // The agent's normal drain loop will claim it.
                    return 0
                }
            }
            let reportReader = try SQLiteReportStore()
            let discovery = APFSVolumeProvider()
            let reportCoordinator = DailyReportCoordinator(
                store: store,
                diagnosticsCoordinator: PhysicalDiagnosticsCoordinator(
                    deletedOpenFileProbe: DeletedOpenFileProbe()
                ),
                reportWriter: LocalReportWriter()
            )
            let coordinator = DailyDiskRunCoordinator(
                store: store,
                reportReader: reportReader,
                discovery: discovery,
                eventReader: FSEventHistoryReader(),
                metadataReader: POSIXFileMetadataReader(),
                fileScanner: FileInventoryScanner(),
                diskUsageSampler: APFSDiskUsageSampler(),
                overheadSampler: DailyDiskOverheadSampler(volumeDiscovery: discovery),
                reportCoordinator: reportCoordinator,
                progressFactory: { requestID, trigger, startedAt, count in
                    if let resumedProgress {
                        return try ScanProgressTracker(
                            resuming: resumedProgress, reporter: control,
                            cancellationChecker: control, commitBoundary: control,
                            runBindingRecorder: control
                        )
                    }
                    return try ScanProgressTracker(
                        context: ScanProgressContext(
                            requestID: requestID, trigger: trigger, startedAt: startedAt,
                            domainCount: count > 0 ? count : nil
                        ),
                        reporter: control, cancellationChecker: control,
                        commitBoundary: control, runBindingRecorder: control
                    )
                },
                scheduledReportHandler: { result in
                    do {
                        _ = try await AlertCoordinator(
                            policy: AlertPolicy(),
                            stateStore: LocalAlertStateStore(),
                            notifier: AppProcessNotificationSender()
                        ).evaluateAndNotify(
                            report: result.report,
                            currentSample: result.currentSample
                        )
                    } catch {
                        try? await logger?.log(
                            level: .warning,
                            event: "notification-unavailable",
                            sensitiveMetadata: ["error": String(describing: error)]
                        )
                    }
                    try? await logger?.log(
                        level: .info,
                        event: "scan-complete",
                        runID: result.report.runID.rawValue,
                        publicMetadata: [
                            "domain": .identifier(result.report.storageDomainID.rawValue),
                            "correctionBytes": .bytes(
                                result.report.accounting.reconciliationCorrection
                            ),
                        ]
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
                },
                errorHandler: { event, error in
                    try? await logger?.log(
                        level: .error,
                        event: event,
                        sensitiveMetadata: ["error": String(describing: error)]
                    )
                }
            )
            let summary = await coordinator.run(
                mode: .scheduled, startedAt: resumedProgress?.startedAt ?? runRequest.createdAt,
                requestID: runRequest.requestID
            )
            try await control.complete(summary)
            switch summary.terminalState {
            case .maintenanceCompleted, .succeeded, .skippedNotDue:
                return 0
            case .cancelled, .failed, .blockedByWriter:
                return 1
            }
        } catch let error as WriterLeaseError {
            try? await logger?.log(
                level: .info,
                event: "scheduled-writer-busy",
                sensitiveMetadata: ["error": String(describing: error)]
            )
            return 0
        } catch {
            try? await logger?.log(
                level: .error,
                event: "scheduled-run-failed",
                sensitiveMetadata: ["error": String(describing: error)]
            )
            return 1
        }
    }
}
