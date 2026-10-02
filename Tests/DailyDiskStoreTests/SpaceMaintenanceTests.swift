import DailyDiskCore
import Darwin
import Foundation
import Testing

@testable import DailyDiskStore

private func publishBaseline(_ baseline: BaselineResult, in fixture: StoreFixture) async throws {
    let report = try DailyReport(
        runID: baseline.run.id, generatedAt: Date(timeIntervalSince1970: 21),
        storageDomainID: fixture.scope.domain.id,
        accounting: SpaceAccounting.summarize(
            changes: [], scope: fixture.scope, previousSample: nil, currentSample: baseline.sample),
        reconciliation: nil,
        coverage: ScanCoverage(
            visitedPathCount: 1, indexedObjectCount: 1, unreadablePathCount: 0, transientErrorCount: 0),
        largestGrowth: [], largestShrinkage: [], diagnostics: []
    )
    try await fixture.store.commitReport(
        ReportCommit(
            runID: baseline.run.id, scope: fixture.scope, changes: [], previousStorageSample: nil,
            currentStorageSample: baseline.sample, previousOverheadSample: nil, currentOverheadSample: nil,
            report: report
        )
    )
}

private func addRetiredInventory(to fixture: StoreFixture, retiredAt: Double) throws -> String {
    let db = try SQLiteDatabase(url: fixture.databaseURL)
    let id = UUID().uuidString
    let statement = try db.prepare(
        """
        INSERT INTO inventory_generations(id,volume_id,created_by_run_id,state,created_at,retired_at)
        SELECT ?,volume_id,created_by_run_id,'retired',0,? FROM inventory_generations WHERE state='active'
        """
    )
    try statement.bind(id, at: 1)
    try statement.bind(retiredAt, at: 2)
    _ = try statement.step()
    // Synthetic long paths exercise all published indexes and the cleanup trigger.
    try db.execute(
        """
        INSERT INTO hybrid_objects SELECT (SELECT id FROM hybrid_generations WHERE external_id='\(id)'),
            volume_id,device_id,inode,kind,logical_bytes,allocated_bytes,link_count,modified_at,metadata_changed_at
            FROM hybrid_objects WHERE generation_id = (SELECT g.id FROM hybrid_generations g
                JOIN checkpoints c ON c.active_generation_id=g.external_id LIMIT 1);
        INSERT INTO hybrid_paths SELECT (SELECT id FROM hybrid_generations WHERE external_id='\(id)'),
            volume_id,path_id,device_id,inode,classification FROM hybrid_paths
            WHERE generation_id = (SELECT g.id FROM hybrid_generations g
                JOIN checkpoints c ON c.active_generation_id=g.external_id LIMIT 1);
        INSERT INTO hybrid_order SELECT (SELECT id FROM hybrid_generations WHERE external_id='\(id)'),path,path_id
            FROM hybrid_order WHERE generation_id = (SELECT g.id FROM hybrid_generations g
                JOIN checkpoints c ON c.active_generation_id=g.external_id LIMIT 1);
        INSERT INTO hybrid_canonical SELECT (SELECT id FROM hybrid_generations WHERE external_id='\(id)'),
            volume_id,device_id,inode,path_id,classification FROM hybrid_canonical
            WHERE generation_id = (SELECT g.id FROM hybrid_generations g
                JOIN checkpoints c ON c.active_generation_id=g.external_id LIMIT 1);
        """
    )
    return id
}

