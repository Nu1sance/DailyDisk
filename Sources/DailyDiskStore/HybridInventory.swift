import DailyDiskCore
import Foundation

/// Batch-scoped compact inventory writer. The owning store supplies the transaction
/// and writer lease; UUID resolution and prepared statements are reused per batch.
final class HybridInventoryWriter {
    let generation: Int64
    let volume: Int64
    private let externalVolume: String
    private let database: SQLiteDatabase
    private let object: SQLiteStatement
    private let membership: SQLiteStatement
    private let order: SQLiteStatement
    private let lookup: SQLiteStatement
    private let insertNode: SQLiteStatement
    private var cache: [Data: Int64] = [:]

    init(database: SQLiteDatabase, generationID: InventoryGeneration.ID, ignoreExisting: Bool = false) throws {
        self.database = database
        let keys = try database.prepare(
            """
            SELECT g.id,g.volume_id,v.external_id FROM hybrid_generations g
            JOIN hybrid_volumes v ON v.id=g.volume_id WHERE g.external_id=?
            """)
        try keys.bind(generationID.rawValue.uuidString, at: 1)
        guard try keys.step(), let externalVolume = keys.columnText(2) else {
            throw StoreInvariantError.corruptStoredValue("hybrid generation mapping")
        }
        generation = keys.columnInt64(0)
        volume = keys.columnInt64(1)
        self.externalVolume = externalVolume
        object = try database.prepare(
            """
            INSERT INTO hybrid_objects VALUES(?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(generation_id,device_id,inode) DO \(ignoreExisting ? "NOTHING" : """
            UPDATE SET kind=excluded.kind,logical_bytes=excluded.logical_bytes,
              allocated_bytes=excluded.allocated_bytes,link_count=excluded.link_count,
              modified_at=excluded.modified_at,metadata_changed_at=excluded.metadata_changed_at
            WHERE hybrid_objects.kind IS NOT excluded.kind
              OR hybrid_objects.logical_bytes IS NOT excluded.logical_bytes
              OR hybrid_objects.allocated_bytes IS NOT excluded.allocated_bytes
              OR hybrid_objects.link_count IS NOT excluded.link_count
              OR hybrid_objects.modified_at IS NOT excluded.modified_at
              OR hybrid_objects.metadata_changed_at IS NOT excluded.metadata_changed_at
            """)
            """)
        membership = try database.prepare(
            """
            INSERT INTO hybrid_paths VALUES(?,?,?,?,?,?)
            ON CONFLICT(generation_id,path_id) DO \(ignoreExisting ? "NOTHING" : """
            UPDATE SET device_id=excluded.device_id,inode=excluded.inode,classification=excluded.classification
            """)
            """)
        order = try database.prepare(
            """
            INSERT INTO hybrid_order VALUES(?,?,?)
            ON CONFLICT(generation_id,path) DO UPDATE SET
              path_id=CASE WHEN hybrid_order.path_id=excluded.path_id THEN excluded.path_id ELSE NULL END
            WHERE hybrid_order.path_id IS NOT excluded.path_id
            """)
        lookup = try database.prepare("SELECT id FROM hybrid_nodes WHERE COALESCE(parent_id,0)=? AND name=?")
        insertNode = try database.prepare("INSERT INTO hybrid_nodes(parent_id,name) VALUES(?,?)")
    }

    @discardableResult
    func write(_ record: InventoryRecord) throws -> Bool {
        guard record.path.volumeID.rawValue == externalVolume,
            record.object.identity.volumeID.rawValue == externalVolume
        else { throw StoreInvariantError.volumeMismatch }
        // No cache survives a failed write/transaction, including rolled-back node IDs.
        do {
            let node = try intern(record.path.relativePath.bytes)
            defer {
                try? object.reset()
                try? membership.reset()
                try? order.reset()
            }
            try writeObject(record.object)
            try membership.bind(generation, at: 1)
            try membership.bind(volume, at: 2)
            try membership.bind(node, at: 3)
            try membership.bind(Int64(bitPattern: record.path.objectIdentity.deviceID), at: 4)
            try membership.bind(Int64(bitPattern: record.path.objectIdentity.inode), at: 5)
            try membership.bind(record.path.classification.rawValue, at: 6)
            _ = try membership.step()
            let changed = database.changes == 1
            try order.bind(generation, at: 1)
            try order.bind(record.path.relativePath.bytes, at: 2)
            try order.bind(node, at: 3)
            _ = try order.step()
            return changed
        } catch {
            cache.removeAll(keepingCapacity: true)
            throw error
        }
    }

