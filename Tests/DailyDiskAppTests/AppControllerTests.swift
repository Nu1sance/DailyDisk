import DailyDiskCore
import DailyDiskPlatform
import DailyDiskStore
import Foundation
import Testing

@testable import DailyDiskApp

private struct AppAccessProbe: FullDiskAccessProbing {
    func probe() async -> FullDiskAccessProbeResult {
        FullDiskAccessProbeResult(
            status: .likelyGranted,
            accessiblePaths: [],
            deniedPaths: [],
            missingPaths: []
        )
    }
}

private struct AppNotificationManager: NotificationAuthorizationManaging {
    func authorizationState() async -> NotificationAuthorizationState { .authorized }
    func requestAuthorization() async throws -> Bool { true }
}

private struct AppVolumeDiscovery: VolumeDiscovering {
    func discoverInternalAPFSVolumes() async throws -> VolumeTopology {
        VolumeTopology(domains: [], volumes: [], discoveredAt: Date())
    }
}

private final class AppRegistrationService: LaunchAgentRegistrationServicing, @unchecked Sendable {
    let value: LaunchAgentStatus
    init(_ value: LaunchAgentStatus) { self.value = value }
    func status() -> LaunchAgentStatus { value }
    func register() throws {}
    func unregister() throws {}
}

private actor AppLaunchctlProbe: ProcessRunning {
    private(set) var requests: [ProcessRequest] = []
    private let pauseKickstart: Bool
    private var continuation: CheckedContinuation<Void, Never>?

    init(pauseKickstart: Bool = false) { self.pauseKickstart = pauseKickstart }
    var isPaused: Bool { continuation != nil }
    func resume() {
        continuation?.resume()
        continuation = nil
    }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        requests.append(request)
        if pauseKickstart, request.arguments.first == "kickstart" {
            await withCheckedContinuation { continuation = $0 }
        }
        let output =
            request.arguments.first == "print"
            ? Data("state = exited\nlast exit code = 0\n".utf8)
            : Data()
        return ProcessResult(
            terminationStatus: 0,
            standardOutput: output,
            standardError: Data()
        )
    }
}

private func appControlRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("DailyDiskAppControllerTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("Control", isDirectory: true)
}

@MainActor
private func makeController(
    control: RunControlStore,
    databaseURL: URL,
    process: AppLaunchctlProbe = AppLaunchctlProbe()
) -> AppController {
    AppController(
        accessProbe: AppAccessProbe(),
        notificationManager: AppNotificationManager(),
        volumeDiscovery: AppVolumeDiscovery(),
        launchAgentManager: LaunchAgentManager(
            service: AppRegistrationService(.enabled),
            bundleURL: URL(fileURLWithPath: "/Applications/DailyDisk.app"),
            processRunner: process,
            userID: 501
        ),
        controlStore: control,
        inspectionService: RuntimeInspectionService(databaseURL: databaseURL),
        pollingInterval: .seconds(60)
    )
}

@Test("Report paths use reversible byte-safe display escaping")
func reportPathEscaping() throws {
    let path = try RelativePath(validating: Data([0x61, 0x25, 0x0A, 0xFF]))
    #expect(reversibleDisplayPath(path) == "a%25%0A%FF")
}

@Test("Manual button enqueues once and a new controller reconnects")
@MainActor
func appControllerEnqueueAndReconnect() async throws {
    let root = appControlRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let control = try RunControlStore(rootURL: root)
    let process = AppLaunchctlProbe()
    let databaseURL = root.deletingLastPathComponent().appendingPathComponent("missing.sqlite")
    let controller = makeController(
        control: control,
        databaseURL: databaseURL,
        process: process
    )
    await controller.scanNow()
    guard case .running(let queued) = controller.scanState else {
        Issue.record("Expected queued scan state")
        return
    }
    #expect(queued.phase == .queued)
    let request = try #require(try await control.pendingRequest())
    await controller.scanNow()
    #expect(try await control.pendingRequest()?.requestID == request.requestID)
    #expect(
        await process.requests.filter { $0.arguments.first == "kickstart" }.count == 1)

    let reconnected = makeController(control: control, databaseURL: databaseURL)
    await reconnected.refreshScanState()
    guard case .running(let restored) = reconnected.scanState else {
        Issue.record("Expected restored queued state")
        return
    }
    #expect(restored.requestID == request.requestID)
    await reconnected.cancelScan()
    guard case .cancelled(let summary) = reconnected.scanState else {
        Issue.record("Queued request should cancel without helper claim")
        return
    }
    #expect(summary?.requestID == request.requestID)
    #expect(try await control.pendingRequest() == nil)
}

