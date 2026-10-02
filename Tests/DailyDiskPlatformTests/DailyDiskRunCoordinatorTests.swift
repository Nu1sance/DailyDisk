import DailyDiskCore
import DailyDiskPlatform
import DailyDiskStore
import Darwin
import Foundation
import Testing

private struct CoordinatorLatestReportReader: LatestReportReading {
    let date: Date?
    let databaseURL: URL

    func latestSuccessfulFullReportDate(
        for storageDomainID: StorageDomain.ID
    ) async throws -> Date? {
        if let date { return date }
        return try await SQLiteReportStore(databaseURL: databaseURL).latestSuccessfulFullReportDate(
            for: storageDomainID)
    }
}

private struct CoordinatorDiscovery: VolumeDiscovering {
    let topology: VolumeTopology
    func discoverInternalAPFSVolumes() async throws -> VolumeTopology { topology }
}

private actor CoordinatorEventReader: EventHistoryReading {
    private let volumeID: MonitoredVolume.ID
    private let eventStoreUUID: UUID
    private var nextEventID: UInt64 = 1

    init(volumeID: MonitoredVolume.ID, eventStoreUUID: UUID) {
        self.volumeID = volumeID
        self.eventStoreUUID = eventStoreUUID
    }

    func openSession(
        volume: MonitoredVolume,
        checkpoint: EventStreamCheckpoint?
    ) async throws -> any EventHistorySession {
        let start = max(checkpoint?.lastEventID ?? 0, nextEventID)
        nextEventID = start + 1
        return CoordinatorEventSession(
            history: EventCursorFence(
                volumeID: volumeID,
                eventStoreUUID: eventStoreUUID,
                highestFullyDeliveredEventID: start,
                phase: .historyDone,
                trust: .trusted
            ),
            live: EventCursorFence(
                volumeID: volumeID,
                eventStoreUUID: eventStoreUUID,
                highestFullyDeliveredEventID: start,
                phase: .liveFlush,
                trust: .trusted
            )
        )
    }
}

private actor CoordinatorEventSession: EventHistorySession {
    let history: EventCursorFence
    let live: EventCursorFence

    init(history: EventCursorFence, live: EventCursorFence) {
        self.history = history
        self.live = live
    }

    func replayHistoricalEvents(
        consume: @escaping @Sendable (EventBatch) async throws -> Void
    ) async throws -> EventCursorFence { history }

    func flushLiveEvents(
        consume: @escaping @Sendable (EventBatch) async throws -> Void
    ) async throws -> EventCursorFence { live }

    func stop() async {}
}

private struct CoordinatorDiskSampler: DiskUsageSampling {
    let domainID: StorageDomain.ID

    func sample(storageDomain: StorageDomain) async throws -> StorageSample {
        try StorageSample(
            storageDomainID: domainID,
            sampledAt: Date(),
            capacityBytes: 1_000_000,
            usedBytes: 100,
            availableBytes: 999_900
        )
    }

    func snapshots(volume: MonitoredVolume) async throws -> [SnapshotSample] { [] }
}

private struct CoordinatorMetadataReader: FileMetadataReading {
    func read(volume: MonitoredVolume, path: RelativePath) async throws -> FileMetadataReadResult {
        .missing
    }
}

private struct CoordinatorDeletedProbe: DeletedOpenFileProbing {
    func deletedOpenFiles() async throws -> [DeletedOpenFile] { [] }
}

private struct FailingCoordinatorReportWriter: ReportWriting {
    func existingReport(runID: ScanRun.ID) async throws -> DailyReport? { nil }
    func write(report: DailyReport) async throws -> ReportArtifacts {
        throw CoordinatorTestError.report
    }
}

private actor CoordinatorReportWriter: ReportWriting {
    func existingReport(runID: ScanRun.ID) async throws -> DailyReport? { nil }

    func write(report: DailyReport) async throws -> ReportArtifacts {
        let root = FileManager.default.temporaryDirectory
        return ReportArtifacts(
            jsonURL: root.appendingPathComponent("\(report.runID).json"),
            markdownURL: root.appendingPathComponent("\(report.runID).md")
        )
    }
}

