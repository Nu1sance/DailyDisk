import CSQLite
import DailyDiskCore
import Darwin
import Foundation

@testable import DailyDiskStore

/// Experimental hot-inventory layouts only. Never used by a production writer or migration.
enum StorageLayout: String, CaseIterable {
    case uuidPaths, integerPaths, sharedPaths, treePaths, treeOrdered

    var shared: Bool { self == .sharedPaths || tree }
    var tree: Bool { self == .treePaths || self == .treeOrdered }
    var keyType: String { self == .uuidPaths ? "TEXT" : "INTEGER" }
    func key(_ value: Int) -> String {
        self == .uuidPaths ? "'\(externalID(value))'" : String(value)
    }
    func externalID(_ value: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012d", value)
    }
}

struct LayoutRecord: Equatable {
    let path: Data
    let inode: Int64
    var allocated: Int64 = 4096
    var classification = "ordinary"
    var device: Int64 = 1
    var links: Int64 = 1

    var parent: Data? {
        guard let slash = path.lastIndex(of: 47) else { return nil }
        return Data(path[..<slash])
    }
}

final class StorageLayoutPrototype {
    let layout: StorageLayout
    let database: SQLiteDatabase
    let url: URL
    private var dictionaryCache: [Data: Int64] = [:]
    private var dictionaryLookup: SQLiteStatement?
    private var dictionaryInsertion: SQLiteStatement?