@Test("Progress polling preserves immediate feedback while launch is pending")
@MainActor
func pollingDoesNotReplaceSubmissionFeedback() async throws {
    let root = appControlRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let control = try RunControlStore(rootURL: root)
    let process = AppLaunchctlProbe(pauseKickstart: true)
    let controller = makeController(
        control: control,
        databaseURL: root.deletingLastPathComponent().appendingPathComponent("missing.sqlite"),
        process: process
    )
    let submission = Task { await controller.scanNow() }
    while !(await process.isPaused) { await Task.yield() }
    await controller.refreshScanState()
    #expect(controller.scanState == .requesting)
    await controller.scanNow()
    #expect(await process.requests.filter { $0.arguments.first == "kickstart" }.count == 1)
    await process.resume()
    await submission.value
    #expect(try await control.pendingRequest() != nil)
}

@Test("Initial refresh discovers an external writer and clears it after release")
@MainActor
func appControllerExternalWriter() async throws {
    let root = appControlRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let control = try RunControlStore(rootURL: root)
    let databaseURL = root.deletingLastPathComponent().appendingPathComponent("DailyDisk.sqlite")
    var writer: SQLiteInventoryStore? = try SQLiteInventoryStore(databaseURL: databaseURL)
    try await writer?.prepare()
    let controller = makeController(control: control, databaseURL: databaseURL)
    await controller.refresh()
    guard case .externalWriter = controller.scanState else {
        Issue.record("Expected initial external writer state")
        return
    }
    #expect(controller.scanState.isActive)

    let request = try DailyDiskRunRequest(createdAt: Date(timeIntervalSince1970: 10))
    try await control.enqueue(request)
    _ = try await control.claimPendingRequest()
    var update = request.createdAt
    for phase in [
        ScanProgressPhase.preparing, .discoveringStorage, .replayingEvents,
        .catchingUpEvents, .sealingInventory, .collectingDiagnostics,
        .committing, .publishingReport,
    ] {
        update = update.addingTimeInterval(1)
        await control.publish(
            try ScanProgressSnapshot(
                requestID: request.requestID,
                trigger: .manual,
                mode: .incremental,
                phase: phase,
                startedAt: request.createdAt,
                updatedAt: update
            )
        )
    }
    let summary = try DailyDiskRunSummary(
        requestID: request.requestID,
        trigger: .manual,
        terminalState: .succeeded,
        startedAt: request.createdAt,
        finishedAt: update.addingTimeInterval(1),
        completedDomainCount: 1,
        failedDomainCount: 0,
        reportRunIDs: []
    )
    try await control.complete(summary)
    await controller.refreshScanState()
    guard case .succeeded = controller.scanState else {
        Issue.record("Terminal control state must outrank stale external-writer cache")
        return
    }

    writer = nil
}

