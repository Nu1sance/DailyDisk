import DailyDiskCore
import Darwin
import Foundation
import Testing

@testable import DailyDiskPlatform

private func publishPhases(
    _ phases: [ScanProgressPhase],
    store: RunControlStore,
    request: DailyDiskRunRequest,
    mode: ScanExecutionMode
) async throws -> ScanProgressSnapshot {
    var latest: ScanProgressSnapshot?
    for phase in phases {
        let snapshot = try ScanProgressSnapshot(
            requestID: request.requestID,
            trigger: .manual,
            mode: mode,
            phase: phase,
            startedAt: request.createdAt,
            updatedAt: request.createdAt.addingTimeInterval(Double(phase.sequenceRank + 1)),
            domainOrdinal: 1,
            domainCount: 1,
            counters: ScanProgressCounters(visitedPaths: UInt64(phase.sequenceRank * 10))
        )
        await store.publish(snapshot)
        latest = snapshot
    }
    return try #require(latest)
}

private func controlRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DailyDiskControlTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("Control", isDirectory: true)
    return root
}

@Test("Manual request is atomically claimed once and survives store restart")
func requestClaimAndReconnect() async throws {
    let root = try controlRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let request = try DailyDiskRunRequest(
        requestID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        createdAt: Date(timeIntervalSince1970: 100)
    )
    let producer = try RunControlStore(rootURL: root)
    try await producer.enqueue(request)
    #expect(try await producer.pendingRequest() == request)
    #expect(try await producer.latestProgress()?.phase == .queued)

    let helper = try RunControlStore(rootURL: root)
    #expect(try await helper.claimPendingRequest() == request)
    await #expect(throws: RunControlStoreError.runAlreadyActive) {
        _ = try await helper.claimPendingRequest()
    }
    #expect(try await producer.activeRequest() == request)

    let progress = try await publishPhases(
        [.preparing, .discoveringStorage, .scanningFiles],
        store: helper,
        request: request,
        mode: .initialFull
    )

    let reconnectedGUI = try RunControlStore(rootURL: root)
    #expect(try await reconnectedGUI.latestProgress() == progress)
}

@Test("A restarted tracker preserves active progress identity and counters")
func trackerResumePreservesProgress() async throws {
    let root = try controlRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try RunControlStore(rootURL: root)
    let request = try DailyDiskRunRequest(createdAt: Date(timeIntervalSince1970: 10))
    try await store.enqueue(request)
    _ = try await store.claimPendingRequest()
    let progress = try await publishPhases(
        [.preparing, .discoveringStorage, .scanningFiles],
        store: store,
        request: request,
        mode: .initialFull
    )
    let resumed = try ScanProgressTracker(
        resuming: progress,
        reporter: store,
        cancellationChecker: store,
        commitBoundary: store,
        publicationInterval: 0
    )
    try await resumed.beginDomain(ordinal: 1, count: 1)
    try await resumed.transition(to: .preparing, mode: .initialFull)
    try await resumed.checkpoint(ScanProgressDelta(visitedPaths: 5))

    let latest = try #require(try await store.latestProgress())
    #expect(latest.phase == .preparing)
    #expect(latest.startedAt == progress.startedAt)
    #expect(latest.counters.visitedPaths == progress.counters.visitedPaths + 5)
}

@Test("Tracker seals cancellation and commit transition under one control lock")
func trackerCommitBoundaryIsAtomic() async throws {
    let root = try controlRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try RunControlStore(rootURL: root)
    let request = try DailyDiskRunRequest(createdAt: Date())
    try await store.enqueue(request)
    let claimed = try #require(try await store.claimPendingRequest())
    let tracker = try ScanProgressTracker(
        context: ScanProgressContext(
            requestID: claimed.requestID,
            trigger: .manual,
            startedAt: claimed.createdAt
        ),
        reporter: store,
        cancellationChecker: store,
        commitBoundary: store,
        runBindingRecorder: store,
        publicationInterval: 60
    )
    let boundRunID = ScanRun.ID()
    try await tracker.bindRun(boundRunID)
    #expect(try await store.runBinding()?.runID == boundRunID)
    for phase in [
        ScanProgressPhase.preparing, .discoveringStorage, .replayingEvents,
        .catchingUpEvents, .sealingInventory, .collectingDiagnostics,
    ] {
        try await tracker.transition(to: phase, mode: .incremental)
    }
    try await store.requestCancellation(
        DailyDiskCancelRequest(requestID: request.requestID)
    )
    await #expect(throws: ScanProgressError.cancelled) {
        try await tracker.transition(to: .committing, mode: .incremental)
    }
    #expect(await store.channelError() == nil)
    #expect(try await store.latestProgress()?.phase == .collectingDiagnostics)

    try await tracker.transition(to: .cancelling, mode: .incremental)
    try await tracker.transition(to: .cancelled, mode: .incremental)
    let summary = try DailyDiskRunSummary(
        requestID: claimed.requestID,
        trigger: .manual,
        terminalState: .cancelled,
        startedAt: claimed.createdAt,
        finishedAt: Date().addingTimeInterval(1),
        completedDomainCount: 0,
        failedDomainCount: 0,
        reportRunIDs: []
    )
    try await store.complete(summary)
    #expect(try await store.activeRequest() == nil)
    #expect(try await store.runBinding() == nil)
    #expect(try await store.latestProgress()?.phase == .cancelled)
}

