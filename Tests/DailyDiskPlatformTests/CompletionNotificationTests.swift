import DailyDiskCore
import Foundation
import Testing

@testable import DailyDiskPlatform

private actor CompletionNotifier: NotificationSending {
    private(set) var messages: [NotificationMessage] = []
    let fails: Bool
    init(fails: Bool = false) { self.fails = fails }
    func send(_ message: NotificationMessage) throws {
        messages.append(message)
        if fails { throw NotificationDeliveryError.deliveryFailed(77) }
    }
}

private func notificationReport(_ id: UUID, delta: Int64? = 1024, unreadable: UInt64 = 0) throws -> DailyReport {
    try DailyReport(
        runID: ScanRun.ID(id), generatedAt: Date(), storageDomainID: StorageDomain.ID("test"),
        accounting: AccountingSummary(
            eventAttributedDelta: delta ?? 0, reconciliationCorrection: 0,
            reconciledIndexedDelta: delta ?? 0, dailyDiskOverheadDelta: 0,
            physicalUsedDelta: delta, physicalUnattributedDelta: delta == nil ? nil : 0),
        reconciliation: nil,
        coverage: ScanCoverage(
            visitedPathCount: 10, indexedObjectCount: 10,
            unreadablePathCount: unreadable, transientErrorCount: 0),
        largestGrowth: [
            RankedPathChange(
                path: RelativePath(validating: "private-secret/file.txt"),
                allocatedDelta: 1024, logicalDelta: 1024)
        ], largestShrinkage: [], diagnostics: [])
}

private func completionSummary(
    _ ids: [UUID], trigger: DailyDiskRunTrigger = .scheduled,
    requestID: UUID = UUID()
) throws -> DailyDiskRunSummary {
    try DailyDiskRunSummary(
        requestID: requestID, trigger: trigger, terminalState: .succeeded,
        startedAt: Date(timeIntervalSince1970: 10), finishedAt: Date(timeIntervalSince1970: 20),
        completedDomainCount: ids.count, failedDomainCount: 0, reportRunIDs: ids)
}

@Test("Completion content preserves signs and baseline meaning and never discloses paths")
func completionContent() throws {
    for delta: Int64? in [nil, 0, 1024, -2048, Int64.min] {
        let report = try notificationReport(UUID(), delta: delta, unreadable: 1)
        let message = CompletionNotification.message(
            report: report, availableBytes: 200_000_000_000,
            sound: false, badge: 2)
        #expect(!message.body.contains("private-secret"))
        #expect(message.body.contains("部分位置无法读取"))
        #expect(message.badgeCount == 2)
        #expect(message.playsSound == false)
        if delta == nil { #expect(message.body.contains("基线")) }
        if let delta, delta < 0 { #expect(message.body.contains("减少")) }
        if delta == 0 { #expect(message.body.contains("基本不变")) }
    }
}

@Test("Manual and scheduled completions deduplicate across processes; viewed reports stay read")
func completionDeliveryAndReadState() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RunControlStore(rootURL: root)
    let secondProcess = try RunControlStore(rootURL: root)
    let id = UUID()
    try await store.markReportRead(id)  // GUI may see the published report before helper completion.
    try await store.enqueueCompletionNotifications(completionSummary([id], trigger: .manual))
    let recorder = CompletionNotifier()
    let coordinator = CompletionNotificationCoordinator(
        control: store, notifier: recorder,
        loadReport: { id in
            (
                try notificationReport(id),
                try StorageSample(
                    storageDomainID: StorageDomain.ID("test"),
                    sampledAt: Date(), capacityBytes: 400_000_000_000, usedBytes: 200_000_000_000,
                    availableBytes: 200_000_000_000)
            )
        })
    await coordinator.processLatestCompletion()
    try await secondProcess.enqueueCompletionNotifications(completionSummary([id]))
    await coordinator.processLatestCompletion()
    #expect(await recorder.messages.count == 1)
    #expect(try await secondProcess.notificationState().badgeCount == 0)
    let next = UUID()
    try await secondProcess.enqueueCompletionNotifications(completionSummary([next], trigger: .manual))
    await coordinator.processLatestCompletion()
    #expect(await recorder.messages.count == 2)
    #expect(await recorder.messages.last?.badgeCount == 1)
    try await store.markReportRead(next)
    #expect(try await secondProcess.notificationState().unread.isEmpty)
    #expect(try await secondProcess.notificationState().lastDelivery == .submitted)
}

@Test("Notification failure is isolated, not retried; disabling banners retains badge-only updates")
func completionFailureAndPreferences() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let control = try RunControlStore(rootURL: root)
    let failing = CompletionNotifier(fails: true)
    try await control.enqueueCompletionNotifications(completionSummary([UUID()]))
    let sender = CompletionNotificationCoordinator(
        control: control, notifier: failing,
        loadReport: { id in (try notificationReport(id), nil) })
    await sender.processLatestCompletion()
    await sender.processLatestCompletion()
    #expect(await failing.messages.count == 1)
    #expect(try await control.notificationState().lastDelivery == .unavailable)
    try await control.setNotificationPreferences(enabled: false, badges: false)
    try await control.enqueueCompletionNotifications(completionSummary([UUID()]))
    let recording = CompletionNotifier()
    await CompletionNotificationCoordinator(
        control: control, notifier: recording,
        loadReport: { id in (try notificationReport(id), nil) }
    ).processLatestCompletion()
    #expect(await recording.messages.first?.badgeOnly == true)
    #expect(await recording.messages.first?.badgeCount == 0)
    #expect(try await control.notificationState().lastDelivery == .disabled)
}

@Test("Notification preferences and inbox mutations share a cross-process lock")
func notificationConcurrentState() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try RunControlStore(rootURL: root)
    let second = try RunControlStore(rootURL: root)
    let id = UUID()
    async let enqueue: Void = first.enqueueCompletionNotifications(completionSummary([id]))
    async let read: Void = second.markReportRead(id)
    _ = try await (enqueue, read)
    #expect(try await first.notificationState().badgeCount == 0)
    async let sound: Void = first.setNotificationPreferences(sound: true)
    async let badges: Void = second.setNotificationPreferences(badges: false)
    _ = try await (sound, badges)
    let state = try await first.notificationState()
    #expect(state.sound && !state.badges && state.enabled)
    async let claim1 = first.claimCompletionNotification(id)
    async let claim2 = second.claimCompletionNotification(id)
    let claims = try await [claim1, claim2]
    #expect(claims.filter { $0 }.count == 1)
}