private actor CoordinatorErrorProbe {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

private actor CoordinatorNotificationProbe {
    private(set) var count = 0
    func record() { count += 1 }
}

private struct CoordinatorFixture {
    let root: URL
    let databaseURL: URL
    let domain: StorageDomain
    let volume: MonitoredVolume
    let topology: VolumeTopology
    let store: SQLiteInventoryStore

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyDiskCoordinatorTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: root.appendingPathComponent("payload"))
        databaseURL = root.appendingPathComponent("private/DailyDisk.sqlite")
        domain = StorageDomain(
            id: StorageDomain.ID("coordinator-domain"),
            containerIdentifier: "disk-test",
            displayName: "Coordinator Domain",
            isInternal: true
        )
        var status = Darwin.stat()
        #expect(lstat(root.path, &status) == 0)
        let eventStoreUUID = UUID()
        volume = MonitoredVolume(
            id: MonitoredVolume.ID("coordinator-volume"),
            storageDomainID: domain.id,
            filesystemUUID: UUID(),
            eventStoreUUID: eventStoreUUID,
            deviceID: UInt64(UInt32(bitPattern: status.st_dev)),
            mountPath: root.path,
            displayName: "Data",
            role: .data,
            isInternal: true,
            isRemovable: false,
            isReadOnly: false,
            supportsPersistentEvents: true,
            topologyFingerprint: "coordinator-topology",
            inventoryMode: .full
        )
        topology = VolumeTopology(
            domains: [domain],
            volumes: [volume],
            discoveredAt: Date()
        )
        store = try SQLiteInventoryStore(databaseURL: databaseURL)
        try await store.prepare()
    }

    func makeCoordinator(
        latestReportDate: Date?,
        notificationProbe: CoordinatorNotificationProbe,
        reportWriter: any ReportWriting = CoordinatorReportWriter(),
        retentionHandler: DailyDiskRunCoordinator.RetentionHandler? = nil,
        errorProbe: CoordinatorErrorProbe? = nil,
        progressFactory: @escaping DailyDiskRunCoordinator.ProgressFactory = { _, _, _, _ in NoopScanProgressTracker()
        },
        eventReader: (any EventHistoryReading)? = nil,
        policy: ScanPolicy = .default
    ) throws -> DailyDiskRunCoordinator {
        let discovery = CoordinatorDiscovery(topology: topology)
        return DailyDiskRunCoordinator(
            store: store,
            reportReader: CoordinatorLatestReportReader(date: latestReportDate, databaseURL: databaseURL),
            discovery: discovery,
            eventReader: eventReader
                ?? CoordinatorEventReader(
                    volumeID: volume.id,
                    eventStoreUUID: volume.eventStoreUUID!
                ),
            metadataReader: CoordinatorMetadataReader(),
            fileScanner: FileInventoryScanner(
                configuration: try FileInventoryScannerConfiguration(
                    managedAbsolutePaths: [databaseURL.deletingLastPathComponent().path],
                    validateMountIdentity: false
                )
            ),
            diskUsageSampler: CoordinatorDiskSampler(domainID: domain.id),
            reportCoordinator: DailyReportCoordinator(
                store: store,
                diagnosticsCoordinator: PhysicalDiagnosticsCoordinator(
                    deletedOpenFileProbe: CoordinatorDeletedProbe()
                ),
                reportWriter: reportWriter
            ),
            scanPolicy: policy,
            progressFactory: progressFactory,
            scheduledReportHandler: { _ in await notificationProbe.record() },
            retentionHandler: retentionHandler,
            errorHandler: { event, _ in await errorProbe?.record(event) }
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum CoordinatorTestError: Error {
    case retention
    case report
}

private actor InterruptedCommitProgressProbe: ScanProgressReporting {
    private(set) var phases: [ScanProgressPhase] = []
    func publish(_ snapshot: ScanProgressSnapshot) { phases.append(snapshot.phase) }
}

@Test("Restart before SQLite commit shows cleanup before resuming inventory work")
func uncommittedManualResumeCleansUpBeforeRescan() async throws {
    let fixture = try await CoordinatorFixture()
    defer { fixture.remove() }
    try await fixture.store.register(scope: StorageDomainScope(domain: fixture.domain, volumes: [fixture.volume]))
    let run = ScanRun(kind: .full, reason: .manual, status: .running, startedAt: Date())
    try await fixture.store.begin(run: run)
    _ = try await fixture.store.createStagingGeneration(
        volumeID: fixture.volume.id, runID: run.id, at: run.startedAt
    )
    let requestID = UUID()
    let snapshot = try ScanProgressSnapshot(
        requestID: requestID, trigger: .manual, mode: .initialFull,
        phase: .committing, startedAt: run.startedAt, updatedAt: run.startedAt
    )
    let probe = InterruptedCommitProgressProbe()
    let notifications = CoordinatorNotificationProbe()
    let recovery = try fixture.makeCoordinator(
        latestReportDate: nil, notificationProbe: notifications,
        progressFactory: { _, _, _, _ in
            try ScanProgressTracker(
                resuming: snapshot, reporter: probe, cancellationChecker: TaskScanCancellationChecker()
            )
        }
    )
    let summary = await recovery.run(
        mode: .manual(requestID: requestID, requestedMode: .automatic, resumeCommittedRunID: run.id),
        startedAt: run.startedAt
    )
    #expect(summary.terminalState == .succeeded)
    let phases = await probe.phases
    #expect(Array(phases.prefix(3)) == [.cleaningUpFailedRun, .preparing, .discoveringStorage])
    #expect(phases.last == .completed)
    #expect(!ScanProgressPhase.cleaningUpFailedRun.allowsCancellation)
    #expect(!ScanProgressTransitionValidator.canTransition(from: .committing, to: .cancelling))
    let reader = try SQLiteReportStore(databaseURL: fixture.databaseURL)
    let interrupted = try await reader.recentRuns()
    #expect(interrupted.count == 2)
    #expect(interrupted.contains { $0.id == run.id && $0.status == .interrupted })
    #expect(interrupted.contains { $0.status == .succeeded })
    #expect(try await fixture.store.state(for: fixture.volume.id) != nil)
}

@Test("Committed manual report recovery satisfies the same request without a second scan")
func committedManualResumeDoesNotRescan() async throws {
    let fixture = try await CoordinatorFixture()
    defer { fixture.remove() }
    let notifications = CoordinatorNotificationProbe()
    let failing = try fixture.makeCoordinator(
        latestReportDate: nil,
        notificationProbe: notifications,
        reportWriter: FailingCoordinatorReportWriter()
    )
    let first = await failing.run(
        mode: .manual(requestID: UUID(), requestedMode: .fullReconciliation)
    )
    #expect(first.terminalState == .failed)
    let reader = try SQLiteReportStore(databaseURL: fixture.databaseURL)
    let committedRun = try #require(try await reader.recentRuns().first)
    #expect(committedRun.status == .succeeded)
    #expect(try await reader.latestSuccessfulFullReportDate(for: fixture.domain.id) == nil)
    #expect(try await fixture.store.latestUnreportedBasis(storageDomainID: fixture.domain.id) != nil)

    let recovering = try fixture.makeCoordinator(
        latestReportDate: nil,
        notificationProbe: notifications
    )
    let resumed = await recovering.run(
        mode: .manual(
            requestID: UUID(),
            requestedMode: .fullReconciliation,
            resumeCommittedRunID: committedRun.id
        )
    )
    #expect(resumed.terminalState == .succeeded)
    #expect(resumed.reportRunIDs == [committedRun.id.rawValue])
    #expect(try await reader.recentRuns().count == 1)
}

@Test("A due scheduled run scans and notifies")
func scheduledRunNotifies() async throws {
    let fixture = try await CoordinatorFixture()
    defer { fixture.remove() }
    let notifications = CoordinatorNotificationProbe()
    let coordinator = try fixture.makeCoordinator(
        latestReportDate: nil,
        notificationProbe: notifications
    )

    let summary = await coordinator.run(mode: .scheduled)
    #expect(summary.terminalState == .succeeded)
    #expect(summary.completedDomainCount == 1)
    #expect(await notifications.count == 1)
}

@Test("Retention failure preserves successful report accounting and emits diagnostics")
func retentionFailurePreservesSummary() async throws {
    let fixture = try await CoordinatorFixture()
    defer { fixture.remove() }
    let notifications = CoordinatorNotificationProbe()
    let errors = CoordinatorErrorProbe()
    let coordinator = try fixture.makeCoordinator(
        latestReportDate: nil,
        notificationProbe: notifications,
        retentionHandler: { throw CoordinatorTestError.retention },
        errorProbe: errors
    )

    let summary = await coordinator.run(mode: .manual(requestID: UUID(), requestedMode: .automatic))
    #expect(summary.terminalState == .failed)
    #expect(summary.completedDomainCount == 1)
    #expect(summary.failedDomainCount == 1)
    #expect(summary.reportRunIDs.count == 1)
    #expect(await errors.events == ["retention-failed"])
}

@Test("Scheduled execution skips a same-day report while manual execution bypasses due gate")
func manualBypassesDueGate() async throws {
    let fixture = try await CoordinatorFixture()
    defer { fixture.remove() }
    let notifications = CoordinatorNotificationProbe()
    let coordinator = try fixture.makeCoordinator(
        latestReportDate: Date(),
        notificationProbe: notifications
    )

    let scheduled = await coordinator.run(mode: .scheduled)
    #expect(scheduled.terminalState == .skippedNotDue)
    #expect(scheduled.completedDomainCount == 0)

    let requestID = UUID()
    let manual = await coordinator.run(mode: .manual(requestID: requestID, requestedMode: .automatic))
    #expect(manual.requestID == requestID)
    #expect(manual.terminalState == .succeeded)
    #expect(manual.completedDomainCount == 1)
    #expect(manual.reportRunIDs.count == 1)
    #expect(await notifications.count == 0)

    let forced = await coordinator.run(
        mode: .manual(
            requestID: UUID(),
            requestedMode: .fullReconciliation
        )
    )
    #expect(forced.terminalState == .succeeded)

    let reader = try SQLiteReportStore(databaseURL: fixture.databaseURL)
    let run = try #require(try await reader.recentRuns().first)
    #expect(run.reason == .manual)
    #expect(run.kind == .full)
    #expect(run.status == .succeeded)
}

@Test("Scheduled work persists progress and terminal state through the same control channel", arguments: [false, true])
func scheduledControlLifecycle(notDue: Bool) async throws {
    let fixture = try await CoordinatorFixture()
    defer { fixture.remove() }
    let control = try RunControlStore(
        rootURL: fixture.databaseURL.deletingLastPathComponent().appendingPathComponent("Control"))
    let request = try DailyDiskRunRequest()
    try await control.beginScheduledRun(request)
    #expect(try await control.latestProgress()?.trigger == .scheduled)
    #expect(try await control.activeRequest()?.requestID == request.requestID)
    let coordinator = try fixture.makeCoordinator(
        latestReportDate: notDue ? Date() : nil,
        notificationProbe: CoordinatorNotificationProbe(),
        progressFactory: { id, trigger, start, _ in
            try ScanProgressTracker(
                context: ScanProgressContext(requestID: id, trigger: trigger, startedAt: start),
                reporter: control, cancellationChecker: control,
                commitBoundary: control, runBindingRecorder: control
            )
        }
    )
    let summary = await coordinator.run(mode: .scheduled, startedAt: request.createdAt, requestID: request.requestID)
    #expect(summary.terminalState == (notDue ? .skippedNotDue : .succeeded))
    try await control.complete(summary)
    #expect(await control.channelError() == nil)
    #expect(try await control.activeRequest() == nil)
    #expect(try await control.latestSummary()?.requestID == request.requestID)
    #expect(try await control.latestProgress()?.phase == .completed)
    if !notDue {
        #expect(try await control.latestProgress()!.counters.visitedPaths > 0)
    }
}

@Test("Scheduled cancellation before preparation is terminal and never creates a scan")
func scheduledPreflightCancellation() async throws {
    let fixture = try await CoordinatorFixture()
    defer { fixture.remove() }
    let control = try RunControlStore(
        rootURL: fixture.databaseURL.deletingLastPathComponent().appendingPathComponent("Control"))
    let request = try DailyDiskRunRequest()
    try await control.beginScheduledRun(request)
    try await control.requestCancellation(DailyDiskCancelRequest(requestID: request.requestID))
    let coordinator = try fixture.makeCoordinator(
        latestReportDate: nil, notificationProbe: CoordinatorNotificationProbe(),
        progressFactory: { id, trigger, start, _ in
            try ScanProgressTracker(
                context: ScanProgressContext(requestID: id, trigger: trigger, startedAt: start),
                reporter: control, cancellationChecker: control, commitBoundary: control
            )
        }
    )
    let summary = await coordinator.run(mode: .scheduled, startedAt: request.createdAt, requestID: request.requestID)
    #expect(summary.terminalState == .cancelled)
    try await control.complete(summary)
    #expect(try await control.latestProgress()?.phase == .cancelled)
    let reader = try SQLiteReportStore(databaseURL: fixture.databaseURL)
    #expect(try await reader.recentRuns().isEmpty)
}

@Test("A restarted scheduled run publishes its committed report without scanning again")
func scheduledPublicationRecoveryWithControl() async throws {
    let fixture = try await CoordinatorFixture()
    defer { fixture.remove() }
    let notifications = CoordinatorNotificationProbe()
    let first = try fixture.makeCoordinator(
        latestReportDate: nil, notificationProbe: notifications, reportWriter: FailingCoordinatorReportWriter()
    )
    _ = await first.run(mode: .scheduled)
    let reader = try SQLiteReportStore(databaseURL: fixture.databaseURL)
    let run = try #require(try await reader.recentRuns().first)
    #expect(run.status == .succeeded)
    let control = try RunControlStore(
        rootURL: fixture.databaseURL.deletingLastPathComponent().appendingPathComponent("Control"))
    let request = try DailyDiskRunRequest()
    try await control.beginScheduledRun(request)
    let recovery = try fixture.makeCoordinator(
        latestReportDate: Date(), notificationProbe: notifications,
        progressFactory: { id, trigger, start, _ in
            try ScanProgressTracker(
                context: ScanProgressContext(requestID: id, trigger: trigger, startedAt: start),
                reporter: control, cancellationChecker: control, commitBoundary: control
            )
        }
    )
    let summary = await recovery.run(mode: .scheduled, startedAt: request.createdAt, requestID: request.requestID)
    #expect(summary.terminalState == .succeeded)
    #expect(summary.reportRunIDs == [run.id.rawValue])
    try await control.complete(summary)
    #expect(await control.channelError() == nil)
    #expect(try await reader.recentRuns().count == 1)
}

@Test(
    "Coordinator probes distinguish initial, incremental and forced full with committed basis",
    arguments: [false, true])
func coordinatorProbeDecisions(enabled: Bool) async throws {
    let fixture = try await CoordinatorFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let sink = ProbeCollector()
    let context = ScanProbeContext(recorder: enabled ? sink : nil)
    let coordinator = try fixture.makeCoordinator(
        latestReportDate: nil, notificationProbe: CoordinatorNotificationProbe())
    for mode in [DailyDiskRequestedScanMode.automatic, .automatic, .fullReconciliation] {
        let summary = await ScanProbe.$context.withValue(context) {
            await coordinator.run(mode: .manual(requestID: UUID(), requestedMode: mode))
        }
        #expect(summary.terminalState == .succeeded)
    }
    if enabled {
        let events = sink.events
        #expect(
            events.filter { $0.name == .policyDecision }.map { $0.fields["selection"] } == [
                "initialFull", "incremental", "forcedFull",
            ])
        #expect(events.filter { $0.name == .commitSucceeded }.count == 3)
        #expect(events.filter { $0.name == .commitProposed }.count == 3)
        #expect(Set(events.compactMap(\.attemptID)).count == 3)
        #expect(Set(events.compactMap(\.requestID)).count == 3)
        #expect(events.filter { $0.name == .requestFinished }.allSatisfy { $0.fields["terminalState"] == "succeeded" })
        let state = try await fixture.store.state(for: fixture.volume.id)
        #expect(
            events.last { $0.name == .commitSucceeded }?.fields["cursor"]
                == state?.checkpoint.lastCommittedEventID.map { String($0) })
    } else {
        #expect(sink.events.isEmpty)
    }
}