@Test("Cancellation is request-scoped and blocked after commit boundary")
func cancellationScopeAndBoundary() async throws {
    let root = try controlRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try RunControlStore(rootURL: root)
    let request = try DailyDiskRunRequest(createdAt: Date(timeIntervalSince1970: 10))
    try await store.enqueue(request)
    _ = try await store.claimPendingRequest()
    _ = try await publishPhases(
        [.preparing, .discoveringStorage, .scanningFiles],
        store: store,
        request: request,
        mode: .initialFull
    )
    try await store.requestCancellation(
        DailyDiskCancelRequest(
            requestID: request.requestID,
            createdAt: request.createdAt.addingTimeInterval(2)
        )
    )
    await #expect(throws: ScanProgressError.cancelled) {
        try await store.checkCancellation(requestID: request.requestID)
    }
    await #expect(throws: RunControlStoreError.requestIDMismatch) {
        try await store.checkCancellation(requestID: UUID())
    }

    _ = try await publishPhases(
        [.catchingUpEvents, .sealingInventory, .collectingDiagnostics, .committing],
        store: store,
        request: request,
        mode: .initialFull
    )
    await #expect(throws: RunControlStoreError.notCancellable(.committing)) {
        try await store.requestCancellation(
            DailyDiskCancelRequest(requestID: request.requestID)
        )
    }
}

@Test("Terminal completion removes active request and retains summary")
func terminalCompletion() async throws {
    let root = try controlRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try RunControlStore(rootURL: root)
    let request = try DailyDiskRunRequest(createdAt: Date(timeIntervalSince1970: 10))
    try await store.enqueue(request)
    _ = try await store.claimPendingRequest()
    _ = try await publishPhases(
        [
            .preparing, .discoveringStorage, .replayingEvents,
            .catchingUpEvents, .sealingInventory, .collectingDiagnostics,
            .committing, .publishingReport,
        ],
        store: store,
        request: request,
        mode: .incremental
    )
    let summary = try DailyDiskRunSummary(
        requestID: request.requestID,
        trigger: .manual,
        terminalState: .succeeded,
        startedAt: request.createdAt,
        finishedAt: request.createdAt.addingTimeInterval(20),
        completedDomainCount: 1,
        failedDomainCount: 0,
        reportRunIDs: [UUID()]
    )
    try await store.complete(summary)

    #expect(try await store.activeRequest() == nil)
    #expect(try await store.latestSummary() == summary)
    #expect(try await store.latestProgress()?.phase == .completed)
}

@Test("Control files and directory are private user-owned regular files")
func privateControlPermissions() async throws {
    let root = try controlRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try RunControlStore(rootURL: root)
    try await store.enqueue(DailyDiskRunRequest())

    var rootStatus = Darwin.stat()
    #expect(lstat(root.path, &rootStatus) == 0)
    #expect(rootStatus.st_uid == getuid())
    #expect(rootStatus.st_mode & 0o077 == 0)
    for name in ["pending-request.json", "progress.json", ".control.lock"] {
        var status = Darwin.stat()
        #expect(lstat(root.appendingPathComponent(name).path, &status) == 0)
        #expect(status.st_uid == getuid())
        #expect(status.st_mode & S_IFMT == S_IFREG)
        #expect(status.st_mode & 0o077 == 0)
    }
}