    init(url: URL, layout: StorageLayout) throws {
        self.url = url
        self.layout = layout
        database = try SQLiteDatabase(url: url)
        let key = layout.keyType
        let path = layout.shared ? "path_id" : "path"
        let pathType = layout.shared ? "INTEGER REFERENCES path_dictionary(id) ON DELETE RESTRICT" : "BLOB"
        let parent = layout.shared ? "" : ", parent_path BLOB"
        try database.execute(
            """
            CREATE TABLE volumes(id \(key) PRIMARY KEY NOT NULL, external_uuid TEXT NOT NULL UNIQUE) STRICT;
            CREATE TABLE inventory_generations(
                id \(key) PRIMARY KEY NOT NULL, volume_id \(key) NOT NULL REFERENCES volumes(id),
                external_uuid TEXT NOT NULL UNIQUE, state TEXT NOT NULL DEFAULT 'staging',
                UNIQUE(id,volume_id)) STRICT;
            CREATE TABLE checkpoints(
                volume_id \(key) PRIMARY KEY NOT NULL, active_generation_id \(key) NOT NULL, event_id INTEGER NOT NULL,
                FOREIGN KEY(active_generation_id,volume_id) REFERENCES inventory_generations(id,volume_id) ON DELETE RESTRICT
            ) STRICT;
            """)
        if layout.shared {
            try database.execute(
                """
                CREATE TABLE path_dictionary(
                    id INTEGER PRIMARY KEY, \(layout.tree ? "name BLOB NOT NULL" : "path BLOB NOT NULL UNIQUE"),
                    parent_id INTEGER REFERENCES path_dictionary(id) ON DELETE RESTRICT) STRICT;
                CREATE INDEX dictionary_parent_idx ON path_dictionary(parent_id);
                \(layout.tree ? "CREATE UNIQUE INDEX node_name_idx ON path_dictionary(COALESCE(parent_id,0),name);" : "")
                CREATE TABLE overlay_path_refs(
                    run_id TEXT NOT NULL, path_id INTEGER NOT NULL REFERENCES path_dictionary(id) ON DELETE RESTRICT,
                    PRIMARY KEY(run_id,path_id)) STRICT, WITHOUT ROWID;
                CREATE INDEX overlay_dictionary_idx ON overlay_path_refs(path_id);
                """)
        }
        // Match all hot inventory columns, identity constraints and indexes in schema 5.
        // Catalogs, reports and full overlays are deliberately outside this experiment.
        try database.execute(
            """
            CREATE TABLE inventory_objects(
                generation_id \(key) NOT NULL REFERENCES inventory_generations(id) ON DELETE CASCADE,
                volume_id \(key) NOT NULL REFERENCES volumes(id), device_id INTEGER NOT NULL, inode INTEGER NOT NULL,
                kind TEXT NOT NULL, logical_bytes INTEGER NOT NULL CHECK(logical_bytes>=0),
                allocated_bytes INTEGER NOT NULL CHECK(allocated_bytes>=0), link_count INTEGER NOT NULL,
                modified_at REAL, metadata_changed_at REAL,
                PRIMARY KEY(generation_id,device_id,inode), UNIQUE(generation_id,volume_id,device_id,inode),
                FOREIGN KEY(generation_id,volume_id) REFERENCES inventory_generations(id,volume_id) ON DELETE CASCADE
            ) STRICT, WITHOUT ROWID;
            CREATE TABLE inventory_paths(
                generation_id \(key) NOT NULL, volume_id \(key) NOT NULL REFERENCES volumes(id),
                \(path) \(pathType) NOT NULL \(parent), device_id INTEGER NOT NULL, inode INTEGER NOT NULL,
                classification TEXT NOT NULL CHECK(classification IN ('ordinary','dailyDiskInternal')),
                PRIMARY KEY(generation_id,\(path)), UNIQUE(generation_id,volume_id,\(path),device_id,inode),
                FOREIGN KEY(generation_id,volume_id,device_id,inode)
                    REFERENCES inventory_objects(generation_id,volume_id,device_id,inode) ON DELETE CASCADE
            ) STRICT, WITHOUT ROWID;
            CREATE INDEX inventory_paths_object_idx ON inventory_paths(generation_id,device_id,inode,\(path));
            CREATE INDEX inventory_paths_parent_object_idx ON inventory_paths(generation_id,volume_id,device_id,inode);
            CREATE TABLE canonical_attributions(
                generation_id \(key) NOT NULL REFERENCES inventory_generations(id) ON DELETE CASCADE,
                volume_id \(key) NOT NULL REFERENCES volumes(id), device_id INTEGER NOT NULL, inode INTEGER NOT NULL,
                \(path) \(layout.shared ? "INTEGER" : "BLOB") NOT NULL,
                classification TEXT NOT NULL CHECK(classification IN ('ordinary','dailyDiskInternal')),
                PRIMARY KEY(generation_id,device_id,inode),
                FOREIGN KEY(generation_id,volume_id,\(path),device_id,inode)
                    REFERENCES inventory_paths(generation_id,volume_id,\(path),device_id,inode) ON DELETE CASCADE
            ) STRICT, WITHOUT ROWID;
            CREATE TRIGGER inventory_generation_cleanup BEFORE DELETE ON inventory_generations BEGIN
                DELETE FROM canonical_attributions WHERE generation_id=OLD.id;
                DELETE FROM inventory_paths WHERE generation_id=OLD.id;
                DELETE FROM inventory_objects WHERE generation_id=OLD.id;
            END;
            INSERT INTO volumes VALUES(\(layout.key(1)), '\(layout.externalID(1))');
            """)
        if layout == .treeOrdered {
            try database.execute(
                """
                CREATE TABLE path_order(
                    generation_id INTEGER NOT NULL, path BLOB NOT NULL, path_id INTEGER NOT NULL,
                    PRIMARY KEY(generation_id,path), UNIQUE(generation_id,path_id),
                    FOREIGN KEY(generation_id,path_id) REFERENCES inventory_paths(generation_id,path_id) ON DELETE CASCADE
                ) STRICT, WITHOUT ROWID;
                """)
        }
        if layout.shared {
            try database.execute("CREATE INDEX paths_dictionary_idx ON inventory_paths(path_id)")
            dictionaryLookup = try database.prepare(
                layout.tree
                    ? "SELECT id FROM path_dictionary WHERE COALESCE(parent_id,0)=? AND name=?"
                    : "SELECT id FROM path_dictionary WHERE path=?")
            dictionaryInsertion = try database.prepare(
                "INSERT INTO path_dictionary(\(layout.tree ? "name" : "path"),parent_id) VALUES(?,?)")
        }
    }

    func addGeneration(_ generation: Int) throws {
        try database.execute(
            """
            INSERT INTO inventory_generations(id,volume_id,external_uuid)
            VALUES(\(layout.key(generation)),\(layout.key(1)),'\(layout.externalID(generation))')
            """)
    }

    func activate(_ generation: Int, eventID: Int = 10) throws {
        try database.transaction {
            try database.execute("UPDATE inventory_generations SET state='retired' WHERE state='active'")
            try database.execute("UPDATE inventory_generations SET state='active' WHERE id=\(layout.key(generation))")
            try database.execute(
                """
                INSERT INTO checkpoints VALUES(\(layout.key(1)),\(layout.key(generation)),\(eventID))
                ON CONFLICT(volume_id) DO UPDATE SET active_generation_id=excluded.active_generation_id,event_id=excluded.event_id
                """)
        }
    }

