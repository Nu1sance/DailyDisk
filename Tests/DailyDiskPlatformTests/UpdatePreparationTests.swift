import DailyDiskCore
import Foundation
import Testing

@testable import DailyDiskPlatform

private actor UpdateTaskFixture: UpdateTaskManaging {
    var registration: LaunchAgentStatus
    var running = false
    var failUnregister = false
    var failRegister = false
    var needsApproval = false
    var registrations = 0
    init(_ status: LaunchAgentStatus = .enabled) { registration = status }
    func status() -> LaunchAgentStatus { registration }
    func register() throws {
        if failRegister { throw UpdatePreparationError.busy }
        registrations += 1
        registration = needsApproval ? .requiresApproval : .enabled
    }
    func unregister() throws {
        registration = .notRegistered
        if failUnregister { throw UpdatePreparationError.busy }
    }
    func runtimeStatus() -> LaunchAgentRuntimeStatus {
        LaunchAgentRuntimeStatus(isRunning: running, processID: nil, lastExitCode: nil, state: nil)
    }
    func setFailures(unregister: Bool = false, register: Bool = false) {
        failUnregister = unregister
        failRegister = register
    }
    func requireApproval() { needsApproval = true }
}

private func updateRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test("Update admission serializes helpers and rejects every new request until explicit recovery")
func updateBlocksAdmission() async throws {
    let root = try updateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RunControlStore(rootURL: root.appendingPathComponent("Control"))
    let other = try RunControlStore(rootURL: root.appendingPathComponent("Control"))
    var lease = try await store.acquireHelperUpdateLease()
    #expect(lease != nil)
    await #expect(throws: UpdatePreparationError.busy) {
        _ = try await other.beginUpdatePreparation(restoreDailyTask: true)
    }
    withExtendedLifetime(lease) {}
    lease = nil
    let state = try await other.beginUpdatePreparation(restoreDailyTask: true)
    #expect(try await store.acquireHelperUpdateLease() == nil)
    let request = try DailyDiskRunRequest(createdAt: Date(timeIntervalSince1970: 100))
    await #expect(throws: RunControlStoreError.updateInProgress) { try await store.enqueue(request) }
    await #expect(throws: RunControlStoreError.updateInProgress) { try await store.beginScheduledRun(request) }
    await #expect(throws: RunControlStoreError.updateInProgress) { _ = try await store.claimPendingRequest() }
    await #expect(throws: UpdatePreparationError.invalidState) {
        try await store.finishUpdateRestoration(id: state.id)
    }
    try await store.setUpdatePhase(id: state.id, phase: .restoring)
    try await store.finishUpdateRestoration(id: state.id)
    #expect(try await store.acquireHelperUpdateLease() != nil)
    try await store.enqueue(request)
    await #expect(throws: UpdatePreparationError.busy) {
        _ = try await other.beginUpdatePreparation(restoreDailyTask: false)
    }
    #expect(try await store.pendingRequest() == request)
}

@Test("Update restart restores enabled task exactly once and leaves disabled tasks disabled", arguments: [true, false])
func updateRestorePreferences(enabled: Bool) async throws {
    let root = try updateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let location = root.appendingPathComponent("Control")
    let store = try RunControlStore(rootURL: location)
    let manager = UpdateTaskFixture(enabled ? .enabled : .notRegistered)
    let coordinator = UpdateCoordinator(
        control: store, manager: manager, installationDirectory: root, checkSessions: {}, writerIsActive: { false })
    try await coordinator.prepare()
    #expect(try await store.updatePreparation()?.phase == .ready)
    #expect(await manager.status() == .notRegistered)
    let restarted = try RunControlStore(rootURL: location)
    #expect(try await restarted.acquireHelperUpdateLease() == nil)
    let recovery = UpdateCoordinator(
        control: restarted, manager: manager, installationDirectory: root, checkSessions: {}, writerIsActive: { false })
    try await recovery.restore()
    try await recovery.restore()
    #expect(await manager.registrations == (enabled ? 1 : 0))
    #expect(try await store.updatePreparation() == nil)
}