@Test("Retirement expires from replacement time and pending reports protect all recovery inventory")
func retirementWindowAndPendingReport() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let baseline = try await establishBaseline(in: fixture)
    let retired = try addRetiredInventory(to: fixture, retiredAt: 100.75)
    let db = try SQLiteDatabase(url: fixture.databaseURL, readOnly: true)
    try await fixture.store.pruneRetiredGenerations(at: Date(timeIntervalSince1970: 200_000))
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM inventory_generations WHERE state='retired'") == 1)
    await #expect(throws: SpaceMaintenanceError.recoveryPending) {
        try await fixture.store.maintainSpace(force: true, availableBytes: { Int64.max })
    }
    try await publishBaseline(baseline, in: fixture)
    try await fixture.store.pruneRetiredGenerations(at: Date(timeIntervalSince1970: 86_500.5))
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM inventory_generations WHERE id='\(retired)'") == 1)
    try await fixture.store.pruneRetiredGenerations(at: Date(timeIntervalSince1970: 86_500.75))
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM inventory_generations WHERE state='retired'") == 0)
    #expect(try await fixture.store.state(for: fixture.volume.id)?.checkpoint == baseline.checkpoint)
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM inventory_paths") == 1)
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM daily_reports") == 1)
}

@Test("Vacuum reclaims allocated bytes without changing baseline, raw paths, or report payload")
func maintenanceCompactsAndPreservesBasis() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let prefix = "synthetic/repeated-prefix/" + String(repeating: "long-component/", count: 8)
    var records: [InventoryRecord] = []
    records.reserveCapacity(2001)
    for index in 0..<2000 {
        let path = prefix + String(index)
        let linkCount: UInt64 = index == 0 ? 2 : 1
        let record = try fixture.record(
            path: path, inode: UInt64(index + 1), logicalBytes: 100,
            allocatedBytes: 128, linkCount: linkCount)
        records.append(record)
    }
    let rawPath = try RelativePath(validating: Data([0x66, 0xff]))
    records.append(
        try InventoryRecord(
            object: records[0].object,
            path: InventoryPath(
                volumeID: fixture.volume.id, relativePath: rawPath, parentPath: .root,
                objectIdentity: records[0].object.identity)))
    let baseline = try await establishBaseline(in: fixture, records: records)
    try await publishBaseline(baseline, in: fixture)
    _ = try addRetiredInventory(to: fixture, retiredAt: 100)
    let reader = try SQLiteReportStore(databaseURL: fixture.databaseURL)
    let report = try await reader.report(runID: baseline.run.id)
    let before = try await reader.spaceUsage()
    try await fixture.store.maintainSpace(
        at: Date(timeIntervalSince1970: 200_000), force: true, availableBytes: { Int64.max })
    let after = try await reader.spaceUsage()
    #expect(after.allocatedBytes < before.allocatedBytes)
    #expect(after.maintenanceStatus == "completed")
    #expect(after.lastReclaimedBytes != nil)
    #expect(try await reader.report(runID: baseline.run.id) == report)
    #expect(try await fixture.store.state(for: fixture.volume.id)?.checkpoint == baseline.checkpoint)
    #expect(try await reader.verify().isHealthy)
    let db = try SQLiteDatabase(url: fixture.databaseURL, readOnly: true)
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM inventory_paths WHERE path=x'66ff'") == 1)
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM inventory_objects") == 2000)
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM inventory_paths") == 2001)
}

@Test("Insufficient maintenance space and a competing writer preserve committed state")
func maintenanceInsufficientSpace() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let baseline = try await establishBaseline(in: fixture)
    try await publishBaseline(baseline, in: fixture)
    await #expect(throws: SpaceMaintenanceError.insufficientSpace) {
        try await fixture.store.maintainSpace(force: true, availableBytes: { 0 })
    }
    #expect(throws: WriterLeaseError.alreadyHeld) { try SQLiteInventoryStore(databaseURL: fixture.databaseURL) }
    #expect(try await fixture.store.state(for: fixture.volume.id)?.checkpoint == baseline.checkpoint)
    let reader = try SQLiteReportStore(databaseURL: fixture.databaseURL)
    #expect(try await reader.spaceUsage().maintenanceStatus == "insufficientSpace")
    #expect(try await reader.report(runID: baseline.run.id) != nil)
}