@Test("Controller requests cancellation only before finishing")
@MainActor
func appControllerCancellationBoundary() async throws {
    let root = appControlRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let control = try RunControlStore(rootURL: root)
    let request = try DailyDiskRunRequest(createdAt: Date(timeIntervalSince1970: 10))
    try await control.enqueue(request)
    _ = try await control.claimPendingRequest()
    let controller = makeController(
        control: control,
        databaseURL: root.deletingLastPathComponent().appendingPathComponent("missing.sqlite")
    )
    let preparing = try ScanProgressSnapshot(
        requestID: request.requestID,
        trigger: .manual,
        mode: .incremental,
        phase: .preparing,
        startedAt: request.createdAt,
        updatedAt: request.createdAt.addingTimeInterval(1)
    )
    await control.publish(preparing)
    await controller.refreshScanState()
    await controller.cancelScan()
    guard case .cancellationRequested = controller.scanState else {
        Issue.record("Expected cancellation request state")
        return
    }
    var cancellationObserved = false
    do {
        try await control.checkCancellation(requestID: request.requestID)
    } catch ScanProgressError.cancelled {
        cancellationObserved = true
    }
    #expect(cancellationObserved)
    let cancellationReconnect = makeController(
        control: control,
        databaseURL: root.deletingLastPathComponent().appendingPathComponent("missing.sqlite")
    )
    await cancellationReconnect.refreshScanState()
    guard case .cancellationRequested = cancellationReconnect.scanState else {
        Issue.record("Persisted cancellation should survive controller recreation")
        return
    }

    // Use a fresh channel to exercise the non-cancellable commit boundary.
    let finishingRoot = appControlRoot()
    defer { try? FileManager.default.removeItem(at: finishingRoot.deletingLastPathComponent()) }
    let finishingControl = try RunControlStore(rootURL: finishingRoot)
    let finishingRequest = try DailyDiskRunRequest(createdAt: Date(timeIntervalSince1970: 20))
    try await finishingControl.enqueue(finishingRequest)
    _ = try await finishingControl.claimPendingRequest()
    var time = finishingRequest.createdAt
    for phase in [
        ScanProgressPhase.preparing, .discoveringStorage, .replayingEvents,
        .catchingUpEvents, .sealingInventory, .collectingDiagnostics, .committing,
    ] {
        time = time.addingTimeInterval(1)
        await finishingControl.publish(
            try ScanProgressSnapshot(
                requestID: finishingRequest.requestID,
                trigger: .manual,
                mode: .incremental,
                phase: phase,
                startedAt: finishingRequest.createdAt,
                updatedAt: time
            )
        )
    }
    let finishingProcess = AppLaunchctlProbe()
    let finishingController = makeController(
        control: finishingControl,
        databaseURL: finishingRoot.deletingLastPathComponent().appendingPathComponent("missing.sqlite"),
        process: finishingProcess
    )
    await finishingController.refreshScanState()
    guard case .finishing(let progress) = finishingController.scanState else {
        Issue.record("Expected finishing state")
        return
    }
    #expect(progress.phase == .committing)
    await finishingController.cancelScan()
    #expect(try await finishingControl.latestProgress()?.phase == .committing)
    await finishingController.stopCurrentHelper()
    #expect(await finishingProcess.requests.allSatisfy { $0.arguments.first == "print" })
}

private final class AppTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}

@Test("A stopped helper is shown as interrupted instead of spinning indefinitely; retry is explicit")
@MainActor
func appControllerStoppedHelper() async throws {
    let root = appControlRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let control = try RunControlStore(rootURL: root)
    let clock = AppTestClock()
    let request = try DailyDiskRunRequest(createdAt: clock.now())
    try await control.enqueue(request)
    _ = try await control.claimPendingRequest()
    let process = AppLaunchctlProbe()
    let controller = AppController(
        accessProbe: AppAccessProbe(), notificationManager: AppNotificationManager(),
        volumeDiscovery: AppVolumeDiscovery(),
        launchAgentManager: LaunchAgentManager(
            service: AppRegistrationService(.enabled), bundleURL: URL(fileURLWithPath: "/Applications/DailyDisk.app"),
            processRunner: process, userID: 501
        ),
        controlStore: control,
        inspectionService: RuntimeInspectionService(
            databaseURL: root.deletingLastPathComponent().appendingPathComponent("missing.sqlite")),
        pollingInterval: .seconds(60), now: { clock.now() }
    )
    await controller.refreshScanState()
    #expect(controller.scanState.isActive)
    clock.advance(16)
    await controller.refreshScanState()
    #expect(controller.scanState == .failed(.helperStopped))
    #expect(try await control.activeRequest()?.requestID == request.requestID)
    #expect(await process.requests.allSatisfy { $0.arguments.first == "print" })
}