@Test("Bounded inbox does not grow forever or enqueue failed/cancelled/skipped work")
func notificationStateBoundsAndTerminals() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let control = try RunControlStore(rootURL: root)
    for terminal: DailyDiskRunTerminalState in [.cancelled, .skippedNotDue, .maintenanceCompleted, .failed] {
        let failed = terminal == .failed
        let summary = try DailyDiskRunSummary(
            requestID: UUID(), trigger: .manual, terminalState: terminal,
            startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 1),
            completedDomainCount: 0, failedDomainCount: failed ? 1 : 0, reportRunIDs: [],
            errorCategory: failed ? .unknown : nil)
        try await control.enqueueCompletionNotifications(summary)
    }
    #expect(try await control.notificationState().known.isEmpty)
    // Exercise bounds without thousands of fsyncs.
    var state = CompletionNotificationState()
    state.enqueue((0..<1100).map { _ in UUID() })
    #expect(state.known.count == 1024)
    #expect(state.badgeCount == 1024)
    #expect(state.pending.count == 1)
    for id in state.unread { state.markRead(id) }
    #expect(state.badgeCount == 0)
    try state.validate()
}

@Test("A persisted successful terminal summary is enough to recover notification enqueue")
func completionSummaryRecovery() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let control = try RunControlStore(rootURL: root)
    let id = UUID()
    let summary = try completionSummary([id])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    // Simulate a crash after the terminal summary was saved, before notification enqueue.
    let file = root.appendingPathComponent("summary.json")
    try encoder.encode(summary).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let recorder = CompletionNotifier()
    let service = CompletionNotificationCoordinator(
        control: control, notifier: recorder,
        loadReport: { id in (try notificationReport(id), nil) })
    await service.processLatestCompletion()
    await service.processLatestCompletion()
    #expect(await recorder.messages.count == 1)
    #expect(try await control.latestSummary() == summary)
    #expect(try await control.notificationState().unread == [id])
    try await control.clearInactiveState()
    #expect(try await control.notificationState().unread.isEmpty)
}

@Test("Notification state rejects substituted links and unknown schema fields")
func notificationStateSecurity() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let control = try RunControlStore(rootURL: root)
    try await control.setNotificationPreferences(sound: true)
    let stateURL = root.appendingPathComponent("notifications.json")
    let target = root.appendingPathComponent("other.json")
    try FileManager.default.moveItem(at: stateURL, to: target)
    try FileManager.default.createSymbolicLink(at: stateURL, withDestinationURL: target)
    await #expect(throws: (any Error).self) { try await control.notificationState() }
    await #expect(throws: (any Error).self) { try await control.setNotificationPreferences(sound: false) }
    try FileManager.default.removeItem(at: stateURL)
    try FileManager.default.moveItem(at: target, to: stateURL)
    #expect(try await control.notificationState().sound)
    var data = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
    data["command"] = "unexpected"
    try JSONSerialization.data(withJSONObject: data).write(to: stateURL)
    await #expect(throws: (any Error).self) { try await control.notificationState() }
}
