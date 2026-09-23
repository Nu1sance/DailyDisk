import DailyDiskCore
import Foundation
import Testing

@testable import DailyDiskStore

private actor CancellingStoreObserver: ScanWorkObserving {
    private let limit: Int
    private(set) var count = 0

    init(limit: Int) {
        self.limit = limit
    }

    func checkpoint(_ delta: ScanProgressDelta) async throws {
        count += 1
        if count >= limit { throw CancellationError() }
    }
}

@Test("A checkpoint failure rolls back inventory, ledger, and run status together")
func checkpointFailureRollsBackWholeCommit() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let baseline = try await establishBaseline(in: fixture)

    let run = ScanRun(
        kind: .incremental,
        reason: .dailySchedule,
        status: .running,
        startedAt: Date(timeIntervalSince1970: 30)
    )
    try await fixture.store.begin(run: run)
    let modified = try fixture.record(
        path: "Users/alice/file.dat",
        inode: 1,
        logicalBytes: 500,
        allocatedBytes: 512
    )
    let target = InventoryMutationTarget.expectedActive(volumeID: fixture.volume.id)
    try await fixture.store.stage(mutations: [.upsert(modified)], target: target, for: run.id)
    try await fixture.store.finalizeCanonicalAttribution(target: target, runID: run.id, consume: { _ in })

    let change = try ChangeRecord(
        runID: run.id,
        volumeID: fixture.volume.id,
        objectIdentity: modified.object.identity,
        kind: .eventModified,
        pathBefore: modified.path.relativePath,
        pathAfter: modified.path.relativePath,
        effect: .objectTransition(
            before: baseline.records[0].object.footprint,
            after: modified.object.footprint
        )
    )
    let checkpoint = Checkpoint(
        volumeID: fixture.volume.id,
        eventStoreUUID: fixture.volume.eventStoreUUID,
        lastCommittedEventID: 20,
        activeGenerationID: baseline.generation.id,
        topologyFingerprint: fixture.volume.topologyFingerprint,
        lastSuccessfulIncrementalAt: Date(timeIntervalSince1970: 40),
        lastSuccessfulFullScanAt: baseline.checkpoint.lastSuccessfulFullScanAt
    )
    let fence = EventCursorFence(
        volumeID: fixture.volume.id,
        eventStoreUUID: fixture.volume.eventStoreUUID,
        highestFullyDeliveredEventID: 20,
        phase: .liveFlush,
        trust: .trusted
    )
    let commit = try ScanCommit(
        runID: run.id,
        runKind: .incremental,
        scope: fixture.scope,
        volumeID: fixture.volume.id,
        activatedGenerationID: nil,
        previousCheckpoint: baseline.checkpoint,
        checkpoint: checkpoint,
        eventFence: fence,
        changes: [change],
        storageSamples: [fixture.sample(usedBytes: 500_384, at: 40)],
        snapshotSamples: []
    )

    do {
        let faultConnection = try SQLiteDatabase(url: fixture.databaseURL)
        try faultConnection.execute(
            """
            CREATE TRIGGER inject_checkpoint_failure
            BEFORE UPDATE ON checkpoints
            BEGIN
                SELECT RAISE(ABORT, 'injected checkpoint failure');
            END;
            """
        )
    }

    await #expect(throws: (any Error).self) {
        try await fixture.store.commit(commit, finishedAt: Date(timeIntervalSince1970: 40))
    }

    let stateAfterFailure = try #require(try await fixture.store.state(for: fixture.volume.id))
    #expect(stateAfterFailure.checkpoint == baseline.checkpoint)
    let rolledBackDatabase = try SQLiteDatabase(url: fixture.databaseURL)
    #expect(try rolledBackDatabase.scalarInt64("SELECT allocated_bytes FROM inventory_objects") == 128)

    do {
        let inspection = try SQLiteDatabase(url: fixture.databaseURL)
        let ledger = try inspection.prepare("SELECT COUNT(*) FROM change_ledger WHERE run_id = ?")
        try ledger.bind(run.id.rawValue.uuidString, at: 1)
        #expect(try ledger.step())
        #expect(ledger.columnInt64(0) == 0)
        let status = try inspection.prepare("SELECT status FROM scan_runs WHERE id = ?")
        try status.bind(run.id.rawValue.uuidString, at: 1)
        #expect(try status.step())
        #expect(status.columnText(0) == ScanRun.Status.running.rawValue)
        try inspection.execute("DROP TRIGGER inject_checkpoint_failure")
    }

    try await fixture.store.commit(commit, finishedAt: Date(timeIntervalSince1970: 40))
    let finalState = try #require(try await fixture.store.state(for: fixture.volume.id))
    #expect(finalState.checkpoint.lastCommittedEventID == 20)
    let committedDatabase = try SQLiteDatabase(url: fixture.databaseURL)
    #expect(try committedDatabase.scalarInt64("SELECT allocated_bytes FROM inventory_objects") == 512)
}