@Test("Unknown JSON fields and symlinked control roots are rejected")
func unsafeControlInputsAreRejected() async throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("DailyDiskControlUnsafe", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    let target = parent.appendingPathComponent("target", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
    let link = parent.appendingPathComponent("Control")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(throws: (any Error).self) {
        _ = try RunControlStore(rootURL: link)
    }

    let root = parent.appendingPathComponent("SafeControl", isDirectory: true)
    let store = try RunControlStore(rootURL: root)
    let malformed = Data(
        #"{"version":1,"requestID":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","action":"scanNow","requestedMode":"automatic","createdAt":0,"command":"rm -rf /"}"#
            .utf8
    )
    try malformed.write(to: root.appendingPathComponent("pending-request.json"))
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: root.appendingPathComponent("pending-request.json").path
    )
    await #expect(throws: RunControlStoreError.unexpectedJSONShape) {
        _ = try await store.claimPendingRequest()
    }
    #expect(try await store.pendingRequest() == nil)
    #expect(try await store.activeRequest() == nil)
}

@Test("Symlinked lock files are rejected without touching their target")
func symlinkedLockIsRejected() throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("DailyDiskControlLock", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let root = parent.appendingPathComponent("Control", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    defer { try? FileManager.default.removeItem(at: parent) }
    let target = parent.appendingPathComponent("target")
    try Data("target".utf8).write(to: target)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent(".control.lock"),
        withDestinationURL: target
    )

    #expect(throws: (any Error).self) {
        _ = try RunControlStore(rootURL: root)
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
    #expect(attributes[.posixPermissions] as? NSNumber == NSNumber(value: 0o644))

    let hardLinkRoot = parent.appendingPathComponent("HardLinkControl", isDirectory: true)
    try FileManager.default.createDirectory(
        at: hardLinkRoot,
        withIntermediateDirectories: false
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: hardLinkRoot.path
    )
    try FileManager.default.linkItem(
        at: target,
        to: hardLinkRoot.appendingPathComponent(".control.lock")
    )
    #expect(throws: RunControlStoreError.unsafeControlFile) {
        _ = try RunControlStore(rootURL: hardLinkRoot)
    }
    let attributesAfterHardLink = try FileManager.default.attributesOfItem(atPath: target.path)
    #expect(attributesAfterHardLink[.posixPermissions] as? NSNumber == NSNumber(value: 0o644))
}

@Test("Rejected progress cannot corrupt another active request")
func rejectedProgressIsNonDestructive() async throws {
    let root = try controlRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try RunControlStore(rootURL: root)
    let request = try DailyDiskRunRequest(createdAt: Date(timeIntervalSince1970: 10))
    try await store.enqueue(request)
    _ = try await store.claimPendingRequest()
    let valid = try await publishPhases(
        [.preparing], store: store, request: request, mode: .incremental
    )
    let rejected = try ScanProgressSnapshot(
        requestID: UUID(),
        trigger: .scheduled,
        mode: .scheduledFull,
        phase: .notifying,
        startedAt: valid.startedAt,
        updatedAt: valid.updatedAt.addingTimeInterval(1)
    )
    await store.publish(rejected)

    #expect(try await store.latestProgress() == valid)
    #expect(await store.channelError() == .requestIDMismatch)
}

@Test("Nested unknown progress fields are rejected")
func nestedUnknownFieldsAreRejected() async throws {
    let root = try controlRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try RunControlStore(rootURL: root)
    let payload = Data(
        #"{"version":1,"requestID":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","trigger":"manual","phase":"queued","startedAt":"2025-01-01T00:00:00Z","updatedAt":"2025-01-01T00:00:00Z","counters":{"visitedPaths":0,"path":"/Users/private"}}"#
            .utf8
    )
    let progressURL = root.appendingPathComponent("progress.json")
    try payload.write(to: progressURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: progressURL.path)

    await #expect(throws: RunControlStoreError.unexpectedJSONShape) {
        _ = try await store.latestProgress()
    }
}

@Test("The filesystem lock serializes a separate process")
func crossProcessLocking() async throws {
    let root = try controlRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try RunControlStore(rootURL: root)
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    process.arguments = [
        "-MFcntl=:flock",
        "-e",
        #"$|=1; open(my $f, ">>", $ARGV[0]) or die $!; flock($f, LOCK_EX) or die $!; print "ready\n"; sleep 1;"#,
        root.appendingPathComponent(".control.lock").path,
    ]
    process.standardOutput = output
    try process.run()
    let ready = output.fileHandleForReading.readData(ofLength: 6)
    #expect(String(decoding: ready, as: UTF8.self) == "ready\n")

    let started = Date()
    try await store.enqueue(DailyDiskRunRequest())
    let elapsed = Date().timeIntervalSince(started)
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(elapsed >= 0.5)
}