    func writeObject(_ value: InventoryObject) throws {
        guard value.identity.volumeID.rawValue == externalVolume else { throw StoreInvariantError.volumeMismatch }
        defer { try? object.reset() }
        try object.bind(generation, at: 1)
        try object.bind(volume, at: 2)
        try object.bind(Int64(bitPattern: value.identity.deviceID), at: 3)
        try object.bind(Int64(bitPattern: value.identity.inode), at: 4)
        try object.bind(value.kind.rawValue, at: 5)
        try object.bind(value.footprint.logicalBytes, at: 6)
        try object.bind(value.footprint.allocatedBytes, at: 7)
        try object.bind(Int64(bitPattern: value.linkCount), at: 8)
        try object.bind(value.modifiedAt?.timeIntervalSince1970, at: 9)
        try object.bind(value.metadataChangedAt?.timeIntervalSince1970, at: 10)
        _ = try object.step()
    }

    private func intern(_ path: Data) throws -> Int64 {
        // Bound retained prefixes even when a caller writes more than one scanner batch.
        if cache.count > 8192 { cache.removeAll(keepingCapacity: true) }
        if let id = cache[path] { return id }
        var parent: Int64?
        var prefix = Data()
        let components: [Data] = path.isEmpty ? [Data()] : path.split(separator: UInt8(47)).map { Data($0) }
        for (index, name) in components.enumerated() {
            if index > 0 { prefix.append(47) }
            prefix.append(name)
            if let cached = cache[prefix] {
                parent = cached
                continue
            }
            let id: Int64
            do {
                defer { try? lookup.reset() }
                try lookup.bind(parent ?? 0, at: 1)
                try lookup.bind(name, at: 2)
                if try lookup.step() {
                    id = lookup.columnInt64(0)
                } else {
                    defer { try? insertNode.reset() }
                    try insertNode.bind(parent, at: 1)
                    try insertNode.bind(name, at: 2)
                    _ = try insertNode.step()
                    id = database.lastInsertedRowID
                }
            }
            cache[prefix] = id
            parent = id
        }
        return parent!
    }
}

extension SQLiteDatabase {
    func hybridGenerationKey(_ id: InventoryGeneration.ID) throws -> Int64 {
        let query = try prepare("SELECT id FROM hybrid_generations WHERE external_id=?")
        try query.bind(id.rawValue.uuidString, at: 1)
        guard try query.step() else { throw StoreInvariantError.corruptStoredValue("hybrid generation mapping") }
        return query.columnInt64(0)
    }