    func append(_ records: [LayoutRecord], generation: Int, inTransaction: Bool = false) throws {
        precondition(records.count <= 1024)
        dictionaryCache.removeAll(keepingCapacity: true)
        defer { dictionaryCache.removeAll(keepingCapacity: true) }
        let write = { [self] in
            let object = try database.prepare(
                """
                INSERT INTO inventory_objects VALUES(\(layout.key(generation)),\(layout.key(1)),?,?,'regular',?,?,?,0.75,1.75)
                ON CONFLICT(generation_id,device_id,inode) DO UPDATE SET
                    allocated_bytes=excluded.allocated_bytes, logical_bytes=excluded.logical_bytes, link_count=excluded.link_count
                """)
            let path = try database.prepare(
                """
                INSERT INTO inventory_paths VALUES(\(layout.key(generation)),\(layout.key(1)),?\(layout.shared ? "" : ",?"),?,?,?)
                ON CONFLICT(generation_id,\(layout.shared ? "path_id" : "path")) DO UPDATE SET
                    device_id=excluded.device_id,inode=excluded.inode,classification=excluded.classification
                """)
            let ordered =
                layout == .treeOrdered
                ? try database.prepare(
                    "INSERT OR IGNORE INTO path_order VALUES(\(generation),?,?)") : nil
            for record in records {
                try object.bind(record.device, at: 1)
                try object.bind(record.inode, at: 2)
                try object.bind(record.allocated, at: 3)
                try object.bind(record.allocated, at: 4)
                try object.bind(record.links, at: 5)
                _ = try object.step()
                try object.reset()
                if layout.shared {
                    try path.bind(intern(record.path), at: 1)
                } else {
                    try path.bind(record.path, at: 1)
                    try path.bind(record.parent, at: 2)
                }
                let offset: Int32 = layout.shared ? 1 : 2
                try path.bind(record.device, at: offset + 1)
                try path.bind(record.inode, at: offset + 2)
                try path.bind(record.classification, at: offset + 3)
                _ = try path.step()
                try path.reset()
                if let ordered {
                    try ordered.bind(record.path, at: 1)
                    try ordered.bind(intern(record.path), at: 2)
                    _ = try ordered.step()
                    try ordered.reset()
                }
            }
        }
        if inTransaction { try write() } else { try database.transaction(write) }
    }

    func intern(_ path: Data) throws -> Int64 {
        if let id = dictionaryCache[path] { return id }
        if layout.tree { return try internTree(path) }
        let lookup = dictionaryLookup!
        // sqlite3_reset also restores a statement after sqlite3_step fails;
        // its return may repeat that failure, so preserve the original error.
        defer { try? lookup.reset() }
        try lookup.bind(path, at: 1)
        if try lookup.step() {
            let id = lookup.columnInt64(0)
            try lookup.reset()
            dictionaryCache[path] = id
            return id
        }
        try lookup.reset()
        let parent = LayoutRecord(path: path, inode: 0).parent
        let parentID = try parent.map { try intern($0) }
        let insertion = dictionaryInsertion!
        defer { try? insertion.reset() }
        try insertion.bind(path, at: 1)
        try insertion.bind(parentID, at: 2)
        _ = try insertion.step()
        let id = database.lastInsertedRowID
        try insertion.reset()
        dictionaryCache[path] = id
        return id
    }

    // Nodes describe immutable path components, never filesystem object identities.
    // Each batch caches at most its own paths/ancestors; no inventory-sized cache.
    private func internTree(_ path: Data) throws -> Int64 {
        let parent = LayoutRecord(path: path, inode: 0).parent
        let parentID = try parent.map { try intern($0) }
        let name = parent.map { Data(path.dropFirst($0.count + 1)) } ?? path
        let lookup = dictionaryLookup!
        defer { try? lookup.reset() }
        try lookup.bind(parentID ?? 0, at: 1)
        try lookup.bind(name, at: 2)
        if try lookup.step() {
            let id = lookup.columnInt64(0)
            try lookup.reset()
            dictionaryCache[path] = id
            return id
        }
        try lookup.reset()
        let insertion = dictionaryInsertion!
        defer { try? insertion.reset() }
        try insertion.bind(name, at: 1)
        try insertion.bind(parentID, at: 2)
        _ = try insertion.step()
        let id = database.lastInsertedRowID
        try insertion.reset()
        dictionaryCache[path] = id
        return id
    }