@Test("Interrupted maintenance is verified and not automatically retried inside the cooldown")
func interruptedMaintenanceRecovery() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let baseline = try await establishBaseline(in: fixture)
    try await publishBaseline(baseline, in: fixture)
    do {
        let db = try SQLiteDatabase(url: fixture.databaseURL)
        try db.execute("INSERT INTO space_maintenance(singleton,status,attempted_at) VALUES(1,'running',100)")
    }
    try await fixture.store.maintainSpace(at: Date(timeIntervalSince1970: 101))
    let reader = try SQLiteReportStore(databaseURL: fixture.databaseURL)
    let usage = try await reader.spaceUsage()
    #expect(usage.maintenanceStatus == "interrupted")
    #expect(usage.lastMaintenanceAt == nil)
    #expect(try await reader.verify().isHealthy)
    #expect(try await fixture.store.state(for: fixture.volume.id)?.checkpoint == baseline.checkpoint)
}

@Test("Automatic compaction requires both thresholds and seven days between attempts")
func maintenanceThresholds() {
    let policy = SpaceMaintenancePolicy()
    func usage(_ size: Int64, _ free: Int64) -> DatabaseSpaceUsage {
        DatabaseSpaceUsage(
            allocatedBytes: size, databaseBytes: size, reusableBytes: free,
            maintenanceStatus: nil, lastMaintenanceAt: nil, lastReclaimedBytes: nil)
    }
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(!policy.shouldCompact(usage: usage(1000, 0), lastAttempt: nil, now: now))
    #expect(!policy.shouldCompact(usage: usage(10_000_000_000, 2_000_000_000), lastAttempt: nil, now: now))
    #expect(policy.shouldCompact(usage: usage(13_000_000_000, 5_000_000_000), lastAttempt: nil, now: now))
    #expect(!policy.shouldCompact(usage: usage(13_000_000_000, 5_000_000_000), lastAttempt: now, now: now))
    #expect(
        policy.shouldCompact(
            usage: usage(13_000_000_000, 5_000_000_000),
            lastAttempt: now.addingTimeInterval(-7 * 86400), now: now))
}

@Test("Retired cleanup rolls back every child deletion on failure and never deletes a referenced generation")
func retirementCleanupFailureAndReferences() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let baseline = try await establishBaseline(in: fixture)
    try await publishBaseline(baseline, in: fixture)
    _ = try addRetiredInventory(to: fixture, retiredAt: 1)
    let db = try SQLiteDatabase(url: fixture.databaseURL)
    try db.execute(
        """
        CREATE TRIGGER injected_cleanup_failure BEFORE DELETE ON hybrid_objects
        BEGIN SELECT RAISE(ABORT,'synthetic cleanup failure'); END;
        """
    )
    await #expect(throws: (any Error).self) {
        try await fixture.store.pruneRetiredGenerations(at: Date(timeIntervalSince1970: 200_000))
    }
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM inventory_paths") == 2)
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM canonical_attributions") == 2)
    #expect(try await fixture.store.state(for: fixture.volume.id)?.checkpoint == baseline.checkpoint)
    try db.execute("DROP TRIGGER injected_cleanup_failure")
    let running = ScanRun(kind: .incremental, reason: .manual, status: .running, startedAt: Date())
    try await fixture.store.begin(run: running)
    try await fixture.store.pruneRetiredGenerations(at: Date(timeIntervalSince1970: 200_000))
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM inventory_generations") == 2)
    try await fixture.store.interrupt(runID: running.id, finishedAt: Date())
    try await fixture.store.pruneRetiredGenerations(at: Date(timeIntervalSince1970: 200_000))
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM inventory_generations") == 1)
}

