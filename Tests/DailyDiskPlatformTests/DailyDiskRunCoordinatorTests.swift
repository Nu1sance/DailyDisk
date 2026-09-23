import DailyDiskCore
import DailyDiskPlatform
import DailyDiskStore
import Darwin
import Foundation
import Testing

private struct CoordinatorLatestReportReader: LatestReportReading {
    let date: Date?

    func latestSuccessfulReportDate(
        for storageDomainID: StorageDomain.ID
    ) async throws -> Date? {
        date
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
            deviceID: UInt64(status.st_dev),
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
        progressFactory: @escaping DailyDiskRunCoordinator.ProgressFactory = { _, _, _, _ in NoopScanProgressTracker() }
    ) throws -> DailyDiskRunCoordinator {
        let discovery = CoordinatorDiscovery(topology: topology)
        return DailyDiskRunCoordinator(
            store: store,
            reportReader: CoordinatorLatestReportReader(date: latestReportDate),
            discovery: discovery,
            eventReader: CoordinatorEventReader(
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