    /// Generation-local upward reconstruction: avoids visiting unrelated generations,
    /// but still reconstructs every member before a raw-path range can be sorted.
    func reconstructedPaths(generation: Int) -> String {
        """
        WITH RECURSIVE ancestors(path_id,parent_id,path) AS (
            SELECT d.id,d.parent_id,d.name FROM inventory_paths p
            CROSS JOIN path_dictionary d ON d.id=p.path_id WHERE p.generation_id=\(generation)
            UNION ALL
            SELECT a.path_id,d.parent_id,CAST(d.name || x'2f' || a.path AS BLOB)
            FROM ancestors a JOIN path_dictionary d ON d.id=a.parent_id
        ), resolved AS (SELECT path_id,path FROM ancestors WHERE parent_id IS NULL)
        """
    }

    func canonicalPaths(generation: Int) throws -> [Data] {
        let sql: String
        if layout == .treePaths {
            sql =
                reconstructedPaths(generation: generation) + """
                    SELECT d.path FROM canonical_attributions c JOIN resolved d ON d.path_id=c.path_id
                    WHERE c.generation_id=\(generation) ORDER BY d.path
                    """
        } else if layout == .treeOrdered {
            sql = """
                SELECT d.path FROM canonical_attributions c JOIN path_order d
                ON d.generation_id=c.generation_id AND d.path_id=c.path_id
                WHERE c.generation_id=\(generation) ORDER BY d.path
                """
        } else {
            sql =
                layout.shared
                ? "SELECT d.path FROM canonical_attributions c JOIN path_dictionary d ON d.id=c.path_id WHERE c.generation_id=\(generation) ORDER BY d.path"
                : "SELECT path FROM canonical_attributions WHERE generation_id=\(layout.key(generation)) ORDER BY path"
        }
        let query = try database.prepare(sql)
        var result: [Data] = []
        while try query.step() { result.append(query.columnData(0)!) }
        return result
    }

    var canonicalCandidateSQL: String {
        let key = layout.shared ? "path_id" : "path"
        let source =
            layout == .treeOrdered
            ? "CROSS JOIN path_order d ON d.generation_id=q.generation_id AND d.path_id=q.path_id"
            : (layout.shared ? "JOIN path_dictionary d ON d.id=q.path_id" : "")
        let ordering = layout.shared ? "d.path" : "q.path"
        return """
            SELECT q.\(key) FROM inventory_paths q \(source)
            WHERE q.generation_id=o.generation_id AND q.device_id=o.device_id AND q.inode=o.inode
            ORDER BY \(ordering) LIMIT 1
            """
    }

    func seal(_ generation: Int) throws {
        let key = layout.shared ? "path_id" : "path"
        if layout == .treePaths {
            try database.transaction {
                try clearCanonical(generation)
                try database.execute(
                    reconstructedPaths(generation: generation) + """
                        INSERT INTO canonical_attributions
                        SELECT generation_id,volume_id,device_id,inode,path_id,classification FROM (
                            SELECT p.*,ROW_NUMBER() OVER (
                                PARTITION BY p.device_id,p.inode ORDER BY d.path) AS position
                            FROM resolved d JOIN inventory_paths p
                              ON p.generation_id=\(generation) AND p.path_id=d.path_id
                        ) WHERE position=1
                        """)
            }
            return
        }
        try database.transaction {
            try clearCanonical(generation)
            try database.execute(
                """
                INSERT INTO canonical_attributions
                SELECT p.generation_id,p.volume_id,p.device_id,p.inode,p.\(key),p.classification
                FROM inventory_objects o CROSS JOIN inventory_paths p
                WHERE o.generation_id=\(layout.key(generation)) AND p.generation_id=o.generation_id
                  AND p.\(key)=(\(canonicalCandidateSQL))
                """)
        }
    }

    func clearCanonical(_ generation: Int) throws {
        try database.execute("DELETE FROM canonical_attributions WHERE generation_id=\(layout.key(generation))")
    }