@Test("A killed native VACUUM reopens with the original baseline and reports intact")
func killedVacuumRecovery() async throws {
    // Use the system SQLite executable only on a synthetic database. Wait for
    // VACUUM to start copying into its WAL before killing the child process.
    func seed() async throws -> (URL, Checkpoint, ScanRun.ID) {
        let fixture = try await StoreFixture()
        let baseline = try await establishBaseline(in: fixture)
        try await publishBaseline(baseline, in: fixture)
        let db = try SQLiteDatabase(url: fixture.databaseURL)
        try db.execute(
            """
            CREATE TABLE synthetic_vacuum_payload(id INTEGER PRIMARY KEY, payload BLOB);
            WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<64)
            INSERT INTO synthetic_vacuum_payload SELECT i,zeroblob(1048576) FROM n;
            DELETE FROM synthetic_vacuum_payload WHERE id%2=0;
            INSERT INTO space_maintenance(singleton,status,attempted_at) VALUES(1,'running',100);
            PRAGMA wal_checkpoint(TRUNCATE);
            """
        )
        return (fixture.databaseURL, baseline.checkpoint, baseline.run.id)
    }
    let (url, checkpoint, runID) = try await seed()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    child.arguments = [url.path, "PRAGMA synchronous=FULL; VACUUM;"]
    child.standardOutput = FileHandle.nullDevice
    let errors = Pipe()
    child.standardError = errors
    let interrupted = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Bool, any Error>) in
        // A dedicated OS thread keeps the kill injection from being starved by
        // the concurrently running async test suite.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try child.run()
                let wal = url.path + "-wal"
                let deadline = Date().addingTimeInterval(10)
                var killed = false
                while child.isRunning && Date() < deadline {
                    var metadata = stat()
                    if lstat(wal, &metadata) == 0, metadata.st_size > 0 {
                        kill(child.processIdentifier, SIGKILL)
                        killed = true
                        break
                    }
                    usleep(100)
                }
                if child.isRunning && !killed { child.terminate() }
                child.waitUntilExit()
                continuation.resume(returning: killed)
            } catch { continuation.resume(throwing: error) }
        }
    }
    if !interrupted {
        let errorText = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        Issue.record("Synthetic VACUUM did not reach WAL writes: status \(child.terminationStatus), \(errorText)")
    }
    #expect(interrupted)
    let store = try SQLiteInventoryStore(databaseURL: url)
    try await store.prepare()
    try await store.recoverSpaceMaintenance()
    #expect(try await store.state(for: checkpoint.volumeID)?.checkpoint == checkpoint)
    let reader = try SQLiteReportStore(databaseURL: url)
    #expect(try await reader.report(runID: runID) != nil)
    #expect(try await reader.verify().isHealthy)
    #expect(try await reader.spaceUsage().maintenanceStatus == "interrupted")
    let db = try SQLiteDatabase(url: url, readOnly: true)
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM synthetic_vacuum_payload") == 32)
}

@Test("Activation timestamps retirement at replacement rather than the old scan's creation or sampling time")
func retirementUsesActivationTime() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let baseline = try await establishBaseline(in: fixture)
    let run = ScanRun(kind: .full, reason: .manual, status: .running, startedAt: Date(timeIntervalSince1970: 30))
    try await fixture.store.begin(run: run)
    let generation = try await fixture.store.createStagingGeneration(
        volumeID: fixture.volume.id, runID: run.id, at: run.startedAt)
    try await fixture.store.append(records: baseline.records, to: generation.id)
    for target in [
        InventoryMutationTarget.expectedActive(volumeID: fixture.volume.id), .stagingGeneration(generation.id),
    ] {
        try await fixture.store.finalizeCanonicalAttribution(target: target, runID: run.id, consume: { _ in })
    }
    let next = Checkpoint(
        volumeID: fixture.volume.id, eventStoreUUID: fixture.volume.eventStoreUUID,
        lastCommittedEventID: 20, activeGenerationID: generation.id,
        topologyFingerprint: fixture.volume.topologyFingerprint,
        lastSuccessfulIncrementalAt: nil, lastSuccessfulFullScanAt: Date(timeIntervalSince1970: 40))
    let started = Date()
    try await fixture.store.commit(
        ScanCommit(
            runID: run.id, runKind: .full, scope: fixture.scope, volumeID: fixture.volume.id,
            activatedGenerationID: generation.id, previousCheckpoint: baseline.checkpoint, checkpoint: next,
            eventFence: EventCursorFence(
                volumeID: fixture.volume.id, eventStoreUUID: fixture.volume.eventStoreUUID,
                highestFullyDeliveredEventID: 20, phase: .liveFlush, trust: .trusted),
            changes: [], storageSamples: [], snapshotSamples: []), finishedAt: Date(timeIntervalSince1970: 40))
    let db = try SQLiteDatabase(url: fixture.databaseURL, readOnly: true)
    let retired = try #require(
        try db.scalarDouble("SELECT retired_at FROM inventory_generations WHERE state='retired'"))
    #expect(retired >= started.timeIntervalSince1970)
    #expect(retired <= Date().timeIntervalSince1970)
}