@Test("Startup recovery interrupts abandoned runs and removes staging state")
func startupRecoveryRemovesAbandonedState() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }

    let run = ScanRun(
        kind: .full,
        reason: .initialBaseline,
        status: .running,
        startedAt: Date(timeIntervalSince1970: 10)
    )
    try await fixture.store.begin(run: run)
    let generation = try await fixture.store.createStagingGeneration(
        volumeID: fixture.volume.id,
        runID: run.id,
        at: run.startedAt
    )
    try await fixture.store.append(
        records: [fixture.record(path: "orphan", inode: 9, logicalBytes: 1, allocatedBytes: 1)],
        to: generation.id
    )

    try await fixture.store.recoverInterruptedRuns(at: Date(timeIntervalSince1970: 20))

    let reader = try SQLiteReportStore(databaseURL: fixture.databaseURL)
    let runs = try await reader.recentRuns()
    #expect(runs.count == 1)
    #expect(runs[0].status == .interrupted)
    #expect(runs[0].finishedAt == Date(timeIntervalSince1970: 20))

    let database = try SQLiteDatabase(url: fixture.databaseURL, readOnly: true)
    #expect(try database.scalarInt64("SELECT COUNT(*) FROM inventory_generations") == 0)
    #expect(try database.scalarInt64("SELECT COUNT(*) FROM inventory_objects") == 0)
}

@Test("Interrupting an incremental run discards overlays and preserves the checkpoint")
func interruptIncrementalRun() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let baseline = try await establishBaseline(in: fixture)
    let run = ScanRun(
        kind: .incremental,
        reason: .manual,
        status: .running,
        startedAt: Date(timeIntervalSince1970: 30)
    )
    try await fixture.store.begin(run: run)
    let target = InventoryMutationTarget.expectedActive(volumeID: fixture.volume.id)
    try await fixture.store.stage(
        mutations: [
            .upsert(
                fixture.record(
                    path: "Users/alice/file.dat",
                    inode: 1,
                    logicalBytes: 900,
                    allocatedBytes: 1_024
                )
            )
        ],
        target: target,
        for: run.id
    )
    try await fixture.store.finalizeCanonicalAttribution(
        target: target,
        runID: run.id,
        consume: { _ in }
    )

    try await fixture.store.interrupt(
        runID: run.id,
        finishedAt: Date(timeIntervalSince1970: 40)
    )
    let state = try #require(try await fixture.store.state(for: fixture.volume.id))
    #expect(state.checkpoint == baseline.checkpoint)
    #expect(state.activeGeneration.id == baseline.generation.id)
    #expect(state.activeGeneration.state == .active)
    #expect(try await fixture.store.activeRuns().isEmpty)

    let reader = try SQLiteReportStore(databaseURL: fixture.databaseURL)
    let interrupted = try #require(try await reader.recentRuns().first { $0.id == run.id })
    #expect(interrupted.status == .interrupted)
    #expect(interrupted.finishedAt == Date(timeIntervalSince1970: 40))
    #expect(interrupted.errorCount == 0)
    let database = try SQLiteDatabase(url: fixture.databaseURL, readOnly: true)
    for table in [
        "run_targets", "run_mutations", "run_object_mutations",
        "run_canonical_attributions",
    ] {
        #expect(
            try database.scalarInt64("SELECT COUNT(*) FROM \(table) WHERE run_id = '\(run.id.rawValue.uuidString)'")
                == 0)
    }
}