@Test("An open idle window discovers a later scheduled run and can cancel it")
@MainActor
func appControllerDiscoversScheduledRun() async throws {
    let root = appControlRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let control = try RunControlStore(rootURL: root)
    let controller = makeController(
        control: control, databaseURL: root.deletingLastPathComponent().appendingPathComponent("missing.sqlite"))
    await controller.refreshScanState()
    #expect(controller.scanState == .idle)
    let scheduled = try DailyDiskRunRequest()
    try await control.beginScheduledRun(scheduled)
    await controller.refreshScanState()
    #expect(controller.scanState.progress?.trigger == .scheduled)
    #expect(controller.scanState.progress?.requestID == scheduled.requestID)
    await controller.cancelScan()
    #expect(try await control.cancellationRequest()?.requestID == scheduled.requestID)
}

@Test("Space maintenance enqueues the distinct action and reconnects to non-cancellable progress")
@MainActor
func appSpaceMaintenanceReconnect() async throws {
    let root = appControlRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let control = try RunControlStore(rootURL: root)
    let url = root.deletingLastPathComponent().appendingPathComponent("missing.sqlite")
    let controller = makeController(control: control, databaseURL: url)
    await controller.reclaimSpace()
    let pending = try #require(try await control.pendingRequest())
    #expect(pending.action == .reclaimSpace)
    let claimed = try #require(try await control.claimPendingRequest())
    let tracker = try ScanProgressTracker(
        context: ScanProgressContext(requestID: claimed.requestID, trigger: .manual, startedAt: claimed.createdAt),
        reporter: control, cancellationChecker: control, commitBoundary: control)
    try await tracker.transition(to: .preparing, mode: nil)
    try await tracker.transition(to: .reclaimingSpace, mode: nil)
    let restarted = makeController(control: control, databaseURL: url)
    await restarted.refreshScanState()
    guard case .finishing(let progress) = restarted.scanState else {
        Issue.record("Expected non-cancellable maintenance after reconnect")
        return
    }
    #expect(progress.phase == .reclaimingSpace)
    await restarted.cancelScan()
    #expect(try await control.cancellationRequest() == nil)
    try await tracker.transition(to: .verifyingMaintenance, mode: nil)
    try await control.complete(
        DailyDiskRunSummary(
            requestID: claimed.requestID, trigger: .manual, terminalState: .maintenanceCompleted,
            startedAt: claimed.createdAt, finishedAt: Date(), completedDomainCount: 0,
            failedDomainCount: 0, reportRunIDs: []))
    await restarted.refreshScanState()
    guard case .succeeded(let summary) = restarted.scanState else {
        Issue.record("Expected maintenance completion without an inventory report")
        return
    }
    #expect(summary.terminalState == .maintenanceCompleted)
    #expect(summary.completedDomainCount == 0)
}

@Test("Control initialization failures retain a safe diagnostic across refresh")
@MainActor
func controlInitializationDiagnostic() async {
    let controller = AppController(
        accessProbe: AppAccessProbe(), notificationManager: AppNotificationManager(),
        volumeDiscovery: AppVolumeDiscovery(),
        controlStoreFactory: { throw RunControlStoreError.posix(code: 13) })
    #expect(controller.controlDiagnostic == "initialization: posix(code: 13)")
    await controller.refreshScanState()
    #expect(controller.scanState == .failed(.controlChannel))
    #expect(controller.controlDiagnostic == "initialization: posix(code: 13)")
}