@Test("Partial unregistration and failed restoration retain recoverable gate; installer owns recovery exclusion")
func updateFailureRecovery() async throws {
    let root = try updateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RunControlStore(rootURL: root.appendingPathComponent("Control"))
    let manager = UpdateTaskFixture()
    let coordinator = UpdateCoordinator(
        control: store, manager: manager, installationDirectory: root, checkSessions: {}, writerIsActive: { false })
    await manager.setFailures(unregister: true)
    await #expect(throws: UpdatePreparationError.busy) { try await coordinator.prepare() }
    #expect(try await store.updatePreparation()?.phase == .preparing)
    await manager.setFailures(register: true)
    await #expect(throws: UpdatePreparationError.busy) { try await coordinator.restore() }
    #expect(try await store.updatePreparation()?.phase == .restoring)
    let lock = root.appendingPathComponent(".DailyDisk-install.lock")
    try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
    await #expect(throws: UpdatePreparationError.installationInProgress) { try await coordinator.restore() }
    try FileManager.default.removeItem(at: lock)
    await manager.setFailures()
    await manager.requireApproval()
    try await coordinator.restore()
    #expect(await manager.status() == .requiresApproval)
    #expect(try await store.updatePreparation() == nil)
}

@Test("Unsafe update state fails closed without accepting paths or substituted files")
func updateControlSafety() async throws {
    let root = try updateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let location = root.appendingPathComponent("Control")
    let store = try RunControlStore(rootURL: location)
    let state = try await store.beginUpdatePreparation(restoreDailyTask: false)
    let file = location.appendingPathComponent("update-preparation.json")
    let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    let data = try Data(contentsOf: file)
    var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    json["path"] = "/untrusted"
    try JSONSerialization.data(withJSONObject: json).write(to: file)
    await #expect(throws: RunControlStoreError.unexpectedJSONShape) { _ = try await store.acquireHelperUpdateLease() }
    try data.write(to: file)
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.linkItem(at: file, to: alias)
    await #expect(throws: RunControlStoreError.unsafeControlFile) { _ = try await store.updatePreparation() }
    try FileManager.default.removeItem(at: alias)
    try FileManager.default.removeItem(at: file)
    try data.write(to: alias)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: alias)
    await #expect(throws: (any Error).self) { _ = try await store.updatePreparation() }
    #expect(state.version == 1)
}

@Test("Concurrent helper admission and update preparation cannot both acquire ownership")
func updateAdmissionRace() async throws {
    enum Result: Sendable {
        case helper(UpdateWorkLease?)
        case prepared, busy
    }
    let root = try updateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 0..<32 {
        let location = root.appendingPathComponent("Control-\(index)")
        let a = try RunControlStore(rootURL: location)
        let b = try RunControlStore(rootURL: location)
        let results = try await withThrowingTaskGroup(of: Result.self) { group in
            group.addTask { .helper(try await a.acquireHelperUpdateLease()) }
            group.addTask {
                do {
                    _ = try await b.beginUpdatePreparation(restoreDailyTask: false)
                    return .prepared
                } catch UpdatePreparationError.busy { return .busy }
            }
            var results: [Result] = []
            for try await result in group { results.append(result) }
            return results
        }
        let helperOwns = results.contains { if case .helper(.some) = $0 { true } else { false } }
        let prepared = results.contains { if case .prepared = $0 { true } else { false } }
        #expect(helperOwns != prepared)
        withExtendedLifetime(results) {}
    }
}

@Test("Writer activity and unresolved approval do not change task settings or create an update gate")
func updateBusyAndApproval() async throws {
    let root = try updateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RunControlStore(rootURL: root.appendingPathComponent("Control"))
    let manager = UpdateTaskFixture()
    let busy = UpdateCoordinator(
        control: store, manager: manager, installationDirectory: root, checkSessions: {}, writerIsActive: { true })
    await #expect(throws: UpdatePreparationError.busy) { try await busy.prepare() }
    #expect(await manager.status() == .enabled)
    #expect(try await store.updatePreparation() == nil)
    let pending = UpdateTaskFixture(.requiresApproval)
    let unresolved = UpdateCoordinator(
        control: store, manager: pending, installationDirectory: root, checkSessions: {}, writerIsActive: { false })
    await #expect(throws: UpdatePreparationError.unsupportedRegistration) { try await unresolved.prepare() }
    #expect(await pending.status() == .requiresApproval)
    #expect(try await store.updatePreparation() == nil)
}

@Test(
    "Sparkle gates installation across restart and only the target build restores preferences",
    arguments: [true, false])
