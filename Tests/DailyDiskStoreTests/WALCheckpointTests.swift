import Darwin
import Foundation
import Testing

@testable import DailyDiskStore

@Test("Bounded WAL retains FULL durability and refuses further writes behind a pinned reader")
func boundedWALWithPinnedReader() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BoundedWAL-\(UUID())")
    let url = root.appendingPathComponent("test.sqlite")
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try SQLiteDatabase(url: url, checkpointPolicy: .bounded(softLimitBytes: 4096, hardLimitBytes: 32768))
    #expect(try writer.scalarInt64("PRAGMA synchronous") == 2)
    #expect(try writer.scalarInt64("PRAGMA wal_autocheckpoint") == 0)
    try writer.transaction { try writer.execute("CREATE TABLE probe (value BLOB); INSERT INTO probe VALUES (X'01')") }
    let reader = try SQLiteDatabase(url: url, readOnly: true)
    try reader.execute("BEGIN")
    #expect(try reader.scalarInt64("SELECT COUNT(*) FROM probe") == 1)
    try writer.transaction { try writer.execute("INSERT INTO probe VALUES (zeroblob(65536))") }
    #expect(writer.walBytes > 32768)
    #expect(try writer.scalarInt64("SELECT COUNT(*) FROM probe") == 2)
    #expect(throws: SQLiteStoreError.self) {
        try writer.transaction { try writer.execute("INSERT INTO probe VALUES (X'03')") }
    }
    #expect(try writer.scalarInt64("SELECT COUNT(*) FROM probe") == 2)
    #expect(try reader.scalarInt64("SELECT COUNT(*) FROM probe") == 1)
    #expect(throws: SQLiteStoreError.self) { _ = try SQLiteDatabase(url: url, readOnly: true, immutable: true) }
    try reader.execute("COMMIT")
    try writer.checkpointWAL()
    #expect(writer.walBytes == 0)
    let strict = try SQLiteDatabase(url: url, readOnly: true, immutable: true)
    #expect(try strict.scalarInt64("SELECT COUNT(*) FROM probe") == 2)
    #expect(try strict.scalarText("PRAGMA integrity_check") == "ok")
}

@Test("Process death preserves committed uncheckpointed WAL and rolls back later staging")
func boundedWALCrashRecovery() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("WALCrash-\(UUID())")
    let url = root.appendingPathComponent("test.sqlite")
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let db = try SQLiteDatabase(url: url, checkpointPolicy: .bounded())
        try db.transaction { try db.execute("CREATE TABLE probe (value INTEGER)") }
    }
    let ready = root.appendingPathComponent("ready.txt")
    FileManager.default.createFile(atPath: ready.path, contents: nil)
    let output = try FileHandle(forWritingTo: ready)
    defer { try? output.close() }
    let input = Pipe()
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    child.arguments = [url.path]
    child.standardInput = input
    child.standardOutput = output
    child.standardError = output
    try child.run()
    defer {
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        try? input.fileHandleForWriting.close()
    }
    try input.fileHandleForWriting.write(
        contentsOf: Data(
            """
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=FULL;
            PRAGMA wal_autocheckpoint=0;
            BEGIN IMMEDIATE;
            INSERT INTO probe VALUES (1);
            COMMIT;
            BEGIN IMMEDIATE;
            INSERT INTO probe VALUES (2);
            .print STAGED

            """.utf8))
    let deadline = Date().addingTimeInterval(10)
    while !(try String(contentsOf: ready, encoding: .utf8)).contains("STAGED") {
        guard child.isRunning, Date() < deadline else { throw POSIXError(.ETIMEDOUT) }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(
        (try FileManager.default.attributesOfItem(atPath: url.path + "-wal")[.size] as? NSNumber)?.intValue ?? 0 > 0)
    let pid = child.processIdentifier
    #expect(kill(pid, SIGKILL) == 0)
    let exitDeadline = Date().addingTimeInterval(10)
    // Bound exit observation: a concurrent test run was observed stuck in
    // waitUntilExit after the child was gone. Kernel exit is sufficient here.
    while kill(pid, 0) == 0 {
        guard Date() < exitDeadline else { throw POSIXError(.ETIMEDOUT) }
        try await Task.sleep(for: .milliseconds(10))
    }
    guard errno == ESRCH else { throw POSIXError(.ECHILD) }
    let recovered = try SQLiteDatabase(url: url, checkpointPolicy: .bounded())
    #expect(try recovered.scalarInt64("SELECT COUNT(*) FROM probe") == 1)
    #expect(try recovered.scalarInt64("SELECT value FROM probe") == 1)
    #expect(try recovered.scalarText("PRAGMA integrity_check") == "ok")
    try recovered.checkpointWAL()
    #expect(recovered.walBytes == 0)
}

@Test("Closing a bounded writer tolerates checkpoint I/O failure without an unowned-reference crash")
func boundedWALCloseFailure() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("WALClose-\(UUID())")
    let url = root.appendingPathComponent("test.sqlite")
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let db = try SQLiteDatabase(url: url, checkpointPolicy: .bounded())
        try db.transaction {
            try db.execute("CREATE TABLE probe (value BLOB); INSERT INTO probe VALUES (zeroblob(8192))")
        }
        // Synthetic fixture teardown / disappearing backing storage: deinit
        // must use the native API, not a statement with an unowned self.
        try FileManager.default.removeItem(at: root)
    }
}