private actor ProbeRejectingReader: EventHistoryReading {
    let normal: CoordinatorEventReader
    var rejected = false
    let fastFailure: Bool
    let fastSession = FastFailureSession()
    init(volume: MonitoredVolume, fastFailure: Bool = false) {
        self.fastFailure = fastFailure
        normal = CoordinatorEventReader(volumeID: volume.id, eventStoreUUID: volume.eventStoreUUID!)
    }
    func openSession(volume: MonitoredVolume, checkpoint: EventStreamCheckpoint?) async throws
        -> any EventHistorySession
    {
        if !rejected {
            rejected = true
            if fastFailure { return fastSession }
            _ = EventTrustEvaluator.assessJournal(
                expectedUUID: checkpoint?.eventStoreUUID,
                observedUUID: UUID(), previousEventID: checkpoint?.lastEventID, observedEventID: checkpoint?.lastEventID
            )
            let fence = EventCursorFence(
                volumeID: volume.id, eventStoreUUID: UUID(),
                highestFullyDeliveredEventID: checkpoint?.lastEventID, phase: .historyDone,
                trust: .fullScanRequired, diagnostic: "synthetic replacement")
            return CoordinatorEventSession(history: fence, live: fence)
        }
        return try await normal.openSession(volume: volume, checkpoint: checkpoint)
    }
}

