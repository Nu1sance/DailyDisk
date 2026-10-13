import DailyDiskCore
import Foundation

/// Confined to the inventory-store actor. Small rescans stay in memory; large
/// rescans spill only raw path keys to a private, disposable database.
final class SubtreeSeenPaths: @unchecked Sendable {
    private var memory = Set<RelativePath>()
    private var memoryBytes = 0
    private var directory: URL?
    private var database: SQLiteDatabase?
    private var insertion: SQLiteStatement?
    private var lookup: SQLiteStatement?

    deinit {
        insertion = nil
        lookup = nil
        database = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func insert(_ path: RelativePath) throws {
        if database == nil {
            if memory.insert(path).inserted { memoryBytes += path.bytes.count }
            guard memory.count > 4096 || memoryBytes > 1_048_576 else { return }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("DailyDisk.SubtreeSeen.\(UUID().uuidString)")
            self.directory = directory
            let db = try SQLiteDatabase(url: directory.appendingPathComponent("seen.sqlite"))
            database = db
            try db.execute("CREATE TABLE seen(path BLOB PRIMARY KEY) WITHOUT ROWID; BEGIN IMMEDIATE;")
            insertion = try db.prepare("INSERT OR IGNORE INTO seen(path) VALUES (?)")
            lookup = try db.prepare("SELECT 1 FROM seen WHERE path=?")
            for value in memory { try insertDisk(value) }
            memory.removeAll(keepingCapacity: false)
            memoryBytes = 0
        } else {
            try insertDisk(path)
        }
    }

    private func insertDisk(_ path: RelativePath) throws {
        guard let statement = insertion else { return }
        try statement.bind(path.bytes, at: 1)
        _ = try statement.step()
        try statement.reset()
    }

    func contains(_ path: RelativePath) throws -> Bool {
        guard let statement = lookup else { return memory.contains(path) }
        try statement.bind(path.bytes, at: 1)
        let found = try statement.step()
        try statement.reset()
        return found
    }
}