    /// This is deliberately the simplest dictionary-driven ordered pager. The
    /// sparse-generation experiment measures its extra work, not just its LIMIT.
    func pageSQL(generation: Int) -> String {
        if layout.tree {
            let prefix = layout == .treePaths ? reconstructedPaths(generation: generation) : ""
            let source = layout == .treePaths ? "resolved d" : "path_order d"
            let filter = layout == .treeOrdered ? "d.generation_id=\(generation) AND " : ""
            return prefix + """
                SELECT d.path,p.device_id,p.inode,o.allocated_bytes,p.classification,o.link_count
                FROM \(source) CROSS JOIN inventory_paths p
                  ON p.generation_id=\(generation) AND p.path_id=d.path_id
                CROSS JOIN inventory_objects o
                  ON o.generation_id=p.generation_id AND o.device_id=p.device_id AND o.inode=p.inode
                WHERE \(filter)d.path>? AND d.path<? ORDER BY d.path LIMIT ?
                """
        }
        let source =
            layout.shared
            ? "path_dictionary d CROSS JOIN inventory_paths p ON p.path_id=d.id"
            : "inventory_paths p"
        let path = layout.shared ? "d.path" : "p.path"
        return """
            SELECT \(path),p.device_id,p.inode,o.allocated_bytes,p.classification,o.link_count
            FROM \(source) CROSS JOIN inventory_objects o
              ON o.generation_id=p.generation_id AND o.device_id=p.device_id AND o.inode=p.inode
            WHERE p.generation_id=\(layout.key(generation)) AND \(path)>? AND \(path)<?
            ORDER BY \(path) LIMIT ?
            """
    }

    func page(generation: Int, after: Data, before: Data, limit: Int = 128) throws -> [LayoutRecord] {
        let query = try database.prepare(pageSQL(generation: generation))
        try query.bind(after, at: 1)
        try query.bind(before, at: 2)
        try query.bind(Int64(limit), at: 3)
        var records: [LayoutRecord] = []
        while try query.step() {
            records.append(
                LayoutRecord(
                    path: query.columnData(0)!, inode: query.columnInt64(2), allocated: query.columnInt64(3),
                    classification: query.columnText(4)!, device: query.columnInt64(1), links: query.columnInt64(5)))
        }
        return records
    }

    func plan(generation: Int, lower: Data, upper: Data) throws -> [String] {
        let query = try database.prepare("EXPLAIN QUERY PLAN " + pageSQL(generation: generation))
        try query.bind(lower, at: 1)
        try query.bind(upper, at: 2)
        try query.bind(Int64(128), at: 3)
        var result: [String] = []
        while try query.step() { result.append(query.columnText(3)!) }
        return result
    }

    func deleteGeneration(_ generation: Int) throws {
        try database.transaction {
            try database.execute("DELETE FROM inventory_generations WHERE id=\(layout.key(generation))")
        }
    }

    func remove(_ path: Data, generation: Int) throws {
        var nodeID: Int64?
        if layout.tree {
            var parent: Int64 = 0
            for component in path.split(separator: 47, omittingEmptySubsequences: false) {
                let lookup = dictionaryLookup!
                try lookup.bind(parent, at: 1)
                try lookup.bind(Data(component), at: 2)
                guard try lookup.step() else {
                    try lookup.reset()
                    return
                }
                parent = lookup.columnInt64(0)
                try lookup.reset()
            }
            nodeID = parent
        }
        let predicate =
            layout.tree
            ? "path_id=?"
            : (layout.shared ? "path_id=(SELECT id FROM path_dictionary WHERE path=?)" : "path=?")
        let identity = try database.prepare(
            "SELECT device_id,inode FROM inventory_paths WHERE generation_id=\(layout.key(generation)) AND \(predicate)"
        )
        if let nodeID { try identity.bind(nodeID, at: 1) } else { try identity.bind(path, at: 1) }
        guard try identity.step() else { return }
        let device = identity.columnInt64(0)
        let inode = identity.columnInt64(1)
        try identity.reset()
        let query = try database.prepare(
            "DELETE FROM inventory_paths WHERE generation_id=\(layout.key(generation)) AND \(predicate)")
        if let nodeID { try query.bind(nodeID, at: 1) } else { try query.bind(path, at: 1) }
        _ = try query.step()
        try database.execute(
            """
            DELETE FROM inventory_objects WHERE generation_id=\(layout.key(generation))
              AND device_id=\(device) AND inode=\(inode) AND NOT EXISTS(
                SELECT 1 FROM inventory_paths p WHERE p.generation_id=inventory_objects.generation_id
                  AND p.device_id=inventory_objects.device_id AND p.inode=inventory_objects.inode)
            """)
    }