@Test("Interrupting a full run removes only its staging generation")
func interruptFullRun() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let baseline = try await establishBaseline(in: fixture)
    let run = ScanRun(
        kind: .full,
        reason: .manual,
        status: .running,
        startedAt: Date(timeIntervalSince1970: 30)
    )
    try await fixture.store.begin(run: run)
    let staging = try await fixture.store.createStagingGeneration(
        volumeID: fixture.volume.id,
        runID: run.id,
        at: run.startedAt
    )
    try await fixture.store.append(
        records: [
            fixture.record(path: "partial", inode: 20, logicalBytes: 50, allocatedBytes: 64)
        ],
        to: staging.id
    )
    try await fixture.store.finalizeCanonicalAttribution(
        target: .stagingGeneration(staging.id),
        runID: run.id,
        consume: { _ in }
    )

    try await fixture.store.interrupt(
        runID: run.id,
        finishedAt: Date(timeIntervalSince1970: 40)
    )
    // Repeating cancellation cleanup is idempotent.
    try await fixture.store.interrupt(
        runID: run.id,
        finishedAt: Date(timeIntervalSince1970: 41)
    )
    let state = try #require(try await fixture.store.state(for: fixture.volume.id))
    #expect(state.checkpoint == baseline.checkpoint)
    #expect(state.activeGeneration.id == baseline.generation.id)
    #expect(state.activeGeneration.state == .active)
    let database = try SQLiteDatabase(url: fixture.databaseURL, readOnly: true)
    #expect(try database.scalarInt64("SELECT COUNT(*) FROM inventory_generations") == 1)
    #expect(
        try database.scalarInt64(
            "SELECT COUNT(*) FROM inventory_generations WHERE id = '\(staging.id.rawValue.uuidString)'"
        ) == 0
    )
    #expect(try database.scalarInt64("SELECT allocated_bytes FROM inventory_objects") == 128)
}

@Test("A cancellation arriving after commit cannot rewrite successful state")
func interruptAfterCommitIsRejected() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let baseline = try await establishBaseline(in: fixture)

    await #expect(throws: StoreInvariantError.invalidRunState) {
        try await fixture.store.interrupt(
            runID: baseline.run.id,
            finishedAt: Date(timeIntervalSince1970: 30)
        )
    }
    let state = try #require(try await fixture.store.state(for: fixture.volume.id))
    #expect(state.checkpoint == baseline.checkpoint)
    let reader = try SQLiteReportStore(databaseURL: fixture.databaseURL)
    let run = try #require(try await reader.recentRuns().first)
    #expect(run.status == .succeeded)
}

@Test("Writer status pairs the process lease with the active run")
func typedWriterState() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let run = ScanRun(
        kind: .incremental,
        reason: .manual,
        status: .running,
        startedAt: Date(timeIntervalSince1970: 10)
    )
    try await fixture.store.begin(run: run)
    #expect(try await fixture.store.activeRuns() == [run])
    let reader = try SQLiteReportStore(databaseURL: fixture.databaseURL)
    let state = try await reader.writerState()
    #expect(state.leaseIsHeld)
    #expect(state.activeRuns == [run])
    #expect(!state.hasOrphanedRuns)
}

@Test("Writer state identifies all orphaned running rows under a stable probe")
func orphanedWriterState() async throws {
    var fixture: StoreFixture? = try await StoreFixture()
    var store: SQLiteInventoryStore? = try #require(fixture?.store)
    let databaseURL = try #require(fixture?.databaseURL)
    let first = ScanRun(
        kind: .incremental,
        reason: .manual,
        status: .running,
        startedAt: Date(timeIntervalSince1970: 10)
    )
    let second = ScanRun(
        kind: .full,
        reason: .weeklyReconciliation,
        status: .running,
        startedAt: Date(timeIntervalSince1970: 20)
    )
    try await store?.begin(run: first)
    try await store?.begin(run: second)
    fixture = nil
    store = nil

    let reader = try SQLiteReportStore(databaseURL: databaseURL)
    let state = try await reader.writerState()
    #expect(!state.leaseIsHeld)
    #expect(state.activeRuns == [second, first])
    #expect(state.hasOrphanedRuns)
    try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
}

@Test("A strict shared reader is not reported as an active writer")
func sharedReaderIsNotAWriter() async throws {
    var fixture: StoreFixture? = try await StoreFixture()
    let databaseURL = try #require(fixture?.databaseURL)
    fixture = nil

    let reader = try SQLiteReportStore(
        databaseURL: databaseURL,
        strictReadOnly: true
    )
    let state = try await reader.writerState()
    #expect(!state.leaseIsHeld)
    #expect(state.activeRuns.isEmpty)
    #expect(!state.hasOrphanedRuns)
    try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
}