@Test("Control diagnostics never disclose arbitrary paths or error descriptions")
@MainActor
func sanitizedControlFailure() {
    let privatePath = "/private/fixture-sensitive-path"
    #expect(
        AppController.controlFailureDescription(
            LaunchAgentManagerError.unstableApplicationPath(privatePath), stage: "launch")
            == "launch: unstableApplicationPath")
    #expect(
        AppController.controlFailureDescription(
            NSError(domain: privatePath, code: 17, userInfo: [NSLocalizedDescriptionKey: privatePath]), stage: "request"
        )
            == "request: other(code: 17)")
    #expect(
        AppController.controlFailureDescription(
            LaunchAgentManagerError.launchctlFailed(113), stage: "launch") == "launch: launchctlFailed(113)")
}

@Test("Malformed persisted control data produces an observation diagnostic")
@MainActor
func controlObservationDiagnostic() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let control = try RunControlStore(rootURL: root.appendingPathComponent("Control"))
    let file = root.appendingPathComponent("Control/progress.json")
    try Data("{\"phase\": \"invalid-private-fixture\"}".utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let controller = makeController(control: control, databaseURL: root.appendingPathComponent("fixture.sqlite"))
    await controller.refreshScanState()
    #expect(controller.scanState == .failed(.controlChannel))
    #expect(controller.controlDiagnostic == "observation: invalidControlJSON")
}

private actor AppBadgeProbe: NotificationAuthorizationManaging {
    private(set) var counts: [Int] = []
    private(set) var removed: [UUID] = []
    func authorizationState() -> NotificationAuthorizationState { .authorized }
    func requestAuthorization() -> Bool { true }
    func setBadgeCount(_ count: Int) { counts.append(count) }
    func removeReportNotification(_ id: UUID) { removed.append(id) }
}

@Test("GUI refresh preserves unread badges, viewing one report clears only that report")
@MainActor
func guiUnreadReportBadges() async throws {
    let root = appControlRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let control = try RunControlStore(rootURL: root)
    let probe = AppBadgeProbe()
    let controller = AppController(
        accessProbe: AppAccessProbe(), notificationManager: probe,
        volumeDiscovery: AppVolumeDiscovery(), controlStore: control,
        inspectionService: RuntimeInspectionService(databaseURL: root.appendingPathComponent("absent.sqlite")))
    let first = UUID()
    let second = UUID()
    try await control.enqueueCompletionNotifications(
        DailyDiskRunSummary(
            requestID: UUID(), trigger: .manual, terminalState: .succeeded,
            startedAt: Date(timeIntervalSince1970: 1), finishedAt: Date(timeIntervalSince1970: 2),
            completedDomainCount: 2, failedDomainCount: 0, reportRunIDs: [first, second]))
    await controller.refreshCompletionNotifications(force: true)
    #expect(await probe.counts.last == 2)
    #expect(try await control.notificationState().unread.count == 2)
    let report = try DailyReport(
        runID: ScanRun.ID(first), generatedAt: Date(), storageDomainID: StorageDomain.ID("fixture"),
        accounting: AccountingSummary(
            eventAttributedDelta: 1, reconciliationCorrection: 0,
            reconciledIndexedDelta: 1, dailyDiskOverheadDelta: 0, physicalUsedDelta: 1, physicalUnattributedDelta: 0),
        reconciliation: nil,
        coverage: ScanCoverage(
            visitedPathCount: 1, indexedObjectCount: 1, unreadablePathCount: 0, transientErrorCount: 0),
        largestGrowth: [], largestShrinkage: [], diagnostics: [])
    await controller.didViewReport(report)
    #expect(await probe.counts.last == 1)
    #expect(await probe.removed == [first])
    #expect(try await control.notificationState().unread == [second])
    await controller.setNotificationPreferences(badges: false)
    #expect(await probe.counts.last == 0)
    #expect(try await control.notificationState().unread == [second])
    await controller.setNotificationPreferences(badges: true)
    #expect(await probe.counts.last == 1)
    await controller.markAllReportsRead()
    #expect(await probe.counts.last == 0)
    #expect(try await control.notificationState().unread.isEmpty)
}