    func collectDictionary(afterBatch: () throws -> Void = {}) throws -> Int {
        guard layout.shared else { return 0 }
        dictionaryCache.removeAll()
        // Seed leaves once. Deleting a child only makes its own parent a new
        // candidate; do not sweep every surviving node again for each depth.
        try database.execute(
            """
            CREATE TEMP TABLE gc_queue(id INTEGER PRIMARY KEY);
            CREATE TEMP TABLE gc_batch(id INTEGER PRIMARY KEY);
            CREATE TEMP TABLE gc_deleted(id INTEGER PRIMARY KEY,parent_id INTEGER);
            """)
        defer {
            try? database.execute("DROP TABLE gc_deleted; DROP TABLE gc_batch; DROP TABLE gc_queue;")
        }
        try database.execute(
            """
            INSERT INTO gc_queue SELECT d.id FROM path_dictionary d
              WHERE NOT EXISTS(SELECT 1 FROM inventory_paths p WHERE p.path_id=d.id)
                AND NOT EXISTS(SELECT 1 FROM overlay_path_refs r WHERE r.path_id=d.id)
                AND NOT EXISTS(SELECT 1 FROM path_dictionary c WHERE c.parent_id=d.id);
            """)
        var total = 0
        while try database.scalarInt64("SELECT id FROM gc_queue LIMIT 1") != nil {
            try database.transaction {
                try database.execute(
                    """
                    DELETE FROM gc_batch;
                    DELETE FROM gc_deleted;
                    INSERT INTO gc_batch SELECT id FROM gc_queue ORDER BY id LIMIT 1024;
                    DELETE FROM gc_queue WHERE id IN (SELECT id FROM gc_batch);
                    INSERT INTO gc_deleted
                      SELECT d.id,d.parent_id FROM gc_batch b CROSS JOIN path_dictionary d ON d.id=b.id
                      WHERE NOT EXISTS(SELECT 1 FROM inventory_paths p WHERE p.path_id=d.id)
                        AND NOT EXISTS(SELECT 1 FROM overlay_path_refs r WHERE r.path_id=d.id)
                        AND NOT EXISTS(SELECT 1 FROM path_dictionary c WHERE c.parent_id=d.id);
                    DELETE FROM path_dictionary WHERE id IN (SELECT id FROM gc_deleted);
                    """)
                total += database.changes
                try database.execute(
                    """
                    INSERT OR IGNORE INTO gc_queue
                      SELECT parent_id FROM gc_deleted WHERE parent_id IS NOT NULL;
                    """)
            }
            try afterBatch()
        }
        return total
    }

    func compactBytes() throws -> Int64 {
        try database.execute("VACUUM")
        try database.checkpointWAL()
        return try database.scalarInt64("PRAGMA page_count")! * database.scalarInt64("PRAGMA page_size")!
    }

    /// SQLite VM steps expose work hidden by LIMIT even on a fast/warm machine.
    func pageWork(generation: Int, lower: Data, upper: Data) throws -> (rows: Int, steps: Int32) {
        try database.checkpointWAL()
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            throw LayoutExperimentError.sqlite
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, pageSQL(generation: generation), -1, &statement, nil) == SQLITE_OK else {
            throw LayoutExperimentError.sqlite
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in [lower, upper].enumerated() {
            let code: Int32
            if value.isEmpty {
                code = sqlite3_bind_zeroblob(statement, Int32(index + 1), 0)
            } else {
                code = value.withUnsafeBytes {
                    sqlite3_bind_blob(statement, Int32(index + 1), $0.baseAddress, Int32(value.count), transient)
                }
            }
            guard code == SQLITE_OK else { throw LayoutExperimentError.sqlite }
        }
        guard sqlite3_bind_int(statement, 3, 128) == SQLITE_OK else { throw LayoutExperimentError.sqlite }
        var rows = 0
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            rows += 1
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw LayoutExperimentError.sqlite }
        return (rows, sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0))
    }
}

enum LayoutExperimentError: Error { case sqlite, rollback }

/// The serial queue owns both phase and samples. Only file allocation is read;
/// SQLite statements/connections never cross into the sampling queue.
final class LayoutAllocationSampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "DailyDisk.LayoutAllocationSampler")
    private let timer: DispatchSourceTimer
    private let paths: [String]
    private var phase = "setup"
    private var peaks: [String: Int64] = [:]

    init(url: URL) {
        paths = [url.path, url.path + "-wal", url.path + "-shm"]
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
    }

    func setPhase(_ value: String) {
        queue.sync {
            sample()
            phase = value
            sample()
        }
    }

    func finish() -> [String: Int64] {
        timer.cancel()
        return queue.sync {
            sample()
            return peaks
        }
    }

    private func sample() {
        let allocated = paths.reduce(Int64(0)) { result, path in
            var metadata = stat()
            return result + (lstat(path, &metadata) == 0 ? Int64(metadata.st_blocks) * 512 : 0)
        }
        peaks[phase] = max(peaks[phase, default: 0], allocated)
    }
}