@Test("Store paging cancellation leaves committed inventory untouched")
func storePagingCancellation() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let records = try (0..<1_100).map { index in
        try fixture.record(
            path: "bulk/item-\(index)",
            inode: UInt64(index + 1),
            logicalBytes: 1,
            allocatedBytes: 1
        )
    }
    let baseline = try await establishBaseline(in: fixture, records: records)
    let run = ScanRun(
        kind: .full,
        reason: .manual,
        status: .running,
        startedAt: Date(timeIntervalSince1970: 30)
    )
    try await fixture.store.begin(run: run)
    let staging = try await fixture.store.createStagingGeneration(
        volumeID: fixture.volume.id,
        runID: run.id,
        at: run.startedAt
    )
    let observer = CancellingStoreObserver(limit: 3)
    await #expect(throws: CancellationError.self) {
        try await fixture.store.preserveOpaqueSubtrees(
            roots: [.root],
            from: .expectedActive(volumeID: fixture.volume.id),
            to: .stagingGeneration(staging.id),
            for: run.id,
            observer: observer
        )
    }
    #expect(await observer.count == 3)
    try await fixture.store.interrupt(
        runID: run.id,
        finishedAt: Date(timeIntervalSince1970: 40)
    )
    let state = try #require(try await fixture.store.state(for: fixture.volume.id))
    #expect(state.checkpoint == baseline.checkpoint)
    #expect(state.activeGeneration.id == baseline.generation.id)
    let database = try SQLiteDatabase(url: fixture.databaseURL, readOnly: true)
    #expect(try database.scalarInt64("SELECT COUNT(*) FROM inventory_generations") == 1)
}

@Test("Failed scans retain diagnostics but discard their uncommitted staging data")
func failedScanRetainsErrors() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }

    let run = ScanRun(
        kind: .full,
        reason: .manual,
        status: .running,
        startedAt: Date(timeIntervalSince1970: 10)
    )
    try await fixture.store.begin(run: run)
    let generation = try await fixture.store.createStagingGeneration(
        volumeID: fixture.volume.id,
        runID: run.id,
        at: run.startedAt
    )
    try await fixture.store.append(
        records: [fixture.record(path: "partial", inode: 4, logicalBytes: 1, allocatedBytes: 1)],
        to: generation.id
    )
    let error = ScanErrorRecord(
        runID: run.id,
        volumeID: fixture.volume.id,
        kind: .permissionDenied,
        path: try RelativePath(validating: "private/var/protected"),
        errorCode: 13,
        message: "Permission denied"
    )
    try await fixture.store.fail(
        runID: run.id,
        errors: [error],
        finishedAt: Date(timeIntervalSince1970: 20)
    )

    let reader = try SQLiteReportStore(databaseURL: fixture.databaseURL)
    #expect(try await reader.errors(for: run.id) == [error])
    let runs = try await reader.recentRuns()
    #expect(runs[0].status == .failed)
    #expect(runs[0].errorCount == 1)

    let database = try SQLiteDatabase(url: fixture.databaseURL, readOnly: true)
    #expect(try database.scalarInt64("SELECT COUNT(*) FROM inventory_generations") == 0)
}

@Test("Cancelling a large staging generation removes children while preserving the active baseline")
func largeStagingCleanup() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let baseline = try await establishBaseline(in: fixture)
    let run = ScanRun(kind: .full, reason: .manual, status: .running, startedAt: Date())
    try await fixture.store.begin(run: run)
    let generation = try await fixture.store.createStagingGeneration(
        volumeID: fixture.volume.id, runID: run.id, at: Date())
    for start in stride(from: 0, to: 10_000, by: 500) {
        let records = try (start..<(start + 500)).map { index in
            try fixture.record(
                path: "synthetic/\(index)", inode: UInt64(index + 100), logicalBytes: 1, allocatedBytes: 512)
        }
        try await fixture.store.append(records: records, to: generation.id)
    }
    try await fixture.store.interrupt(runID: run.id, finishedAt: Date())
    #expect(try await fixture.store.state(for: fixture.volume.id)?.checkpoint == baseline.checkpoint)
    let reader = try SQLiteReportStore(databaseURL: fixture.databaseURL)
    #expect(try await reader.recentRuns().first?.status == .interrupted)
    let diagnostics = try await reader.diagnostics()
    #expect(diagnostics.tableCounts["inventory_generations"] == 1)
    #expect(diagnostics.tableCounts["inventory_paths"] == Int64(baseline.records.count))
}
