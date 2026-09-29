import DailyDiskCore
import Darwin
import Foundation
import Testing

@testable import DailyDiskStore

@Test("Compact inventory uses integer keys, immutable nodes and exact raw-path projections")
func compactInventoryProjection() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let run = ScanRun(kind: .full, reason: .manual, status: .running, startedAt: Date())
    try await fixture.store.begin(run: run)
    let generation = try await fixture.store.createStagingGeneration(
        volumeID: fixture.volume.id, runID: run.id, at: run.startedAt)
    let paths = [Data(), Data("top".utf8), Data("top/deep/".utf8) + Data([255, 128])]
    var records: [InventoryRecord] = []
    for (index, bytes) in paths.enumerated() {
        let sample = try fixture.record(path: "sample", inode: UInt64(index + 1), logicalBytes: 71, allocatedBytes: 512)
        let path = try RelativePath(validating: bytes)
        records.append(
            try InventoryRecord(
                object: sample.object,
                path: InventoryPath(
                    volumeID: fixture.volume.id, relativePath: path, parentPath: PathPolicy.parent(of: path),
                    objectIdentity: sample.object.identity)))
    }
    try await fixture.store.append(records: records, to: generation.id)
    let actual = try await fixture.store.records(
        target: .stagingGeneration(generation.id), runID: run.id, paths: records.map(\.path.relativePath))
    #expect(actual == records)
    let db = try SQLiteDatabase(url: fixture.databaseURL)
    #expect(try db.scalarText("SELECT typeof(generation_id) FROM hybrid_objects LIMIT 1") == "integer")
    #expect(
        try db.scalarInt64(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='view' AND name IN ('inventory_paths','inventory_objects','canonical_attributions')"
        ) == 3)
    #expect(try db.verifyHybridOrdering() == 0)
    #expect(throws: SQLiteStoreError.self) { try db.execute("UPDATE hybrid_nodes SET name=x'78'") }
    #expect(throws: SQLiteStoreError.self) { try db.execute("UPDATE hybrid_generations SET volume_id=volume_id") }
    try await fixture.store.interrupt(runID: run.id, finishedAt: Date())
    try db.collectHybridNodes()
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM hybrid_nodes") == 0)
}

@Test("Compact writer retries failed node insertion without retaining rolled-back IDs")
func compactWriterFailureRecovery() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let run = ScanRun(kind: .full, reason: .manual, status: .running, startedAt: Date())
    try await fixture.store.begin(run: run)
    let generation = try await fixture.store.createStagingGeneration(
        volumeID: fixture.volume.id, runID: run.id, at: run.startedAt)
    let db = try SQLiteDatabase(url: fixture.databaseURL)
    let writer = try HybridInventoryWriter(database: db, generationID: generation.id)
    let record = try fixture.record(path: "new/blocked/file", inode: 8, logicalBytes: 99, allocatedBytes: 512)
    try db.execute(
        """
        CREATE TRIGGER injected_node_failure BEFORE INSERT ON hybrid_nodes
        WHEN NEW.name=x'626c6f636b6564' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END;
        """)
    #expect(throws: SQLiteStoreError.self) { try db.transaction { try writer.write(record) } }
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM hybrid_nodes") == 0)
    try db.execute("DROP TRIGGER injected_node_failure")
    try db.transaction { try writer.write(record) }
    #expect(try db.verifyHybridOrdering() == 0)
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM hybrid_paths") == 1)
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM checkpoints") == 0)
}

@Test(
    "Missing or incorrect compact ordering cannot seal a full generation or pass explicit verification",
    arguments: [false, true])
func compactOrderingFailureStopsSeal(wrongPath: Bool) async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let baseline = try await establishBaseline(in: fixture)
    let run = ScanRun(kind: .full, reason: .manual, status: .running, startedAt: Date())
    try await fixture.store.begin(run: run)
    let generation = try await fixture.store.createStagingGeneration(
        volumeID: fixture.volume.id, runID: run.id, at: run.startedAt)
    try await fixture.store.append(records: baseline.records, to: generation.id)
    let db = try SQLiteDatabase(url: fixture.databaseURL)
    let key = try db.hybridGenerationKey(generation.id)
    if wrongPath {
        try db.execute("UPDATE hybrid_order SET path=x'626164' WHERE generation_id=\(key)")
    } else {
        try db.execute("DELETE FROM hybrid_order WHERE generation_id=\(key)")
    }
    // This corruption passes SQLite FK checks, so the application audit is essential.
    let foreign = try db.prepare("PRAGMA foreign_key_check")
    #expect(try !foreign.step())
    #expect(try db.verifyHybridOrdering() == 1)
    await #expect(throws: StoreInvariantError.self) {
        try await fixture.store.finalizeCanonicalAttribution(
            target: .stagingGeneration(generation.id), runID: run.id, consume: { _ in })
    }
    #expect(try await fixture.store.state(for: fixture.volume.id)?.checkpoint == baseline.checkpoint)
    let reports = try SQLiteReportStore(databaseURL: fixture.databaseURL)
    #expect(try await reports.verify().invariantViolationCount > 0)
    try await fixture.store.interrupt(runID: run.id, finishedAt: Date())
    #expect(try db.verifyHybridOrdering() == 0)
}

@Test("A killed SQLite transaction cannot expose mixed compact membership, order and checkpoint")
func compactTransactionCrashRecovery() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let baseline = try await establishBaseline(in: fixture)
    let ready = fixture.rootURL.appendingPathComponent("transaction-ready")
    let child = Process()
    let input = Pipe()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    child.arguments = [fixture.databaseURL.path]
    child.standardInput = input
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    try child.run()
    defer {
        if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
        try? input.fileHandleForWriting.close()
    }
    let quoted = ready.path.replacingOccurrences(of: "\"", with: "\\\"")
    let sql = """
        .bail on
        PRAGMA foreign_keys=ON;
        PRAGMA cache_size=1;
        BEGIN IMMEDIATE;
        DELETE FROM hybrid_paths;
        UPDATE checkpoints SET last_committed_event_id=999;
        .once "\(quoted)"
        SELECT 'ready';

        """
    try input.fileHandleForWriting.write(contentsOf: Data(sql.utf8))
    let deadline = Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath: ready.path) && child.isRunning && Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(FileManager.default.fileExists(atPath: ready.path))
    guard child.isRunning else {
        Issue.record("Synthetic transaction worker exited before crash injection")
        return
    }
    #expect(kill(child.processIdentifier, SIGKILL) == 0)
    while child.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(!child.isRunning)
    let db = try SQLiteDatabase(url: fixture.databaseURL)
    #expect(try db.scalarText("PRAGMA integrity_check") == "ok")
    #expect(try db.verifyHybridOrdering() == 0)
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM hybrid_paths") == Int64(baseline.records.count))
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM hybrid_canonical") == Int64(baseline.records.count))
    #expect(try await fixture.store.state(for: fixture.volume.id)?.checkpoint == baseline.checkpoint)
}