@Test("Concurrent enqueue across store instances produces one pending request")
func concurrentEnqueueIsSerialized() async throws {
    let root = try controlRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let first = try RunControlStore(rootURL: root)
    let second = try RunControlStore(rootURL: root)
    let requests = [try DailyDiskRunRequest(), try DailyDiskRunRequest()]

    let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
        group.addTask { (try? await first.enqueue(requests[0])) != nil }
        group.addTask { (try? await second.enqueue(requests[1])) != nil }
        var count = 0
        for await value in group where value { count += 1 }
        return count
    }
    #expect(successes == 1)
}

@Test("Completion resumes idempotently after a persisted summary")
func completionRecovery() async throws {
    let root = try controlRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try RunControlStore(rootURL: root)
    let request = try DailyDiskRunRequest(createdAt: Date(timeIntervalSince1970: 10))
    try await store.enqueue(request)
    _ = try await store.claimPendingRequest()
    _ = try await publishPhases(
        [
            .preparing, .discoveringStorage, .replayingEvents,
            .catchingUpEvents, .sealingInventory, .collectingDiagnostics,
            .committing, .publishingReport,
        ],
        store: store,
        request: request,
        mode: .incremental
    )
    let summary = try DailyDiskRunSummary(
        requestID: request.requestID,
        trigger: .manual,
        terminalState: .succeeded,
        startedAt: request.createdAt,
        finishedAt: request.createdAt.addingTimeInterval(20),
        completedDomainCount: 1,
        failedDomainCount: 0,
        reportRunIDs: [UUID()]
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let summaryURL = root.appendingPathComponent("summary.json")
    try encoder.encode(summary).write(to: summaryURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: summaryURL.path)
    try await store.clearExpiredState(
        now: Date(timeIntervalSince1970: 1_000),
        maximumAge: 10,
        writerIsActive: true
    )
    #expect(try await store.activeRequest() == request)

    // Simulate a crash after summary persistence and active-state removal.
    try FileManager.default.removeItem(at: root.appendingPathComponent("active-request.json"))
    try await store.complete(summary)
    try await store.complete(summary)
    #expect(try await store.activeRequest() == nil)
    #expect(try await store.latestProgress()?.phase == .completed)
}

@Test("Cleanup preserves stale-looking state while its writer is active")
func activeWriterPreventsCleanup() async throws {
    let root = try controlRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try RunControlStore(rootURL: root)
    let request = try DailyDiskRunRequest(createdAt: Date(timeIntervalSince1970: 1))
    try await store.enqueue(request)
    _ = try await store.claimPendingRequest()
    try await store.clearExpiredState(
        now: Date(timeIntervalSince1970: 1_000),
        maximumAge: 10,
        writerIsActive: true
    )
    #expect(try await store.activeRequest() == request)
}

@Test("Expired active and terminal state can be cleaned safely")
func expiredStateCleanup() async throws {
    let root = try controlRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try RunControlStore(rootURL: root)
    let request = try DailyDiskRunRequest(createdAt: Date(timeIntervalSince1970: 1))
    try await store.enqueue(request)
    _ = try await store.claimPendingRequest()
    try await store.clearExpiredState(
        now: Date(timeIntervalSince1970: 1_000),
        maximumAge: 10,
        writerIsActive: false
    )
    #expect(try await store.activeRequest() == nil)
}

@Test("Fractional worker timestamps survive progress JSON round trips and allow atomic commit")
func fractionalProgressClock() async throws {
    let root = try controlRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let control = try RunControlStore(rootURL: root)
    let request = try DailyDiskRunRequest(createdAt: Date(timeIntervalSince1970: 1_790_000_000.375))
    try await control.enqueue(request)
    _ = try await control.claimPendingRequest()
    let tracker = try ScanProgressTracker(
        context: ScanProgressContext(requestID: request.requestID, trigger: .manual, startedAt: request.createdAt),
        reporter: control, cancellationChecker: control, commitBoundary: control,
        publicationInterval: 0
    )
    for phase in [
        ScanProgressPhase.preparing, .discoveringStorage, .replayingEvents, .catchingUpEvents,
        .sealingInventory, .collectingDiagnostics, .committing, .publishingReport,
    ] {
        try await tracker.transition(to: phase, mode: .incremental)
        #expect(await control.channelError() == nil)
        #expect(try await control.latestProgress()?.phase == phase)
    }
    let summary = try DailyDiskRunSummary(
        requestID: request.requestID, trigger: .manual, terminalState: .succeeded,
        startedAt: request.createdAt, finishedAt: Date(), completedDomainCount: 1,
        failedDomainCount: 0, reportRunIDs: []
    )
    try await control.complete(summary)
    #expect(try await control.activeRequest() == nil)
    #expect(try await control.latestProgress()?.phase == .completed)
}
