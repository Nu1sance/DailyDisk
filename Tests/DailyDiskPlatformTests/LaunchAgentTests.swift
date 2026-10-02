import DailyDiskCore
import Foundation
import Testing

@testable import DailyDiskPlatform

private final class FakeRegistrationService: LaunchAgentRegistrationServicing, @unchecked Sendable {
    var currentStatus: LaunchAgentStatus
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    var statusAfterRegister: LaunchAgentStatus = .enabled
    var registrationError: LaunchAgentManagerError?
    var unregistrationError: LaunchAgentManagerError?

    init(status: LaunchAgentStatus) {
        currentStatus = status
    }

    func status() -> LaunchAgentStatus { currentStatus }
    func register() throws {
        registerCount += 1
        if let registrationError { throw registrationError }
        currentStatus = statusAfterRegister
    }
    func unregister() throws {
        unregisterCount += 1
        if let unregistrationError { throw unregistrationError }
        currentStatus = .notRegistered
    }
}

private final class SignalProbe: ProcessSignaling, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var processIDs: [Int32] = []

    func terminate(processID: Int32) throws {
        lock.withLock { processIDs.append(processID) }
    }
}

private actor LaunchctlProbe: ProcessRunning {
    private var responses: [ProcessResult]
    private let beforeResult: (@Sendable () async -> Void)?
    private(set) var requests: [ProcessRequest] = []

    init(responses: [ProcessResult], beforeResult: (@Sendable () async -> Void)? = nil) {
        self.responses = responses
        self.beforeResult = beforeResult
    }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        requests.append(request)
        await beforeResult?()
        return responses.isEmpty
            ? ProcessResult(terminationStatus: 0, standardOutput: Data(), standardError: Data())
            : responses.removeFirst()
    }
}

private func launchctlResult(_ output: String = "", status: Int32 = 0) -> ProcessResult {
    ProcessResult(
        terminationStatus: status,
        standardOutput: Data(output.utf8),
        standardError: Data()
    )
}

@Test("Embedded LaunchAgent is a non-resident daily 05:00 job")
func launchAgentPlist() throws {
    let testsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let plistURL =
        testsDirectory
        .deletingLastPathComponent()
        .appendingPathComponent("App/DailyDisk/LaunchAgents/io.github.xiuyuwu.DailyDisk.agent.plist")
    let data = try Data(contentsOf: plistURL)
    let value = try #require(
        PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    )
    let calendar = try #require(value["StartCalendarInterval"] as? [String: Int])
    let arguments = try #require(value["ProgramArguments"] as? [String])

    #expect(value["Label"] as? String == "io.github.xiuyuwu.DailyDisk.agent")
    #expect(value["BundleProgram"] as? String == "Contents/Helpers/DailyDiskAgent")
    #expect(arguments == ["DailyDiskAgent"])
    #expect(calendar["Hour"] == 5)
    #expect(calendar["Minute"] == 0)
    #expect(value["KeepAlive"] as? Bool == false)
    #expect(value["ThrottleInterval"] == nil)
    #expect(value["RunAtLoad"] as? Bool == true)
}

@Test("LaunchAgent start uses non-destructive kickstart and avoids duplicate launch")
func launchAgentKickstart() async throws {
    let service = FakeRegistrationService(status: .enabled)
    let probe = LaunchctlProbe(
        responses: [
            launchctlResult("state = exited\nlast exit code = 0\n"),
            launchctlResult(),
        ]
    )
    let manager = LaunchAgentManager(
        service: service,
        bundleURL: URL(fileURLWithPath: "/Applications/DailyDisk.app"),
        processRunner: probe,
        userID: 501
    )
    #expect(try await manager.startIfNeeded() == .started)
    let requests = await probe.requests
    #expect(requests.count == 2)
    #expect(requests[1].arguments == ["kickstart", "gui/501/io.github.xiuyuwu.DailyDisk.agent"])
    #expect(!requests[1].arguments.contains("-k"))

    let runningProbe = LaunchctlProbe(
        responses: [launchctlResult("state = running\npid = 42\nlast exit code = 0\n")]
    )
    let runningManager = LaunchAgentManager(
        service: service,
        bundleURL: URL(fileURLWithPath: "/Applications/DailyDisk.app"),
        processRunner: runningProbe,
        userID: 501
    )
    let result = try await runningManager.startIfNeeded()
    guard case .alreadyRunning(let status) = result else {
        Issue.record("Expected attachment to existing helper")
        return
    }
    #expect(status.processID == 42)
    #expect(await runningProbe.requests.count == 1)
    #expect(service.registerCount == 0)
    #expect(service.unregisterCount == 0)
}

