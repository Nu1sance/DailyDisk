import Foundation
import Testing

@testable import DailyDiskStore

private func temporaryDatabaseURL(_ name: String = UUID().uuidString) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DailyDiskStoreTests", isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.appendingPathComponent("DailyDisk.sqlite")
}

@Test("Initial migration creates the complete schema and is idempotent")
func initialMigrationIsIdempotent() async throws {
    let url = try temporaryDatabaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let store = try SQLiteInventoryStore(databaseURL: url)
    try await store.prepare()
    try await store.prepare()

    let database = try SQLiteDatabase(url: url, readOnly: true)
    #expect(try database.scalarInt64("PRAGMA user_version") == Int64(DailyDiskSchema.currentVersion))
    #expect(
        try database.scalarInt64("SELECT COUNT(*) FROM schema_metadata")
            == Int64(DailyDiskSchema.currentVersion)
    )
    #expect(try database.scalarInt64("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table'")! >= 15)
    #expect(try database.scalarInt64("PRAGMA foreign_keys") == 1)
}

@Test("Database and parent directory are private to the current user")
func databasePermissionsArePrivate() async throws {
    let url = try temporaryDatabaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let store = try SQLiteInventoryStore(databaseURL: url)
    try await store.prepare()

    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
    let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let directoryMode = try #require(directoryAttributes[.posixPermissions] as? NSNumber)
    let fileMode = try #require(fileAttributes[.posixPermissions] as? NSNumber)
    #expect(directoryMode.intValue & 0o077 == 0)
    #expect(fileMode.intValue & 0o077 == 0)
}

@Test("A user_version without matching metadata is rejected before migration")
func divergentUserVersionIsRejected() async throws {
    let url = try temporaryDatabaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    do {
        let database = try SQLiteDatabase(url: url)
        try database.execute("PRAGMA user_version = 999")
    }

    let store = try SQLiteInventoryStore(databaseURL: url)
    await #expect(throws: (any Error).self) {
        try await store.prepare()
    }
    let inspection = try SQLiteDatabase(url: url, readOnly: true)
    #expect(
        try inspection.scalarInt64(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'schema_metadata'"
        ) == 0
    )
}

@Test("A newer database schema is rejected")
func newerSchemaIsRejected() async throws {
    let url = try temporaryDatabaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    do {
        let database = try SQLiteDatabase(url: url)
        try database.execute(
            """
            CREATE TABLE schema_metadata (
                version INTEGER PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                applied_at REAL NOT NULL
            ) STRICT;
            INSERT INTO schema_metadata(version, name, applied_at)
            VALUES (999, 'future', 0);
            """
        )
    }

    let store = try SQLiteInventoryStore(databaseURL: url)
    await #expect(throws: (any Error).self) {
        try await store.prepare()
    }
}

@Test("Version two upgrades without losing data and installs generation cleanup")
func cascadeIndexMigration() throws {
    let url = try temporaryDatabaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let db = try SQLiteDatabase(url: url)
    try DatabaseMigrator.migrate(db, targetVersion: 5)
    // Recreate the exact published v2 schema, then exercise its upgrade.
    try db.execute("DROP TABLE space_maintenance")
    try db.execute("DROP INDEX inventory_generations_retirement_idx")
    try db.execute("ALTER TABLE inventory_generations DROP COLUMN retired_at")
    try db.execute("DROP TRIGGER inventory_generation_cleanup")
    try db.execute("DROP INDEX inventory_paths_parent_object_idx")
    try db.execute("DELETE FROM schema_metadata WHERE version >= 3")
    try db.execute("PRAGMA user_version = 2")
    try db.execute("INSERT INTO settings(key,value,updated_at) VALUES ('migration-sentinel', x'1234', 0)")
    try DatabaseMigrator.migrate(db, targetVersion: 5)
    #expect(try db.scalarInt64("PRAGMA user_version") == 5)
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM settings WHERE key='migration-sentinel'") == 1)
    #expect(
        try db.scalarInt64("SELECT COUNT(*) FROM sqlite_master WHERE name = 'inventory_paths_parent_object_idx'") == 1)
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM sqlite_master WHERE name = 'inventory_generation_cleanup'") == 1)
    try DatabaseMigrator.migrate(db, targetVersion: 5)
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM schema_metadata") == 5)
}

@Test("Version four retirement upgrade grants a fresh recovery window and preserves the active checkpoint")
func retirementMigrationWindow() throws {
    let url = try temporaryDatabaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let db = try SQLiteDatabase(url: url)
    try DatabaseMigrator.migrate(db, targetVersion: 4)
    try db.execute(
        """
        INSERT INTO storage_domains VALUES('domain','container','Synthetic',1);
        INSERT INTO volumes VALUES('volume','domain',NULL,NULL,NULL,1,NULL,'Data','data',1,0,0,1,'topology','full');
        INSERT INTO scan_runs VALUES('run','full','manual','succeeded',1,2,0);
        INSERT INTO inventory_generations VALUES('active','volume','run','active',1);
        INSERT INTO inventory_generations VALUES('retired','volume','run','retired',1);
        INSERT INTO checkpoints VALUES('volume','journal',123,'active','topology',NULL,2);
        """)
    let migratedAt = Date(timeIntervalSince1970: 1_000_000.75)
    try DatabaseMigrator.migrate(db, now: migratedAt, targetVersion: 5)
    #expect(try db.scalarDouble("SELECT retired_at FROM inventory_generations WHERE state='retired'") == 1_000_000.75)
    #expect(try db.scalarDouble("SELECT retired_at FROM inventory_generations WHERE state='active'") == nil)
    #expect(try db.scalarText("SELECT active_generation_id FROM checkpoints") == "active")
    #expect(try db.scalarInt64("SELECT last_committed_event_id FROM checkpoints") == 123)
    try DatabaseMigrator.migrate(db, now: migratedAt.addingTimeInterval(100), targetVersion: 5)
    #expect(try db.scalarDouble("SELECT retired_at FROM inventory_generations WHERE state='retired'") == 1_000_000.75)
    // A populated legacy inventory is preserved, not silently converted/reset.
    #expect(throws: SQLiteStoreError.self) { try DatabaseMigrator.migrate(db) }
    #expect(try db.scalarInt64("PRAGMA user_version") == 5)
    #expect(try db.scalarInt64("SELECT last_committed_event_id FROM checkpoints") == 123)
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM sqlite_master WHERE name='hybrid_nodes'") == 0)
}

@Test("Schema seven preserves old payloads and adds publication and snapshot accounting")
func dailyFullReportMigration() throws {
    let url = try temporaryDatabaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let db = try SQLiteDatabase(url: url)
    try DatabaseMigrator.migrate(db, targetVersion: 6)
    try db.execute(
        """
        INSERT INTO storage_domains VALUES ('domain','disk-test','Test',1);
        INSERT INTO scan_runs VALUES ('old-run','full','manual','succeeded',1,2,0);
        INSERT INTO daily_reports VALUES ('old-run','domain',2,10,-3,7,0,8,1,X'010203');
        """)
    try DatabaseMigrator.migrate(db)
    #expect(try db.scalarInt64("SELECT snapshot_compared_delta FROM daily_reports") == 0)
    #expect(try db.scalarInt64("SELECT published_at FROM daily_reports") == 2)
    #expect(try db.scalarText("SELECT hex(payload_json) FROM daily_reports") == "010203")
    #expect(try db.scalarInt64("SELECT reconciliation_correction FROM daily_reports") == -3)
    #expect(try db.scalarText("PRAGMA integrity_check") == "ok")
    try DatabaseMigrator.migrate(db)
}