@Test("Probe recovery keeps typed first cause, failed attempt and pre-recovery checkpoint", arguments: [false, true])
func coordinatorProbeRecovery(fastFailure: Bool) async throws {
    let fixture = try await CoordinatorFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let notifications = CoordinatorNotificationProbe()
    let initial = try fixture.makeCoordinator(latestReportDate: nil, notificationProbe: notifications)
    _ = await initial.run(mode: .manual(requestID: UUID(), requestedMode: .automatic))
    let before = try #require(try await fixture.store.state(for: fixture.volume.id))
    let sink = ProbeCollector()
    let request = UUID()
    let reader = ProbeRejectingReader(volume: fixture.volume, fastFailure: fastFailure)
    let recovery = try fixture.makeCoordinator(
        latestReportDate: nil, notificationProbe: notifications,
        eventReader: reader)
    let result = await ScanProbe.$context.withValue(ScanProbeContext(recorder: sink)) {
        await recovery.run(mode: .manual(requestID: request, requestedMode: .automatic))
    }
    #expect(result.terminalState == .succeeded)
    let events = sink.events
    if fastFailure { #expect(await reader.fastSession.stopped) }
    let reason: ScanProbeReasonCode = fastFailure ? .mailboxOverflow : .journalUUIDChanged
    let rejected = try #require(events.first { $0.reason == reason })
    let decision = try #require(events.first { $0.name == .recoverySelected })
    #expect(decision.fields["firstReason"] == reason.rawValue)
    #expect(decision.attemptID == rejected.attemptID && decision.runID == rejected.runID)
    let attempts = events.filter { $0.name == .attemptStarted }
    #expect(attempts.count == 2 && attempts[0].attemptID != attempts[1].attemptID)
    #expect(events.filter { $0.name == .commitSucceeded }.count == 1)
    #expect(events.first { $0.name == .attemptFailed }?.attemptID == rejected.attemptID)
    let recoveryBasis = try #require(
        events.first { $0.name == .checkpointRead && $0.attemptID == attempts[1].attemptID })
    #expect(recoveryBasis.fields["cursor"] == before.checkpoint.lastCommittedEventID.map { String($0) })
    #expect(recoveryBasis.fields["generation"] == before.checkpoint.activeGenerationID.rawValue.uuidString)
    #expect(events.allSatisfy { $0.requestID == request })
    let periodic = try fixture.makeCoordinator(
        latestReportDate: nil, notificationProbe: notifications,
        policy: ScanPolicy())
    _ = await ScanProbe.$context.withValue(ScanProbeContext(recorder: sink)) {
        await periodic.run(mode: .manual(requestID: UUID(), requestedMode: .fullReconciliation))
    }
    #expect(sink.events.last { $0.name == .policyDecision }?.fields["selection"] == "forcedFull")
}