@Test("Queued request during helper shutdown is kickstarted after the idle handshake")
func helperShutdownHandshake() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LaunchAgentHandshake", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let control = try RunControlStore(rootURL: root)
    #expect(try await control.markHelperIdleIfNoPendingRequest(processID: 123))
    try await control.enqueue(DailyDiskRunRequest())

    let probe = LaunchctlProbe(
        responses: [
            launchctlResult("state = running\npid = 123\n"),
            launchctlResult("state = exited\nlast exit code = 0\n"),
            launchctlResult(),
        ]
    )
    let manager = LaunchAgentManager(
        service: FakeRegistrationService(status: .enabled),
        bundleURL: URL(fileURLWithPath: "/Applications/DailyDisk.app"),
        processRunner: probe,
        userID: 503
    )
    #expect(try await manager.startIfNeeded(controlStore: control) == .started)
    let requests = await probe.requests
    #expect(
        requests.map(\.arguments) == [
            ["print", "gui/503/io.github.xiuyuwu.DailyDisk.agent"],
            ["print", "gui/503/io.github.xiuyuwu.DailyDisk.agent"],
            ["kickstart", "gui/503/io.github.xiuyuwu.DailyDisk.agent"],
        ])
}

@Test("Idle handshake ignores missing and replacement process identities")
func helperShutdownIdentityChanges() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LaunchAgentIdentity", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let control = try RunControlStore(rootURL: root)
    #expect(try await control.markHelperIdleIfNoPendingRequest(processID: 123))
    try await control.enqueue(DailyDiskRunRequest())

    let missingPIDProbe = LaunchctlProbe(
        responses: [launchctlResult("state = running\n")]
    )
    let missingPIDManager = LaunchAgentManager(
        service: FakeRegistrationService(status: .enabled),
        bundleURL: URL(fileURLWithPath: "/Applications/DailyDisk.app"),
        processRunner: missingPIDProbe,
        userID: 503
    )
    guard
        case .alreadyRunning = try await missingPIDManager.startIfNeeded(
            controlStore: control
        )
    else {
        Issue.record("A PID-less running helper must be attached without stale-idle polling")
        return
    }
    #expect(await missingPIDProbe.requests.count == 1)

    let replacementProbe = LaunchctlProbe(
        responses: [
            launchctlResult("state = running\npid = 123\n"),
            launchctlResult("state = running\npid = 456\n"),
        ]
    )
    let replacementManager = LaunchAgentManager(
        service: FakeRegistrationService(status: .enabled),
        bundleURL: URL(fileURLWithPath: "/Applications/DailyDisk.app"),
        processRunner: replacementProbe,
        userID: 503
    )
    guard
        case .alreadyRunning(let replacement) = try await replacementManager.startIfNeeded(
            controlStore: control
        )
    else {
        Issue.record("Replacement helper should be attached")
        return
    }
    #expect(replacement.processID == 456)
    #expect(await replacementProbe.requests.count == 2)
}

