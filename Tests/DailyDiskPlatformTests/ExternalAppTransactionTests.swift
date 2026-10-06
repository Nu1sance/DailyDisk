import Darwin
import Foundation
import Testing

@testable import DailyDiskPlatform

private enum InstallationFault: Error { case injected }

private struct InstallationFixture {
    let root: URL
    let directory: URL
    let candidate: URL
    let store: RunControlStore
    var target: URL { directory.appendingPathComponent("DailyDisk.app") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directory = root.appendingPathComponent("Applications")
        candidate = root.appendingPathComponent("Candidate.app")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try RunControlStore(rootURL: root.appendingPathComponent("Control"))
        try writeApp(candidate, build: 17)
    }
    func transaction(boundary: @escaping @Sendable (ExternalAppTransaction.Boundary) throws -> Void = { _ in })
        -> ExternalAppTransaction
    {
        ExternalAppTransaction(
            control: store, directory: directory, candidate: candidate, validate: readApp,
            requireIdle: {}, boundary: boundary)
    }
    func prepare() async throws {
        let state = try await store.beginUpdatePreparation(restoreDailyTask: true)
        try await store.setUpdatePhase(id: state.id, phase: .ready)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private func writeApp(_ url: URL, build: Int) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try Data(String(build).utf8).write(to: url.appendingPathComponent("build"))
}

private func readApp(_ url: URL) throws -> Int {
    guard let result = Int(try String(contentsOf: url.appendingPathComponent("build"), encoding: .utf8)) else {
        throw InstallationFault.injected
    }
    return result
}

@Test("Native installer publishes a complete first app and preserves explicit task restoration")
func externalFirstInstallAndRemove() async throws {
    let fixture = try InstallationFixture()
    defer { fixture.cleanup() }
    #expect(try await fixture.transaction().run(removing: false) == .installed)
    #expect(try readApp(fixture.target) == 17)
    #expect(try await fixture.store.updatePreparation() == nil)
    try await fixture.prepare()
    #expect(try await fixture.transaction().run(removing: true) == .removed)
    #expect(!FileManager.default.fileExists(atPath: fixture.target.path))
    #expect(try await fixture.store.updatePreparation() == nil)
}

@Test("Actual newer or equal apps survive stale Homebrew receipts without preparation", arguments: [17, 18])
func externalNoDowngrade(build: Int) async throws {
    let fixture = try InstallationFixture()
    defer { fixture.cleanup() }
    try writeApp(fixture.target, build: build)
    #expect(try await fixture.transaction().run(removing: false) == .preservedNewer)
    #expect(try readApp(fixture.target) == build)
    #expect(try await fixture.store.updatePreparation() == nil)
}

@Test("Existing apps require preparation before replacement or removal", arguments: [false, true])
func externalRejectUnprepared(removing: Bool) async throws {
    let fixture = try InstallationFixture()
    defer { fixture.cleanup() }
    try writeApp(fixture.target, build: 16)
    await #expect(throws: UpdatePreparationError.invalidState) {
        _ = try await fixture.transaction().run(removing: removing)
    }
    #expect(try readApp(fixture.target) == 16)
}

@Test(
    "Interrupted native replacement remains blocked across restart and recovers on explicit retry",
    arguments: [ExternalAppTransaction.Boundary.copied, .oldMoved, .installed])
func externalInterruptedReplacement(boundary: ExternalAppTransaction.Boundary) async throws {
    let fixture = try InstallationFixture()
    defer { fixture.cleanup() }
    try writeApp(fixture.target, build: 16)
    try await fixture.prepare()
    let transaction = fixture.transaction { point in
        if point == boundary { throw InstallationFault.injected }
    }
    await #expect(throws: InstallationFault.self) { _ = try await transaction.run(removing: false) }
    let reopened = try RunControlStore(rootURL: fixture.root.appendingPathComponent("Control"))
    #expect(try await reopened.updatePreparation()?.phase == .externalRecoveryRequired)
    #expect(try await reopened.acquireHelperUpdateLease() == nil)
    let result = try await fixture.transaction().run(removing: false)
    #expect(result == .installed || result == .preservedNewer)
    #expect(try readApp(fixture.target) == 17)
    #expect(try await reopened.updatePreparation()?.phase == .ready)
    #expect(try await reopened.updatePreparation()?.restoreDailyTask == true)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path) == ["DailyDisk.app"])
}

@Test("Interrupted uninstall finishes under leases and preserves unrelated user files")
func externalInterruptedUninstall() async throws {
    let fixture = try InstallationFixture()
    defer { fixture.cleanup() }
    try writeApp(fixture.target, build: 16)
    try await fixture.prepare()
    let unrelated = fixture.root.appendingPathComponent("history")
    try Data("keep".utf8).write(to: unrelated)
    let transaction = fixture.transaction { if $0 == .oldMoved { throw InstallationFault.injected } }
    await #expect(throws: InstallationFault.self) { _ = try await transaction.run(removing: true) }
    #expect(try await fixture.store.updatePreparation()?.phase == .externalRecoveryRequired)
    #expect(try await fixture.transaction().run(removing: true) == .removed)
    #expect(try await fixture.store.updatePreparation() == nil)
    #expect(try String(contentsOf: unrelated, encoding: .utf8) == "keep")
}