private actor FastFailureSession: EventHistorySession {
    var stopped = false
    func replayHistoricalEvents(consume: @escaping @Sendable (EventBatch) async throws -> Void) async throws
        -> EventCursorFence
    {
        ScanProbe.emit(.rejection, reason: .mailboxOverflow)
        throw EventReplayInvalidated(reasons: ["DailyDisk FSEvents buffer overflowed"])
    }
    func flushLiveEvents(consume: @escaping @Sendable (EventBatch) async throws -> Void) async throws
        -> EventCursorFence
    {
        Issue.record("Invalidated history must not flush")
        throw EventReplayInvalidated(reasons: ["unexpected flush"])
    }
    func stop() async { stopped = true }
}

@Test("Published full survives later incremental and failed full attempts for automatic deduplication")
func dailyFullSuccessIsNotErased() async throws {
    let fixture = try await CoordinatorFixture()
    defer { fixture.remove() }
    let notifications = CoordinatorNotificationProbe()
    let coordinator = try fixture.makeCoordinator(latestReportDate: nil, notificationProbe: notifications)
    let full = await coordinator.run(mode: .manual(requestID: UUID(), requestedMode: .automatic))
    #expect(full.terminalState == .succeeded)
    let reader = try SQLiteReportStore(databaseURL: fixture.databaseURL)
    let published = try #require(try await reader.latestSuccessfulFullReportDate(for: fixture.domain.id))
    #expect(await coordinator.run(mode: .scheduled).terminalState == .skippedNotDue)
    let incremental = await coordinator.run(mode: .manual(requestID: UUID(), requestedMode: .automatic))
    #expect(incremental.terminalState == .succeeded)
    #expect(try await reader.recentRuns().first?.kind == .incremental)
    let failed = ScanRun(kind: .full, reason: .manual, status: .running, startedAt: Date())
    try await fixture.store.begin(run: failed)
    try await fixture.store.fail(runID: failed.id, errors: [], finishedAt: Date())
    #expect(try await reader.latestSuccessfulFullReportDate(for: fixture.domain.id) == published)
    #expect(await coordinator.run(mode: .scheduled).terminalState == .skippedNotDue)
}

