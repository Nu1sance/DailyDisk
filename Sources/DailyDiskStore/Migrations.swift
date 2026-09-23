import Foundation

public enum DailyDiskSchema {
    public static let currentVersion = 4
    public static let expectedMigrations: [(version: Int, name: String)] = [
        (1, "initial"),
        (2, "one_full_volume_per_domain"),
        (3, "inventory_path_cascade_index"),
        (4, "generation_cleanup"),
    ]
}

enum DatabaseMigrator {
    private struct Migration {
        let version: Int
        let name: String
        let resourceName: String
    }

    private static let migrations = [
        Migration(version: 1, name: "initial", resourceName: "001_initial"),
        Migration(
            version: 2,
            name: "one_full_volume_per_domain",
            resourceName: "002_one_full_volume_per_domain"
        ),
        Migration(
            version: 3,
            name: "inventory_path_cascade_index",
            resourceName: "003_inventory_path_cascade_index"
        ),
        Migration(version: 4, name: "generation_cleanup", resourceName: "004_generation_cleanup"),
    ]

    static func migrate(_ database: SQLiteDatabase, now: Date = Date()) throws {
        let userVersion = Int(try database.scalarInt64("PRAGMA user_version") ?? 0)
        let hasMetadata =
            try database.scalarInt64(
                """
                SELECT COUNT(*) FROM sqlite_master
                WHERE type = 'table' AND name = 'schema_metadata'
                """
            ) == 1

        let applied = hasMetadata ? try appliedMigrations(database) : []
        let metadataVersion = applied.last?.version ?? 0

        guard userVersion == metadataVersion else {
            throw migrationError("PRAGMA user_version \(userVersion) disagrees with metadata \(metadataVersion)")
        }
        guard metadataVersion <= DailyDiskSchema.currentVersion else {
            throw migrationError(
                "Database schema \(metadataVersion) is newer than supported schema \(DailyDiskSchema.currentVersion)"
            )
        }
        try validateContinuity(applied)

        if !hasMetadata {
            guard userVersion == 0 else {
                throw migrationError("A versioned database is missing schema_metadata")
            }
            try database.execute(
                """
                CREATE TABLE schema_metadata (
                    version INTEGER PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    applied_at REAL NOT NULL
                ) STRICT;
                """
            )
        }

        for migration in migrations where migration.version > metadataVersion {
            let sql = try loadMigration(named: migration.resourceName)
            try database.transaction {
                try database.execute(sql)
                let statement = try database.prepare(
                    "INSERT INTO schema_metadata(version, name, applied_at) VALUES (?, ?, ?)"
                )
                try statement.bind(Int64(migration.version), at: 1)
                try statement.bind(migration.name, at: 2)
                try statement.bind(now.timeIntervalSince1970, at: 3)
                _ = try statement.step()
                try database.execute("PRAGMA user_version = \(migration.version)")
            }
        }
    }

    private static func appliedMigrations(_ database: SQLiteDatabase) throws -> [(version: Int, name: String)] {
        let statement = try database.prepare("SELECT version, name FROM schema_metadata ORDER BY version")
        var result: [(Int, String)] = []
        while try statement.step() {
            guard let name = statement.columnText(1) else {
                throw migrationError("Migration metadata contains a null name")
            }
            result.append((Int(statement.columnInt64(0)), name))
        }
        return result
    }

    private static func validateContinuity(_ applied: [(version: Int, name: String)]) throws {
        for (index, value) in applied.enumerated() {
            let expectedVersion = index + 1
            guard value.version == expectedVersion,
                let known = migrations.first(where: { $0.version == expectedVersion }),
                value.name == known.name
            else {
                throw migrationError("Migration history is missing, divergent, or noncontiguous")
            }
        }
    }

    private static func loadMigration(named baseName: String) throws -> String {
        let packagedBundle = Bundle.main.resourceURL
            .map { $0.appendingPathComponent("DailyDisk_DailyDiskStore.bundle", isDirectory: true) }
            .flatMap(Bundle.init(url:))
        let resourceBundle = packagedBundle ?? Bundle.module
        let candidateURLs = [
            resourceBundle.url(forResource: baseName, withExtension: "sql", subdirectory: "Migrations"),
            resourceBundle.url(forResource: baseName, withExtension: "sql"),
        ]
        guard let url = candidateURLs.compactMap({ $0 }).first else {
            throw migrationError("Missing schema migration \(baseName).sql")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func migrationError(_ message: String) -> SQLiteStoreError {
        SQLiteStoreError(code: -1, message: message)
    }
}
