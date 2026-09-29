import Foundation

@testable import DailyDiskStore

/// Test adapter for the hybrid candidate; not a production run/ledger/fence implementation.
/// Overlay paths remain raw bytes, as in the existing production overlay.
final class HybridTreeExperiment {
    let store: StorageLayoutPrototype
    let generation: Int
    let run: Int
    var database: SQLiteDatabase { store.database }

    init(store: StorageLayoutPrototype, generation: Int, run: Int = 1) throws {
        precondition(store.layout == .treeOrdered)
        self.store = store
        self.generation = generation
        self.run = run
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS experiment_mutations(
                run INTEGER NOT NULL, generation INTEGER NOT NULL REFERENCES inventory_generations(id),
                path BLOB NOT NULL, device INTEGER, inode INTEGER, classification TEXT,
                PRIMARY KEY(run,generation,path)) STRICT, WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS experiment_objects(
                run INTEGER NOT NULL, generation INTEGER NOT NULL REFERENCES inventory_generations(id),
                device INTEGER NOT NULL, inode INTEGER NOT NULL, allocated INTEGER NOT NULL, links INTEGER NOT NULL,
                PRIMARY KEY(run,generation,device,inode)) STRICT, WITHOUT ROWID;
            """)
    }

    func stage(_ record: LayoutRecord) throws {
        try database.transaction {
            let object = try database.prepare(
                """
                INSERT INTO experiment_objects VALUES(?,?,?,?,?,?)
                ON CONFLICT(run,generation,device,inode) DO UPDATE SET allocated=excluded.allocated,links=excluded.links
                """)
            try object.bind(Int64(run), at: 1)
            try object.bind(Int64(generation), at: 2)
            try object.bind(record.device, at: 3)
            try object.bind(record.inode, at: 4)
            try object.bind(record.allocated, at: 5)
            try object.bind(record.links, at: 6)
            _ = try object.step()
            let path = try database.prepare("INSERT OR REPLACE INTO experiment_mutations VALUES(?,?,?,?,?,?)")
            try path.bind(Int64(run), at: 1)
            try path.bind(Int64(generation), at: 2)
            try path.bind(record.path, at: 3)
            try path.bind(record.device, at: 4)
            try path.bind(record.inode, at: 5)
            try path.bind(record.classification, at: 6)
            _ = try path.step()
        }
    }

    func remove(_ path: Data) throws {
        let query = try database.prepare(
            """
            INSERT OR REPLACE INTO experiment_mutations VALUES(\(run),\(generation),?,NULL,NULL,NULL)
            """)
        try query.bind(path, at: 1)
        _ = try query.step()
    }

    func pageSQL(after: Data?, root: Data?) -> String {
        let root = root?.isEmpty == true ? nil : root
        func bounds(_ alias: String) -> String {
            var result = "\(alias).path \(after == nil ? ">=" : ">") ?1"
            if root != nil {
                result += """
                     AND \(alias).path>=?2 AND \(alias).path<?3
                     AND (\(alias).path=?2 OR \(alias).path>=?4)
                    """
            }
            return result
        }
        return """
            WITH base_page AS (
                SELECT d.path,p.device_id AS device,p.inode,COALESCE(om.allocated,o.allocated_bytes) AS allocated,
                    p.classification,COALESCE(om.links,o.link_count) AS links
                FROM path_order d CROSS JOIN inventory_paths p
                  ON p.generation_id=d.generation_id AND p.path_id=d.path_id
                CROSS JOIN inventory_objects o
                  ON o.generation_id=p.generation_id AND o.device_id=p.device_id AND o.inode=p.inode
                LEFT JOIN experiment_objects om
                  ON om.run=\(run) AND om.generation=\(generation) AND om.device=p.device_id AND om.inode=p.inode
                WHERE d.generation_id=\(generation) AND \(bounds("d"))
                  AND NOT EXISTS(SELECT 1 FROM experiment_mutations m
                    WHERE m.run=\(run) AND m.generation=\(generation) AND m.path=d.path)
                ORDER BY d.path LIMIT ?5
            ), mutation_page AS (
                SELECT m.path,m.device,m.inode,o.allocated,m.classification,o.links
                FROM experiment_mutations m CROSS JOIN experiment_objects o
                  ON o.run=m.run AND o.generation=m.generation AND o.device=m.device AND o.inode=m.inode
                WHERE m.run=\(run) AND m.generation=\(generation) AND m.device IS NOT NULL AND \(bounds("m"))
                ORDER BY m.path LIMIT ?5
            )
            SELECT * FROM base_page UNION ALL SELECT * FROM mutation_page ORDER BY path LIMIT ?5
            """
    }

    private func query(after: Data?, root: Data?, limit: Int, explain: Bool = false) throws -> SQLiteStatement {
        let root = root?.isEmpty == true ? nil : root
        let query = try database.prepare((explain ? "EXPLAIN QUERY PLAN " : "") + pageSQL(after: after, root: root))
        try query.bind(after ?? Data(), at: 1)
        if let root {
            try query.bind(root, at: 2)
            try query.bind(root + Data([48]), at: 3)
            try query.bind(root + Data([47]), at: 4)
        }
        try query.bind(Int64(limit), at: 5)
        return query
    }

    func page(after: Data? = nil, root: Data? = nil, limit: Int = 128) throws -> [LayoutRecord] {
        precondition(limit > 0 && limit <= 1024)
        let query = try query(after: after, root: root, limit: limit)
        var result: [LayoutRecord] = []
        while try query.step() {
            result.append(
                LayoutRecord(
                    path: query.columnData(0)!, inode: query.columnInt64(2),
                    allocated: query.columnInt64(3), classification: query.columnText(4)!,
                    device: query.columnInt64(1), links: query.columnInt64(5)))
        }
        return result
    }

    func plan(root: Data) throws -> [String] {
        let query = try query(after: nil, root: root, limit: 128, explain: true)
        var result: [String] = []
        while try query.step() { result.append(query.columnText(3)!) }
        return result
    }

    /// Opaque copy examines only disjoint requested path ranges, with one transaction per page.
    func preserve(roots: [Data], destination: Int, afterBatch: () throws -> Void = {}) throws -> Int {
        precondition(destination != generation)
        var disjoint: [Data] = []
        for root in Set(roots).sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            if !disjoint.contains(where: { $0.isEmpty || root == $0 || root.starts(with: $0 + Data([47])) }) {
                disjoint.append(root)
            }
        }
        var count = 0
        for root in disjoint {
            var cursor: Data?
            while true {
                let records = try page(after: cursor, root: root, limit: 1024)
                guard let last = records.last else { break }
                try store.append(records, generation: destination)
                count += records.count
                cursor = last.path
                try afterBatch()
            }
        }
        return count
    }

    /// Test-only atomic candidate commit. A real adapter still needs run revisions,
    /// trusted event fences, semantic ledger and report publication in this transaction.
    func commit(eventID: Int, beforeCheckpoint: () throws -> Void = {}) throws {
        try database.transaction {
            try database.execute(
                """
                CREATE TEMP TABLE IF NOT EXISTS experiment_candidates(
                    device INTEGER NOT NULL,inode INTEGER NOT NULL,PRIMARY KEY(device,inode)) WITHOUT ROWID;
                DELETE FROM experiment_candidates;
                INSERT OR IGNORE INTO experiment_candidates
                    SELECT p.device_id,p.inode FROM experiment_mutations m
                    CROSS JOIN path_order d ON d.generation_id=\(generation) AND d.path=m.path
                    CROSS JOIN inventory_paths p ON p.generation_id=d.generation_id AND p.path_id=d.path_id
                    WHERE m.run=\(run) AND m.generation=\(generation);
                INSERT OR IGNORE INTO experiment_candidates
                    SELECT device,inode FROM experiment_objects WHERE run=\(run) AND generation=\(generation);
                DELETE FROM canonical_attributions WHERE generation_id=\(generation)
                    AND (device_id,inode) IN (SELECT device,inode FROM experiment_candidates);
                DELETE FROM inventory_paths WHERE generation_id=\(generation) AND path_id IN (
                    SELECT d.path_id FROM experiment_mutations m CROSS JOIN path_order d
                    ON d.generation_id=\(generation) AND d.path=m.path
                    WHERE m.run=\(run) AND m.generation=\(generation));
                """)
            // Upserts are independently paged; tombstones have already removed old membership.
            var cursor: Data?
            while true {
                let query = try database.prepare(
                    """
                    SELECT m.path,m.device,m.inode,o.allocated,m.classification,o.links
                    FROM experiment_mutations m CROSS JOIN experiment_objects o
                      ON o.run=m.run AND o.generation=m.generation AND o.device=m.device AND o.inode=m.inode
                    WHERE m.run=\(run) AND m.generation=\(generation) AND m.device IS NOT NULL
                      AND m.path \(cursor == nil ? ">=" : ">") ? ORDER BY m.path LIMIT 1024
                    """)
                try query.bind(cursor ?? Data(), at: 1)
                var records: [LayoutRecord] = []
                while try query.step() {
                    records.append(
                        LayoutRecord(
                            path: query.columnData(0)!, inode: query.columnInt64(2),
                            allocated: query.columnInt64(3), classification: query.columnText(4)!,
                            device: query.columnInt64(1), links: query.columnInt64(5)))
                }
                guard let last = records.last else { break }
                try store.append(records, generation: generation, inTransaction: true)
                cursor = last.path
            }
            try database.execute(
                """
                UPDATE inventory_objects SET
                  allocated_bytes=(SELECT allocated FROM experiment_objects m WHERE m.run=\(run)
                    AND m.generation=\(generation) AND m.device=device_id AND m.inode=inventory_objects.inode),
                  logical_bytes=(SELECT allocated FROM experiment_objects m WHERE m.run=\(run)
                    AND m.generation=\(generation) AND m.device=device_id AND m.inode=inventory_objects.inode),
                  link_count=(SELECT links FROM experiment_objects m WHERE m.run=\(run)
                    AND m.generation=\(generation) AND m.device=device_id AND m.inode=inventory_objects.inode)
                WHERE generation_id=\(generation) AND (device_id,inode) IN (
                    SELECT device,inode FROM experiment_objects WHERE run=\(run) AND generation=\(generation));
                DELETE FROM inventory_objects WHERE generation_id=\(generation)
                  AND (device_id,inode) IN (SELECT device,inode FROM experiment_candidates)
                  AND NOT EXISTS(SELECT 1 FROM inventory_paths p WHERE p.generation_id=\(generation)
                    AND p.device_id=inventory_objects.device_id AND p.inode=inventory_objects.inode);
                INSERT INTO canonical_attributions
                SELECT p.generation_id,p.volume_id,p.device_id,p.inode,p.path_id,p.classification
                FROM inventory_objects o CROSS JOIN inventory_paths p
                WHERE o.generation_id=\(generation) AND p.generation_id=o.generation_id
                  AND (o.device_id,o.inode) IN (SELECT device,inode FROM experiment_candidates)
                  AND p.path_id=(\(store.canonicalCandidateSQL));
                """)
            try beforeCheckpoint()
            let checkpoint = try database.prepare(
                """
                UPDATE checkpoints SET event_id=? WHERE active_generation_id=\(generation)
                """)
            try checkpoint.bind(Int64(eventID), at: 1)
            _ = try checkpoint.step()
            guard database.changes == 1 else { throw HybridValidationError.inactiveGeneration }
            try database.execute(
                """
                DELETE FROM experiment_mutations WHERE run=\(run) AND generation=\(generation);
                DELETE FROM experiment_objects WHERE run=\(run) AND generation=\(generation);
                """)
        }
    }
}

enum HybridValidationError: Error {
    case missingNode, cycle, inconsistentOrder, inactiveGeneration
}

extension StorageLayoutPrototype {
    /// Explicit diagnostic, never a normal polling query. Bounded membership batches
    /// and ancestor cache; detects errors that a one-way order->membership FK misses.
    func auditTreeOrder(generation: Int) throws -> Int {
        precondition(layout == .treeOrdered)
        let lookup = try database.prepare("SELECT parent_id,name FROM path_dictionary WHERE id=?")
        var cursor: Int64 = 0
        var count = 0
        while true {
            let rows = try database.prepare(
                """
                SELECT p.path_id,d.path FROM inventory_paths p LEFT JOIN path_order d
                  ON d.generation_id=p.generation_id AND d.path_id=p.path_id
                WHERE p.generation_id=\(generation) AND p.path_id>? ORDER BY p.path_id LIMIT 512
                """)
            try rows.bind(cursor, at: 1)
            var batch: [(Int64, Data?)] = []
            while try rows.step() { batch.append((rows.columnInt64(0), rows.columnData(1))) }
            guard !batch.isEmpty else { return count }
            var cache: [Int64: Data] = [:]
            for (id, ordered) in batch {
                var chain: [(Int64, Data)] = []
                var visiting: Set<Int64> = []
                var current: Int64? = id
                while let node = current, cache[node] == nil {
                    guard visiting.insert(node).inserted else { throw HybridValidationError.cycle }
                    try lookup.bind(node, at: 1)
                    guard try lookup.step() else {
                        try lookup.reset()
                        throw HybridValidationError.missingNode
                    }
                    let parent = lookup.columnIsNull(0) ? nil : lookup.columnInt64(0)
                    let name = lookup.columnData(1)!
                    try lookup.reset()
                    chain.append((node, name))
                    current = parent
                }
                var path = current.flatMap { cache[$0] }
                for (node, name) in chain.reversed() {
                    path = path.map { $0 + Data([47]) + name } ?? name
                    cache[node] = path!
                }
                guard ordered == cache[id] else { throw HybridValidationError.inconsistentOrder }
                cursor = id
                count += 1
            }
        }
    }
}

/// Two independently bounded cursors. Callback permits exact comparison without
/// retaining a complete inventory/diff in memory.
func hybridDiff(
    _ lhs: HybridTreeExperiment, _ rhs: HybridTreeExperiment,
    emit: (LayoutRecord?, LayoutRecord?) throws -> Void
) throws -> Int {
    var left: [LayoutRecord] = []
    var right: [LayoutRecord] = []
    var li = 0
    var ri = 0
    var lc: Data?
    var rc: Data?
    var leftDone = false
    var rightDone = false
    var changes = 0
    while true {
        if li == left.count && !leftDone {
            left = try lhs.page(after: lc, limit: 512)
            li = 0
            lc = left.last?.path ?? lc
            leftDone = left.isEmpty
        }
        if ri == right.count && !rightDone {
            right = try rhs.page(after: rc, limit: 512)
            ri = 0
            rc = right.last?.path ?? rc
            rightDone = right.isEmpty
        }
        let a = li < left.count ? left[li] : nil
        let b = ri < right.count ? right[ri] : nil
        if a == nil && b == nil { return changes }
        if let a, let b, a.path == b.path {
            if a != b {
                try emit(a, b)
                changes += 1
            }
            li += 1
            ri += 1
        } else if let a, b == nil || a.path.lexicographicallyPrecedes(b!.path) {
            try emit(a, nil)
            changes += 1
            li += 1
        } else {
            try emit(nil, b)
            changes += 1
            ri += 1
        }
    }
}