    /// Full seal/explicit audit, or identity-bounded incremental seal; never GUI polling.
    func verifyHybridOrdering(generation: Int64? = nil, identity: FileIdentity? = nil) throws -> Int {
        let generationFilter = generation.map { " AND p.generation_id=\($0)" } ?? ""
        let identityFilter =
            identity.map {
                " AND p.device_id=\(Int64(bitPattern: $0.deviceID)) AND p.inode=\(Int64(bitPattern: $0.inode))"
            } ?? ""
        let missing =
            try scalarInt64(
                """
                SELECT COUNT(*) FROM hybrid_paths p LEFT JOIN hybrid_order d
                  ON d.generation_id=p.generation_id AND d.path_id=p.path_id WHERE d.path_id IS NULL \(generationFilter) \(identityFilter)
                """) ?? 0
        if missing > 0 { return Int(missing) }
        let nodes = try prepare("SELECT parent_id,name FROM hybrid_nodes WHERE id=?")
        // Audit one generation at a time to retain only a bounded ancestor cache.
        let generations = try prepare(
            "SELECT id FROM hybrid_generations \(generation.map { "WHERE id=\($0)" } ?? "") ORDER BY id")
        var violations = 0
        while try generations.step() {
            let generation = generations.columnInt64(0)
            var after: Int64 = 0
            while true {
                let batch = try prepare(
                    """
                    SELECT p.path_id,d.path FROM hybrid_paths p LEFT JOIN hybrid_order d
                      ON d.generation_id=p.generation_id AND d.path_id=p.path_id
                    WHERE p.generation_id=? AND p.path_id>? \(identityFilter) ORDER BY p.path_id LIMIT 512
                    """)
                try batch.bind(generation, at: 1)
                try batch.bind(after, at: 2)
                var cache: [Int64: Data] = [:]
                var count = 0
                while try batch.step() {
                    count += 1
                    after = batch.columnInt64(0)
                    var chain: [(Int64, Data)] = []
                    var seen: Set<Int64> = []
                    var current: Int64? = after
                    while let id = current, cache[id] == nil {
                        guard seen.insert(id).inserted else { return violations + 1 }
                        try nodes.reset()
                        try nodes.bind(id, at: 1)
                        guard try nodes.step(), let name = nodes.columnData(1) else { return violations + 1 }
                        chain.append((id, name))
                        current = nodes.columnIsNull(0) ? nil : nodes.columnInt64(0)
                    }
                    var path = current.flatMap { cache[$0] }
                    for (id, name) in chain.reversed() {
                        path = path.map { $0 + Data([47]) + name } ?? name
                        cache[id] = path!
                    }
                    if batch.columnData(1) != cache[after] { violations += 1 }
                }
                if count == 0 { break }
            }
        }
        return violations
    }

    /// Idle maintenance; run overlays contain raw paths and hold no node IDs.
    func collectHybridNodes() throws {
        defer {
            try? execute(
                "DROP TABLE IF EXISTS hybrid_gc_deleted; DROP TABLE IF EXISTS hybrid_gc_batch; DROP TABLE IF EXISTS hybrid_gc_queue;"
            )
        }
        try execute(
            """
            CREATE TEMP TABLE hybrid_gc_queue(id INTEGER PRIMARY KEY);
            CREATE TEMP TABLE hybrid_gc_batch(id INTEGER PRIMARY KEY);
            CREATE TEMP TABLE hybrid_gc_deleted(id INTEGER PRIMARY KEY,parent_id INTEGER);
            INSERT INTO hybrid_gc_queue SELECT d.id FROM hybrid_nodes d
            WHERE NOT EXISTS(SELECT 1 FROM hybrid_paths p WHERE p.path_id=d.id)
              AND NOT EXISTS(SELECT 1 FROM hybrid_nodes c WHERE c.parent_id=d.id);
            """)
        while try scalarInt64("SELECT id FROM hybrid_gc_queue LIMIT 1") != nil {
            try transaction {
                try execute(
                    """
                    DELETE FROM hybrid_gc_batch; DELETE FROM hybrid_gc_deleted;
                    INSERT INTO hybrid_gc_batch SELECT id FROM hybrid_gc_queue ORDER BY id LIMIT 1024;
                    DELETE FROM hybrid_gc_queue WHERE id IN (SELECT id FROM hybrid_gc_batch);
                    INSERT INTO hybrid_gc_deleted SELECT d.id,d.parent_id
                      FROM hybrid_gc_batch b CROSS JOIN hybrid_nodes d ON d.id=b.id
                      WHERE NOT EXISTS(SELECT 1 FROM hybrid_paths p WHERE p.path_id=d.id)
                        AND NOT EXISTS(SELECT 1 FROM hybrid_nodes c WHERE c.parent_id=d.id);
                    DELETE FROM hybrid_nodes WHERE id IN (SELECT id FROM hybrid_gc_deleted);
                    INSERT OR IGNORE INTO hybrid_gc_queue
                      SELECT parent_id FROM hybrid_gc_deleted WHERE parent_id IS NOT NULL;
                    """)
            }
        }
    }
}
