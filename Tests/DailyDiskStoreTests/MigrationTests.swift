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
    try DatabaseMigrator.migrate(db)
    // Recreate the exact published v2 schema, then exercise its upgrade.
    try db.execute("DROP TRIGGER inventory_generation_cleanup")
    try db.execute("DROP INDEX inventory_paths_parent_object_idx")
    try db.execute("DELETE FROM schema_metadata WHERE version >= 3")
    try db.execute("PRAGMA user_version = 2")
    try db.execute("INSERT INTO settings(key,value,updated_at) VALUES ('migration-sentinel', x'1234', 0)")
    try DatabaseMigrator.migrate(db)
    #expect(try db.scalarInt64("PRAGMA user_version") == Int64(DailyDiskSchema.currentVersion))
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM settings WHERE key='migration-sentinel'") == 1)
    #expect(
        try db.scalarInt64("SELECT COUNT(*) FROM sqlite_master WHERE name = 'inventory_paths_parent_object_idx'") == 1)
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM sqlite_master WHERE name = 'inventory_generation_cleanup'") == 1)
    try DatabaseMigrator.migrate(db)
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM schema_metadata") == Int64(DailyDiskSchema.currentVersion))
}