@Test("Recovering an incremental report can continue into a due full with real Control mode transitions")
func recoveredIncrementalThenDailyFull() async throws {
    let fixture = try await CoordinatorFixture()
    defer { fixture.remove() }
    let notifications = CoordinatorNotificationProbe()
    let first = try fixture.makeCoordinator(latestReportDate: nil, notificationProbe: notifications)
    #expect(await first.run(mode: .manual(requestID: UUID(), requestedMode: .automatic)).terminalState == .succeeded)
    let failing = try fixture.makeCoordinator(
        latestReportDate: nil, notificationProbe: notifications,
        reportWriter: FailingCoordinatorReportWriter())
    #expect(await failing.run(mode: .manual(requestID: UUID(), requestedMode: .automatic)).terminalState == .failed)
    let control = try RunControlStore(rootURL: fixture.root.appendingPathComponent("Control"))
    let request = try DailyDiskRunRequest()
    try await control.beginScheduledRun(request)
    let priorTracker = try ScanProgressTracker(
        context: ScanProgressContext(
            requestID: request.requestID, trigger: .scheduled, startedAt: request.createdAt),
        reporter: control, cancellationChecker: control, commitBoundary: control, runBindingRecorder: control)
    try await priorTracker.transition(to: .preparing, mode: .incremental)
    try await priorTracker.transition(to: .discoveringStorage, mode: nil)
    try await priorTracker.transition(to: .publishingReport, mode: nil)
    let saved = try #require(try await control.latestProgress())
    // The older published full is yesterday for this synthetic due gate.
    let coordinator = try fixture.makeCoordinator(
        latestReportDate: Date().addingTimeInterval(-172800),
        notificationProbe: notifications,
        progressFactory: { _, _, _, _ in
            try ScanProgressTracker(
                resuming: saved, reporter: control, cancellationChecker: control,
                commitBoundary: control, runBindingRecorder: control)
        })
    let result = await coordinator.run(mode: .scheduled, startedAt: request.createdAt, requestID: request.requestID)
    #expect(result.terminalState == .succeeded)
    #expect(try await control.latestProgress()?.mode == .scheduledFull)
    #expect(await control.channelError() == nil)
    let reader = try SQLiteReportStore(databaseURL: fixture.databaseURL)
    #expect(try await reader.recentRuns().count == 3)
    #expect(try await fixture.store.latestUnreportedBasis(storageDomainID: fixture.domain.id) == nil)
}