@Test("Stop fallback cannot terminate a later request in the same helper")
func stopFallbackIsRequestScoped() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LaunchAgentStopScope", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let control = try RunControlStore(rootURL: root)
    let first = try DailyDiskRunRequest(createdAt: Date(timeIntervalSince1970: 10))
    try await control.enqueue(first)
    _ = try await control.claimPendingRequest()
    await control.publish(
        try ScanProgressSnapshot(
            requestID: first.requestID,
            trigger: .manual,
            mode: .incremental,
            phase: .preparing,
            startedAt: first.createdAt,
            updatedAt: first.createdAt.addingTimeInterval(1)
        )
    )
    let reachedFallback = AsyncStream<Void>.makeStream()
    let resumeFallback = AsyncStream<Void>.makeStream()
    defer {
        reachedFallback.continuation.finish()
        resumeFallback.continuation.finish()
    }
    let probe = LaunchctlProbe(
        responses: [launchctlResult("state = running\npid = 987\n")],
        beforeResult: {
            reachedFallback.continuation.yield(())
            for await _ in resumeFallback.stream { break }
        }
    )
    let signaler = SignalProbe()
    let manager = LaunchAgentManager(
        service: FakeRegistrationService(status: .enabled),
        bundleURL: URL(fileURLWithPath: "/Applications/DailyDisk.app"),
        processRunner: probe,
        processSignaler: signaler,
        userID: 504
    )
    let stop = Task {
        try await manager.requestStop(
            requestID: first.requestID,
            controlStore: control,
            fallbackDelay: .zero
        )
    }
    // Hold the runtime-status response until turnover is complete. A sleep
    // cannot guarantee this ordering under concurrent test/executor load.
    for await _ in reachedFallback.stream { break }
    await control.publish(
        try ScanProgressSnapshot(
            requestID: first.requestID,
            trigger: .manual,
            mode: .incremental,
            phase: .cancelling,
            startedAt: first.createdAt,
            updatedAt: first.createdAt.addingTimeInterval(2)
        )
    )
    await control.publish(
        try ScanProgressSnapshot(
            requestID: first.requestID,
            trigger: .manual,
            mode: .incremental,
            phase: .cancelled,
            startedAt: first.createdAt,
            updatedAt: first.createdAt.addingTimeInterval(3)
        )
    )
    try await control.complete(
        DailyDiskRunSummary(
            requestID: first.requestID,
            trigger: .manual,
            terminalState: .cancelled,
            startedAt: first.createdAt,
            finishedAt: first.createdAt.addingTimeInterval(4),
            completedDomainCount: 0,
            failedDomainCount: 0,
            reportRunIDs: []
        )
    )
    let second = try DailyDiskRunRequest()
    try await control.enqueue(second)
    _ = try await control.claimPendingRequest()
    resumeFallback.continuation.yield(())
    try await stop.value
    #expect(await probe.requests.count == 1)
    #expect(signaler.processIDs.isEmpty)
    #expect(try await control.activeRequest()?.requestID == second.requestID)
}

@Test("LaunchAgent status parser and cooperative-stop fallback use fixed arguments")
func launchAgentStatusAndStop() async throws {
    let parsed = LaunchAgentManager.parseRuntimeStatus(
        "state = running\npid = 123\nlast exit code = 7\n"
    )
    #expect(parsed.isRunning)
    #expect(parsed.processID == 123)
    #expect(parsed.lastExitCode == 7)
    #expect(!LaunchAgentManager.parseRuntimeStatus("state = exited\npid = 0\n").isRunning)
    #expect(!LaunchAgentManager.parseRuntimeStatus("state = exited\npid = -1\n").isRunning)

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LaunchAgentStop", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let control = try RunControlStore(rootURL: root)
    let request = try DailyDiskRunRequest()
    try await control.enqueue(request)
    _ = try await control.claimPendingRequest()
    let probe = LaunchctlProbe(
        responses: [launchctlResult("state = running\npid = 123\n")]
    )
    let signaler = SignalProbe()
    let manager = LaunchAgentManager(
        service: FakeRegistrationService(status: .enabled),
        bundleURL: URL(fileURLWithPath: "/Applications/DailyDisk.app"),
        processRunner: probe,
        processSignaler: signaler,
        userID: 502
    )
    try await manager.requestStop(
        requestID: request.requestID,
        controlStore: control,
        fallbackDelay: .zero
    )
    let requests = await probe.requests
    #expect(
        requests.last?.arguments == [
            "print", "gui/502/io.github.xiuyuwu.DailyDisk.agent",
        ])
    #expect(signaler.processIDs == [123])
    await #expect(throws: ScanProgressError.cancelled) {
        try await control.checkCancellation(requestID: request.requestID)
    }
}