@Test("Missing-app removal clears manual preparation but never cancels Sparkle", arguments: [false, true])
func externalRemoveMissingApp(sparkle: Bool) async throws {
    let fixture = try InstallationFixture()
    defer { fixture.cleanup() }
    try await fixture.prepare()
    if sparkle {
        let state = try #require(await fixture.store.updatePreparation())
        try await fixture.store.armSparkleInstallation(id: state.id, sourceBuild: "16", targetBuild: "17")
        await #expect(throws: UpdatePreparationError.invalidState) {
            _ = try await fixture.transaction().run(removing: true)
        }
        #expect(try await fixture.store.updatePreparation()?.phase == .sparkleInstalling)
    } else {
        #expect(try await fixture.transaction().run(removing: true) == .removed)
        #expect(try await fixture.store.updatePreparation() == nil)
    }
}

@Test("Native replacement holds installation and helper leases through file mutations")
func externalOwnsMutationLifetime() async throws {
    let fixture = try InstallationFixture()
    defer { fixture.cleanup() }
    let controlRoot = fixture.root.appendingPathComponent("Control")
    let directory = fixture.directory
    let transaction = fixture.transaction { _ in
        #expect(throws: UpdatePreparationError.busy) {
            _ = try UpdateWorkLease(url: controlRoot.appendingPathComponent(".update-work.lock"), exclusive: false)
        }
        #expect(throws: UpdatePreparationError.installationInProgress) {
            _ = try AppInstallationLease(controlDirectory: controlRoot, installationDirectory: directory)
        }
    }
    _ = try await transaction.run(removing: false)
}

@Test("Homebrew command classification rejects unknown commands and similarly named scripts")
func homebrewInvocationArguments() throws {
    let prefix = ["ruby", "-W1", "/opt/homebrew/Library/Homebrew/brew.rb"]
    #expect(
        try HomebrewInvocation.parse(arguments: prefix + ["upgrade", "--cask", "nu1sance/tap/dailydisk"]) == .upgrade)
    #expect(try HomebrewInvocation.parse(arguments: prefix + ["reinstall"]) == .reinstall)
    #expect(try HomebrewInvocation.parse(arguments: prefix + ["rm"]) == .uninstall)
    #expect(try HomebrewInvocation.parse(arguments: ["ruby", "/tmp/brew.rb", "uninstall"]) == nil)
    #expect(throws: UpdatePreparationError.invalidState) {
        _ = try HomebrewInvocation.parse(arguments: prefix + ["bundle"])
    }
    #expect(throws: UpdatePreparationError.invalidState) { _ = try HomebrewInvocation.parse(arguments: prefix) }
}

@Test(
    "Native installation process-death fixture",
    .enabled(if: ProcessInfo.processInfo.environment["DAILYDISK_CRASH_FIXTURE_ROOT"] != nil))
func externalInstallationCrashFixture() async throws {
    let environment = ProcessInfo.processInfo.environment
    let root = URL(fileURLWithPath: try #require(environment["DAILYDISK_CRASH_FIXTURE_ROOT"]))
        .resolvingSymlinksInPath()
    let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    #expect(root.deletingLastPathComponent() == temporary)
    guard root.deletingLastPathComponent() == temporary,
        root.lastPathComponent.hasPrefix("dailydisk-crash-")
    else { throw InstallationFault.injected }
    let store = try RunControlStore(rootURL: root.appendingPathComponent("Control"))
    if try await store.updatePreparation() == nil {
        let state = try await store.beginUpdatePreparation(restoreDailyTask: true)
        try await store.setUpdatePhase(id: state.id, phase: .ready)
    }
    let crashAt = environment["DAILYDISK_CRASH_FIXTURE_BOUNDARY"]
    let transaction = ExternalAppTransaction(
        control: store, directory: root.appendingPathComponent("Applications"),
        candidate: root.appendingPathComponent("Candidate.app"), validate: readApp, requireIdle: {},
        boundary: { point in
            if String(describing: point) == crashAt { kill(getpid(), SIGKILL) }
        })
    _ = try await transaction.run(removing: false)
    #expect(try readApp(root.appendingPathComponent("Applications/DailyDisk.app")) == 17)
    #expect(try await store.updatePreparation()?.phase == .ready)
}

@Test(
    "Signed release transaction uses real bundle verification in an isolated destination",
    .enabled(if: ProcessInfo.processInfo.environment["DAILYDISK_SIGNED_INSTALLER_CANDIDATE"] != nil))
func externalSignedReleaseFixture() async throws {
    let environment = ProcessInfo.processInfo.environment
    let candidate = URL(fileURLWithPath: try #require(environment["DAILYDISK_SIGNED_INSTALLER_CANDIDATE"]))
    let reference = try HomebrewBundleVerifier(reference: candidate)
    let build = try reference.validate(candidate)
    let fixture = try InstallationFixture()
    defer { fixture.cleanup() }
    if let baseline = environment["DAILYDISK_SIGNED_INSTALLER_BASELINE"] {
        let source = URL(fileURLWithPath: baseline)
        #expect(try reference.validate(source) < build)
        try FileManager.default.copyItem(at: source, to: fixture.target)
        try await fixture.prepare()
    }
    let transaction = ExternalAppTransaction(
        control: fixture.store, directory: fixture.directory, candidate: candidate,
        validate: { try reference.validate($0) }, requireIdle: {})
    #expect(try await transaction.run(removing: false) == .installed)
    #expect(try reference.validate(fixture.target) == build)
    #expect(try await transaction.run(removing: false) == .preservedNewer)
    if try await fixture.store.updatePreparation() == nil { try await fixture.prepare() }
    #expect(try await transaction.run(removing: true) == .removed)
    #expect(try await fixture.store.updatePreparation() == nil)
}