@Test("Lost post-commit completion marker does not roll back inventory or invent daily success")
func missingFullCompletionMarker() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    do {
        let db = try SQLiteDatabase(url: fixture.databaseURL)
        try db.execute(
            """
            CREATE TRIGGER fail_completion BEFORE UPDATE OF inventory_completed_at ON scan_runs
            BEGIN SELECT RAISE(FAIL, 'synthetic completion marker failure'); END;
            """)
    }
    let baseline = try await establishBaseline(in: fixture)
    #expect(try await fixture.store.state(for: fixture.volume.id)?.checkpoint == baseline.checkpoint)
    #expect(try await fixture.store.scanRun(id: baseline.run.id)?.status == .succeeded)
    try await publishBaseline(baseline, in: fixture)
    let reader = try SQLiteReportStore(databaseURL: fixture.databaseURL)
    #expect(try await reader.report(runID: baseline.run.id) != nil)
    #expect(try await reader.latestSuccessfulFullReportDate(for: fixture.scope.domain.id) == nil)
}

@Test("Retired generation pruning honors W6 history references until their recovery window expires")
func retirementPinsReuseHistory() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let baseline = try await establishBaseline(in: fixture)
    try await publishBaseline(baseline, in: fixture)
    let older = try addRetiredInventory(to: fixture, retiredAt: 100)
    _ = try addRetiredInventory(to: fixture, retiredAt: 200)
    let db = try SQLiteDatabase(url: fixture.databaseURL)
    let insert = try db.prepare(
        "INSERT INTO inventory_reuse_history(run_id,generation_id,retired_at,checkpoint) VALUES(?,?,?,?)")
    try insert.bind(baseline.run.id.rawValue.uuidString, at: 1)
    try insert.bind(older, at: 2)
    try insert.bind(300000.0, at: 3)
    let retainedCheckpoint = Checkpoint(
        volumeID: fixture.volume.id, eventStoreUUID: fixture.volume.eventStoreUUID,
        lastCommittedEventID: baseline.checkpoint.lastCommittedEventID,
        activeGenerationID: InventoryGeneration.ID(try #require(UUID(uuidString: older))),
        topologyFingerprint: fixture.volume.topologyFingerprint,
        lastSuccessfulIncrementalAt: nil,
        lastSuccessfulFullScanAt: baseline.checkpoint.lastSuccessfulFullScanAt)
    try insert.bind(JSONEncoder().encode(retainedCheckpoint), at: 4)
    _ = try insert.step()
    try await fixture.store.pruneRetiredGenerations(at: Date(timeIntervalSince1970: 300001))
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM inventory_generations WHERE state='retired'") == 1)
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM inventory_reuse_history") == 1)
    try await fixture.store.pruneRetiredGenerations(at: Date(timeIntervalSince1970: 400000))
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM inventory_generations WHERE state='retired'") == 0)
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM inventory_reuse_history") == 0)
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM daily_reports") == 1)
}