func sparkleInstallationRecovery(enabled: Bool) async throws {
    let root = try updateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RunControlStore(rootURL: root.appendingPathComponent("Control"))
    let manager = UpdateTaskFixture(enabled ? .enabled : .notRegistered)
    func coordinator(_ build: String) -> UpdateCoordinator {
        UpdateCoordinator(
            control: store, manager: manager, installationDirectory: root,
            currentBuild: build, checkSessions: {}, writerIsActive: { false })
    }
    await #expect(throws: UpdatePreparationError.invalidState) {
        _ = try await coordinator("10").prepareSparkleInstallation(targetBuild: "9")
    }
    #expect(try await store.updatePreparation() == nil)
    let id = try await coordinator("10").prepareSparkleInstallation(targetBuild: "11")
    #expect(try await store.acquireHelperUpdateLease() == nil)
    #expect(await manager.status() == .notRegistered)
    await #expect(throws: UpdatePreparationError.installationInProgress) { try await coordinator("10").restore() }
    await #expect(throws: UpdatePreparationError.installationInProgress) { try await coordinator("12").restore() }
    #expect(try await coordinator("10").prepareSparkleInstallation(targetBuild: "11") == id)
    try await coordinator("11").restore()
    #expect(try await store.updatePreparation() == nil)
    #expect(await manager.registrations == (enabled ? 1 : 0))
}

@Test("Cancelled download restores scheduling without installing or advancing inventory")
func sparkleCancelledDownload() async throws {
    let root = try updateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RunControlStore(rootURL: root.appendingPathComponent("Control"))
    let manager = UpdateTaskFixture()
    let coordinator = UpdateCoordinator(
        control: store, manager: manager, installationDirectory: root,
        currentBuild: "10", checkSessions: {}, writerIsActive: { false })
    let id = try await coordinator.prepareSparkleInstallation(targetBuild: "11")
    await #expect(throws: UpdatePreparationError.invalidState) {
        try await coordinator.cancelSparkleDownload(id: UUID())
    }
    try await coordinator.cancelSparkleDownload(id: id)
    #expect(try await store.updatePreparation() == nil)
    #expect(await manager.status() == .enabled)
}

@Test("Preparation and recovery work with a read-only application directory")
func updateReadOnlyApplicationDirectory() async throws {
    let root = try updateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("Applications")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
    let control = try RunControlStore(rootURL: root.appendingPathComponent("Control"))
    let manager = UpdateTaskFixture()
    let coordinator = UpdateCoordinator(
        control: control, manager: manager, installationDirectory: directory,
        checkSessions: {}, writerIsActive: { false })
    try await coordinator.prepare()
    try await coordinator.restore()
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    #expect(await manager.status() == .enabled)
}

@Test("Private installation lease excludes another coordinator and rejects symlink substitution")
func privateInstallationExclusion() async throws {
    let root = try updateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let location = root.appendingPathComponent("Control")
    let control = try RunControlStore(rootURL: location)
    var lease: AppInstallationLease? = try await control.acquireInstallationLease(installationDirectory: root)
    let coordinator = UpdateCoordinator(
        control: control, manager: UpdateTaskFixture(), installationDirectory: root,
        checkSessions: {}, writerIsActive: { false })
    await #expect(throws: UpdatePreparationError.installationInProgress) { try await coordinator.prepare() }
    withExtendedLifetime(lease) {}
    lease = nil
    try await coordinator.prepare()
    try await coordinator.restore()
    let file = location.appendingPathComponent(".installation.lock")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("victim"))
    await #expect(throws: (any Error).self) { try await coordinator.prepare() }
}

@Test("Other login sessions block preparation before changing task state")
func updateOtherUserSession() async throws {
    try UpdateSessionGuard.validate("system = {\nuser/0\nuser/501\n}", currentUID: 501)
    #expect(throws: UpdatePreparationError.otherUserSession) {
        try UpdateSessionGuard.validate("system = {\nuser/0\nuser/501\nuser/502\n}", currentUID: 501)
    }
    #expect(throws: UpdatePreparationError.otherUserSession) {
        try UpdateSessionGuard.validate("", currentUID: 501)
    }
    let root = try updateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let control = try RunControlStore(rootURL: root.appendingPathComponent("Control"))
    let manager = UpdateTaskFixture()
    let coordinator = UpdateCoordinator(
        control: control, manager: manager, installationDirectory: root,
        checkSessions: { throw UpdatePreparationError.otherUserSession }, writerIsActive: { false })
    await #expect(throws: UpdatePreparationError.otherUserSession) { try await coordinator.prepare() }
    #expect(try await control.updatePreparation() == nil)
    #expect(await manager.status() == .enabled)
}

@Test("Installation lease releases before an async caller drops its retained wrapper")
func explicitInstallationLeaseRelease() async throws {
    let root = try updateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let control = try RunControlStore(rootURL: root.appendingPathComponent("Control"))
    let previous = try await control.acquireInstallationLease(installationDirectory: root)
    previous.release()
    let next = try await control.acquireInstallationLease(installationDirectory: root)
    next.release()
    previous.release()
    withExtendedLifetime((previous, next)) {}
}