@Test("LaunchAgent registration accepts only stable Applications locations")
func launchAgentStablePath() {
    #expect(LaunchAgentManager.isStableInstallationPath(URL(fileURLWithPath: "/Applications/DailyDisk.app")))
    #expect(
        LaunchAgentManager.isStableInstallationPath(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/DailyDisk.app")
        )
    )
    #expect(!LaunchAgentManager.isStableInstallationPath(URL(fileURLWithPath: "/tmp/DailyDisk.app")))
}

private func missingLaunchAgent() -> ProcessResult {
    ProcessResult(
        terminationStatus: 113, standardOutput: Data(),
        standardError: Data("Could not find service in domain for user gui".utf8)
    )
}

@Test(
    "Reinstall recovery re-registers a missing enabled job and preserves its queued request",
    arguments: [false, true])
func reinstallRecoversMissingAgent(runningAfterRegistration: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let control = try RunControlStore(rootURL: root)
    let request = try DailyDiskRunRequest()
    try await control.enqueue(request)
    let persistedRequest = try await control.pendingRequest()
    let service = FakeRegistrationService(status: .enabled)
    let probe = LaunchctlProbe(responses: [
        missingLaunchAgent(),
        launchctlResult(runningAfterRegistration ? "state = running\npid = 42\n" : "state = exited\n"),
        launchctlResult(),
    ])
    let manager = LaunchAgentManager(
        service: service, bundleURL: URL(fileURLWithPath: "/Applications/DailyDisk.app"),
        processRunner: probe, userID: 501
    )
    let result = try await manager.startIfNeeded(controlStore: control)
    if runningAfterRegistration {
        guard case .alreadyRunning(let runtime) = result else {
            Issue.record("RunAtLoad helper should be attached without another kickstart")
            return
        }
        #expect(runtime.processID == 42)
    } else {
        #expect(result == .started)
    }
    #expect(service.unregisterCount == 1)
    #expect(service.registerCount == 1)
    #expect(try await control.pendingRequest() == persistedRequest)
    #expect(try await control.latestProgress()?.phase == .queued)
    let commands = await probe.requests.map(\.arguments)
    #expect(commands.count == (runningAfterRegistration ? 2 : 3))
    if !runningAfterRegistration {
        #expect(commands.last == ["kickstart", "gui/501/io.github.xiuyuwu.DailyDisk.agent"])
    }
}

@Test(
    "Missing-job recovery stops after one repair or when approval is required",
    arguments: [LaunchAgentStatus.enabled, .requiresApproval])
func reinstallRecoveryIsBounded(status: LaunchAgentStatus) async throws {
    let service = FakeRegistrationService(status: .enabled)
    service.statusAfterRegister = status
    let probe = LaunchctlProbe(responses: [missingLaunchAgent(), missingLaunchAgent()])
    let manager = LaunchAgentManager(
        service: service, bundleURL: URL(fileURLWithPath: "/Applications/DailyDisk.app"),
        processRunner: probe, userID: 501
    )
    let expected: LaunchAgentManagerError =
        status == .enabled
        ? .runtimeStatusUnavailable : .serviceUnavailable(status)
    await #expect(throws: expected) { try await manager.startIfNeeded() }
    #expect(service.unregisterCount == 1)
    #expect(service.registerCount == 1)
    #expect(await probe.requests.count == (status == .enabled ? 2 : 1))
}

@Test("Runtime inspection errors do not trigger registration repair")
func reinstallDoesNotRepairUnknownFailure() async throws {
    let service = FakeRegistrationService(status: .enabled)
    let probe = LaunchctlProbe(responses: [launchctlResult(status: 1)])
    let manager = LaunchAgentManager(
        service: service, bundleURL: URL(fileURLWithPath: "/Applications/DailyDisk.app"),
        processRunner: probe, userID: 501
    )
    await #expect(throws: LaunchAgentManagerError.runtimeStatusUnavailable) {
        try await manager.startIfNeeded()
    }
    #expect(service.unregisterCount == 0)
    #expect(service.registerCount == 0)
}

