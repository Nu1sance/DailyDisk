import DailyDiskCore
import DailyDiskStore
import Foundation

/// Manual maintenance uses the existing private request/progress channel and
/// never turns the GUI into an inventory writer or launches a scan.
struct SpaceMaintenanceRunner {
    func run(
        request: DailyDiskRunRequest,
        resumedProgress: ScanProgressSnapshot?,
        control: RunControlStore,
        databaseURL: URL = SQLiteInventoryStore.defaultDatabaseURL,
        availableBytes: (@Sendable () throws -> Int64)? = nil
    ) async -> Int32 {
        let started = resumedProgress?.startedAt ?? Date()
        do {
            let store = try SQLiteInventoryStore(databaseURL: databaseURL)
            let tracker: ScanProgressTracker
            if let resumedProgress {
                tracker = try ScanProgressTracker(
                    resuming: resumedProgress, reporter: control, cancellationChecker: control,
                    commitBoundary: control
                )
            } else {
                tracker = try ScanProgressTracker(
                    context: ScanProgressContext(requestID: request.requestID, trigger: .manual, startedAt: started),
                    reporter: control, cancellationChecker: control, commitBoundary: control
                )
            }
            try await tracker.transition(to: .preparing, mode: nil)
            try await store.prepare()
            if resumedProgress != nil {
                try await tracker.transition(to: .verifyingMaintenance, mode: nil)
                try await store.recoverSpaceMaintenance(verifyRegardless: true)
                throw SpaceMaintenanceError.interrupted
            }
            // Pending scans/reports require the scan recovery path. Maintenance
            // must not silently erase that request's recovery evidence.
            try await store.maintainSpace(force: true, observer: tracker, availableBytes: availableBytes)
            try await tracker.transition(to: .completed, mode: nil)
            try await control.complete(
                DailyDiskRunSummary(
                    requestID: request.requestID, trigger: .manual, terminalState: .maintenanceCompleted,
                    startedAt: started, finishedAt: Date(), completedDomainCount: 0,
                    failedDomainCount: 0, reportRunIDs: []
                )
            )
            return 0
        } catch is WriterLeaseError {
            return 0
        } catch {
            let cancelled = isScanCancellation(error)
            let category: ScanProgressErrorCategory
            switch error {
            case SpaceMaintenanceError.insufficientSpace: category = .insufficientSpace
            case SpaceMaintenanceError.recoveryPending: category = .maintenanceRecovery
            case SpaceMaintenanceError.interrupted: category = .maintenanceInterrupted
            default: category = .database
            }
            if let summary = try? DailyDiskRunSummary(
                requestID: request.requestID, trigger: .manual,
                terminalState: cancelled ? .cancelled : .failed,
                startedAt: started, finishedAt: Date(), completedDomainCount: 0,
                failedDomainCount: cancelled ? 0 : 1, reportRunIDs: [], errorCategory: cancelled ? nil : category
            ) {
                try? await control.complete(summary)
            }
            return cancelled ? 0 : 1
        }
    }
}
