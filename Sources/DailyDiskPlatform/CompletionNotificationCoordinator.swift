import DailyDiskCore
import DailyDiskStore
import Foundation

public struct CompletionNotificationCoordinator: Sendable {
    public typealias ReportLoader = @Sendable (UUID) async throws -> (DailyReport, StorageSample?)?
    private let control: RunControlStore
    private let notifier: any NotificationSending
    private let loadReport: ReportLoader

    public init(
        control: RunControlStore, notifier: any NotificationSending = AppProcessNotificationSender(),
        loadReport: @escaping ReportLoader = { id in
            let reader = try SQLiteReportStore()
            guard let report = try await reader.report(runID: ScanRun.ID(id)) else { return nil }
            return (
                report, try await reader.storageSampleForReport(runID: report.runID, domainID: report.storageDomainID)
            )
        }
    ) {
        self.control = control
        self.notifier = notifier
        self.loadReport = loadReport
    }

    /// Called only after terminal success is persisted, and on the next natural
    /// helper start to close the terminal-summary/enqueue crash window. Never throws
    /// into scan completion, never prompts, and never starts a retry process.
    public func processLatestCompletion() async {
        do {
            if let summary = try await control.latestSummary() {
                try await control.enqueueCompletionNotifications(summary)
            }
            let pending = try await control.notificationState().pending
            for id in pending {
                guard let (report, sample) = try await loadReport(id) else {
                    _ = try await control.claimCompletionNotification(id)
                    continue
                }
                guard try await control.claimCompletionNotification(id) else { continue }
                let state = try await control.notificationState()
                let reasons =
                    try sample.map {
                        try AlertPolicy().evaluate(report: report, currentSample: $0, cooldown: 0)?.reasons ?? []
                    } ?? []
                let message = CompletionNotification.message(
                    report: report, availableBytes: sample?.availableBytes, sound: state.sound,
                    badge: state.badgeCount, badgeOnly: !state.enabled, alertReasons: reasons)
                do {
                    try await notifier.send(message)
                    try await control.recordNotificationDelivery(state.enabled ? .submitted : .disabled)
                } catch {
                    try? await control.recordNotificationDelivery(.unavailable)
                }
            }
        } catch {
            try? await control.recordNotificationDelivery(.unavailable)
        }
    }
}