@Test("Missing-job recovery validates the installation path before unregistering")
func reinstallRequiresStablePath() async throws {
    let service = FakeRegistrationService(status: .enabled)
    let probe = LaunchctlProbe(responses: [missingLaunchAgent()])
    let manager = LaunchAgentManager(
        service: service, bundleURL: URL(fileURLWithPath: "/tmp/DailyDisk.app"),
        processRunner: probe, userID: 501
    )
    await #expect(throws: LaunchAgentManagerError.unstableApplicationPath("/tmp/DailyDisk.app")) {
        try await manager.startIfNeeded()
    }
    #expect(service.unregisterCount == 0)
    #expect(service.registerCount == 0)
}

@Test("Registration repair propagates failures without attempting a launch", arguments: [false, true])
func reinstallRegistrationFailure(unregisterFails: Bool) async throws {
    let service = FakeRegistrationService(status: .enabled)
    if unregisterFails {
        service.unregistrationError = .serviceUnavailable(.unknown)
    } else {
        service.registrationError = .serviceUnavailable(.unknown)
    }
    let probe = LaunchctlProbe(responses: [missingLaunchAgent()])
    let manager = LaunchAgentManager(
        service: service, bundleURL: URL(fileURLWithPath: "/Applications/DailyDisk.app"),
        processRunner: probe, userID: 501
    )
    await #expect(throws: LaunchAgentManagerError.serviceUnavailable(.unknown)) {
        try await manager.startIfNeeded()
    }
    #expect(service.unregisterCount == 1)
    #expect(service.registerCount == (unregisterFails ? 0 : 1))
    #expect(await probe.requests.count == 1)
}

private actor ConcurrentMissingJobProbe: ProcessRunning {
    private var firstWaiter: CheckedContinuation<Void, Never>?
    private var inspections = 0
    let loadedAfterRepair: Bool
    init(loadedAfterRepair: Bool = true) { self.loadedAfterRepair = loadedAfterRepair }
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        if request.arguments.first == "print" {
            inspections += 1
            if inspections == 1 {
                await withCheckedContinuation { firstWaiter = $0 }
                return missingLaunchAgent()
            }
            if inspections == 2 {
                firstWaiter?.resume()
                firstWaiter = nil
                return missingLaunchAgent()
            }
            return loadedAfterRepair ? launchctlResult("state = running\npid = 42\n") : missingLaunchAgent()
        }
        return launchctlResult()
    }
}

@Test("Simultaneous starts must not unregister the freshly repaired job twice")
func concurrentReinstallRepair() async throws {
    let service = FakeRegistrationService(status: .enabled)
    let manager = LaunchAgentManager(
        service: service, bundleURL: URL(fileURLWithPath: "/Applications/DailyDisk.app"),
        processRunner: ConcurrentMissingJobProbe(), userID: 501)
    async let first = manager.startIfNeeded()
    async let second = manager.startIfNeeded()
    _ = try await (first, second)
    #expect(service.unregisterCount == 1)
    #expect(service.registerCount == 1)
}

@Test("Concurrent repair failure cannot trigger a second unregister", arguments: [false, true])
func concurrentReinstallFailure(registerFails: Bool) async {
    let service = FakeRegistrationService(status: .enabled)
    if registerFails { service.registrationError = .serviceUnavailable(.unknown) }
    let manager = LaunchAgentManager(
        service: service, bundleURL: URL(fileURLWithPath: "/Applications/DailyDisk.app"),
        processRunner: ConcurrentMissingJobProbe(loadedAfterRepair: false), userID: 501)
    async let first = try? manager.startIfNeeded()
    async let second = try? manager.startIfNeeded()
    let results = await (first, second)
    #expect(results.0 == nil && results.1 == nil)
    #expect(service.unregisterCount == 1)
    #expect(service.registerCount == 1)
}
