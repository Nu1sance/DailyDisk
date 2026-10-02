import DailyDiskCore
import Foundation

@testable import DailyDiskStore

/// Isolated W6 storage experiment. Never opens the production database or runs migrations.
/// Callers supply a synthetic database and retain the actor's writer lease through the run.
/// Production uses SQLiteInventoryStore; this fixture remains an independent test oracle.
actor W6InventoryPrototype {
    struct ObjectKey: Hashable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    struct Session: Sendable {
        let id: String
        let baseRevision: Int64
        var seen = W6SeenPaths()
        var finished = false
        var failed = false
    }

    struct Result: Sendable {
        let revision: Int64
        let changedObjects: Int64
        let changedPaths: Int64
    }

    private let lease: ProcessLease
    private let db: SQLiteDatabase
    private let volume: MonitoredVolume.ID
    private var session: Session?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(url: URL, volume: MonitoredVolume.ID) throws {
        // Refuse an existing production DB before acquiring a writer or creating any schema.
        if FileManager.default.fileExists(atPath: url.path) {
            let read = try SQLiteDatabase(url: url, readOnly: true)
            guard try read.scalarInt64("SELECT COUNT(*) FROM sqlite_master WHERE name='schema_metadata'") == 0 else {
                throw StoreInvariantError.corruptStoredValue("W6 prototype requires an isolated database")
            }
        }
        self.volume = volume
        lease = try ProcessLease(databaseURL: url)
        db = try SQLiteDatabase(url: url, checkpointPolicy: .bounded())
        try db.execute(
            """
            CREATE TABLE IF NOT EXISTS w6_meta(singleton INTEGER PRIMARY KEY CHECK(singleton=1),
              revision INTEGER NOT NULL, checkpoint BLOB, volume TEXT NOT NULL) STRICT;
            CREATE TABLE IF NOT EXISTS w6_paths(id INTEGER PRIMARY KEY, raw BLOB NOT NULL UNIQUE) STRICT;
            CREATE TABLE IF NOT EXISTS w6_objects(device INTEGER NOT NULL,inode INTEGER NOT NULL,payload BLOB NOT NULL,
              PRIMARY KEY(device,inode)) STRICT, WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS w6_members(path_id INTEGER PRIMARY KEY REFERENCES w6_paths(id),
              device INTEGER NOT NULL,inode INTEGER NOT NULL,classification TEXT NOT NULL,
              FOREIGN KEY(device,inode) REFERENCES w6_objects(device,inode)) STRICT;
            CREATE INDEX IF NOT EXISTS w6_member_object ON w6_members(device,inode,path_id);
            CREATE TABLE IF NOT EXISTS w6_canonical(device INTEGER NOT NULL,inode INTEGER NOT NULL,
              path_id INTEGER NOT NULL REFERENCES w6_members(path_id), PRIMARY KEY(device,inode),
              FOREIGN KEY(device,inode) REFERENCES w6_objects(device,inode)) STRICT, WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS w6_run(singleton INTEGER PRIMARY KEY CHECK(singleton=1),
              id TEXT NOT NULL,base_revision INTEGER NOT NULL,finished INTEGER NOT NULL DEFAULT 0) STRICT;
            CREATE TABLE IF NOT EXISTS w6_object_delta(device INTEGER NOT NULL,inode INTEGER NOT NULL,payload BLOB NOT NULL,
              PRIMARY KEY(device,inode)) STRICT, WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS w6_path_delta(path_id INTEGER PRIMARY KEY REFERENCES w6_paths(id),
              device INTEGER,inode INTEGER,classification TEXT,
              CHECK((device IS NULL AND inode IS NULL AND classification IS NULL)
                 OR (device IS NOT NULL AND inode IS NOT NULL AND classification IS NOT NULL))) STRICT;
            CREATE TABLE IF NOT EXISTS w6_versions(revision INTEGER PRIMARY KEY,previous_checkpoint BLOB,
              committed_at REAL NOT NULL,published INTEGER NOT NULL DEFAULT 0) STRICT;
            CREATE TABLE IF NOT EXISTS w6_old_objects(revision INTEGER NOT NULL REFERENCES w6_versions(revision) ON DELETE CASCADE,
              device INTEGER NOT NULL,inode INTEGER NOT NULL,payload BLOB,
              PRIMARY KEY(revision,device,inode)) STRICT, WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS w6_old_members(revision INTEGER NOT NULL REFERENCES w6_versions(revision) ON DELETE CASCADE,
              path_id INTEGER NOT NULL REFERENCES w6_paths(id),device INTEGER,inode INTEGER,classification TEXT,
              PRIMARY KEY(revision,path_id)) STRICT, WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS w6_old_member_path ON w6_old_members(path_id);
            """)
        let insert = try db.prepare("INSERT OR IGNORE INTO w6_meta VALUES(1,0,NULL,?)")
        try insert.bind(volume.rawValue, at: 1)
        _ = try insert.step()
        guard try db.scalarText("SELECT volume FROM w6_meta") == volume.rawValue else {
            throw StoreInvariantError.volumeMismatch
        }
        // An interrupted traversal has no durable seen-set. It must restart, not infer deletions.
        let connection = db
        try connection.transaction {
            try connection.execute("DELETE FROM w6_object_delta; DELETE FROM w6_path_delta; DELETE FROM w6_run;")
        }
    }

    func begin() throws {
        guard session == nil,
            try db.scalarInt64("SELECT COUNT(*) FROM w6_versions WHERE published=0") == 0
        else { throw StoreInvariantError.invalidRunState }
        let revision = try db.scalarInt64("SELECT revision FROM w6_meta") ?? 0
        let id = UUID().uuidString
        try db.transaction {
            let insert = try db.prepare("INSERT INTO w6_run VALUES(1,?,?,0)")
            try insert.bind(id, at: 1)
            try insert.bind(revision, at: 2)
            _ = try insert.step()
        }
        session = Session(id: id, baseRevision: revision)
    }

    /// Batches compare against current inventory plus prior observations. Never reorders aliases.
    /// Only changed rows are staged; new immutable path IDs are safe to discard after interruption.
    func observe(_ records: [InventoryRecord]) throws {
        guard var current = session, !current.finished, !current.failed else {
            throw StoreInvariantError.invalidRunState
        }
        guard records.count <= InventoryRecordBatch.maximumRecordCount else {
            throw StoreInvariantError.corruptStoredValue("W6 observation batch is too large")
        }
        var succeeded = false
        defer { if !succeeded { session?.failed = true } }

        let lookupPath = try db.prepare("SELECT id FROM w6_paths WHERE raw=?")
        let insertPath = try db.prepare("INSERT INTO w6_paths(raw) VALUES(?)")
        let lookupObject = try db.prepare(
            """
            SELECT payload FROM w6_object_delta WHERE device=?1 AND inode=?2
            UNION ALL SELECT payload FROM w6_objects WHERE device=?1 AND inode=?2
              AND NOT EXISTS(SELECT 1 FROM w6_object_delta WHERE device=?1 AND inode=?2) LIMIT 1
            """)
        let writeObject = try db.prepare(
            """
            INSERT INTO w6_object_delta VALUES(?,?,?) ON CONFLICT(device,inode) DO UPDATE SET payload=excluded.payload
            """)
        let lookupMember = try db.prepare(
            """
            SELECT device,inode,classification FROM w6_path_delta WHERE path_id=?1
            UNION ALL SELECT device,inode,classification FROM w6_members WHERE path_id=?1
              AND NOT EXISTS(SELECT 1 FROM w6_path_delta WHERE path_id=?1) LIMIT 1
            """)
        let writeMember = try db.prepare(
            """
            INSERT INTO w6_path_delta VALUES(?,?,?,?) ON CONFLICT(path_id) DO UPDATE SET
              device=excluded.device,inode=excluded.inode,classification=excluded.classification
            """)
        try db.transaction {
            for (index, record) in records.enumerated() {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                guard record.path.volumeID == volume, record.object.identity.volumeID == volume else {
                    throw StoreInvariantError.volumeMismatch
                }
                try lookupPath.reset()
                try lookupPath.bind(record.path.relativePath.bytes, at: 1)
                let pathID: Int64
                if try lookupPath.step() {
                    pathID = lookupPath.columnInt64(0)
                } else {
                    try insertPath.reset()
                    try insertPath.bind(record.path.relativePath.bytes, at: 1)
                    _ = try insertPath.step()
                    pathID = db.lastInsertedRowID
                }
                try current.seen.insert(pathID)
                let device = Int64(bitPattern: record.object.identity.deviceID)
                let inode = Int64(bitPattern: record.object.identity.inode)
                try lookupObject.reset()
                try lookupObject.bind(device, at: 1)
                try lookupObject.bind(inode, at: 2)
                let previousObject: InventoryObject?
                if try lookupObject.step(), let payload = lookupObject.columnData(0) {
                    previousObject = try decoder.decode(InventoryObject.self, from: payload)
                } else {
                    previousObject = nil
                }
                if previousObject != record.object {
                    try writeObject.reset()
                    try writeObject.bind(device, at: 1)
                    try writeObject.bind(inode, at: 2)
                    try writeObject.bind(encoder.encode(record.object), at: 3)
                    _ = try writeObject.step()
                }
                try lookupMember.reset()
                try lookupMember.bind(pathID, at: 1)
                let exists = try lookupMember.step()
                if !exists || lookupMember.columnIsNull(0) || lookupMember.columnInt64(0) != device
                    || lookupMember.columnInt64(1) != inode
                    || lookupMember.columnText(2) != record.path.classification.rawValue
                {
                    try writeMember.reset()
                    try writeMember.bind(pathID, at: 1)
                    try writeMember.bind(device, at: 2)
                    try writeMember.bind(inode, at: 3)
                    try writeMember.bind(record.path.classification.rawValue, at: 4)
                    _ = try writeMember.step()
                }
            }
        }
        // Publish seen bits only after the batch commits; rollback cannot manufacture observations.
        session = current
        succeeded = true
    }

    /// Completes traversal only. Caller must apply trusted E0–E1 changes before final activation.
    func finishTraversal(opaqueRoots: [RelativePath] = []) throws {
        guard var current = session, !current.finished, !current.failed else {
            throw StoreInvariantError.invalidRunState
        }
        var succeeded = false
        defer { if !succeeded { session?.failed = true } }

        let roots = opaqueRoots.sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }
        var after: Int64 = 0
        while true {
            try Task.checkCancellation()
            let page = try db.prepare(
                """
                SELECT m.path_id,p.raw FROM w6_members m JOIN w6_paths p ON p.id=m.path_id
                WHERE m.path_id>? ORDER BY m.path_id LIMIT 1024
                """)
            try page.bind(after, at: 1)
            var removed: [Int64] = []
            var count = 0
            while try page.step() {
                count += 1
                after = page.columnInt64(0)
                guard !current.seen.contains(after), let raw = page.columnData(1) else { continue }
                let opaque = roots.contains { root in
                    root.bytes.isEmpty || raw == root.bytes || raw.starts(with: root.bytes + Data([47]))
                }
                if !opaque { removed.append(after) }
            }
            if count == 0 { break }
            try db.transaction {
                let remove = try db.prepare("INSERT OR REPLACE INTO w6_path_delta VALUES(?,NULL,NULL,NULL)")
                for id in removed {
                    try remove.reset()
                    try remove.bind(id, at: 1)
                    _ = try remove.step()
                }
            }
        }
        try db.transaction { try db.execute("UPDATE w6_run SET finished=1") }
        current.finished = true
        session = current
        succeeded = true
    }

    /// Explicit compensation input, not an FSEvents trust bypass. Production adapter must supply fences.
    func compensate(upserts: [InventoryRecord], removals: [RelativePath]) throws {
        guard var current = session, current.finished, !current.failed else {
            throw StoreInvariantError.invalidRunState
        }
        var succeeded = false
        defer { if !succeeded { session?.failed = true } }

        current.finished = false
        session = current
        do { try observe(upserts) } catch {
            session?.finished = true
            throw error
        }
        session?.finished = true
        try db.transaction {
            let remove = try db.prepare(
                """
                INSERT OR REPLACE INTO w6_path_delta SELECT id,NULL,NULL,NULL FROM w6_paths WHERE raw=?
                """)
            for path in removals {
                try remove.reset()
                try remove.bind(path.bytes, at: 1)
                _ = try remove.step()
            }
        }
        succeeded = true
    }

    /// All inventory/old values/checkpoint publication is one transaction. Test fault injection
    /// deliberately throws after mutations to prove rollback also restores canonical and history.
    func commit(checkpoint: Data, at date: Date, beforeCommit: (@Sendable () throws -> Void)? = nil) throws -> Result {
        guard let current = session, current.finished, !current.failed else {
            throw StoreInvariantError.invalidRunState
        }
        let result = try db.transaction {
            guard try db.scalarInt64("SELECT revision FROM w6_meta") == current.baseRevision,
                try db.scalarInt64("SELECT finished FROM w6_run") == 1,
                try db.scalarText("SELECT id FROM w6_run") == current.id
            else { throw StoreInvariantError.invalidRunState }
            // Remove observations that reverted to the original value before committing.
            let candidates = try db.prepare(
                "SELECT d.device,d.inode,d.payload,o.payload FROM w6_object_delta d JOIN w6_objects o USING(device,inode)"
            )
            var equal: [ObjectKey] = []
            while try candidates.step() {
                if let a = candidates.columnData(2), let b = candidates.columnData(3),
                    try decoder.decode(InventoryObject.self, from: a) == decoder.decode(InventoryObject.self, from: b)
                {
                    equal.append(
                        ObjectKey(
                            device: UInt64(bitPattern: candidates.columnInt64(0)),
                            inode: UInt64(bitPattern: candidates.columnInt64(1))))
                }
            }
            let removeEqual = try db.prepare("DELETE FROM w6_object_delta WHERE device=? AND inode=?")
            for key in equal {
                try removeEqual.reset()
                try removeEqual.bind(Int64(bitPattern: key.device), at: 1)
                try removeEqual.bind(Int64(bitPattern: key.inode), at: 2)
                _ = try removeEqual.step()
            }
            try db.execute(
                """
                DELETE FROM w6_path_delta WHERE EXISTS(SELECT 1 FROM w6_members m WHERE m.path_id=w6_path_delta.path_id
                  AND m.device IS w6_path_delta.device AND m.inode IS w6_path_delta.inode
                  AND m.classification IS w6_path_delta.classification)
                  OR (device IS NULL AND NOT EXISTS(SELECT 1 FROM w6_members m WHERE m.path_id=w6_path_delta.path_id));
                CREATE TEMP TABLE w6_candidates(device INTEGER,inode INTEGER,PRIMARY KEY(device,inode)) WITHOUT ROWID;
                INSERT OR IGNORE INTO w6_candidates SELECT device,inode FROM w6_object_delta;
                INSERT OR IGNORE INTO w6_candidates SELECT m.device,m.inode FROM w6_path_delta d JOIN w6_members m USING(path_id);
                INSERT OR IGNORE INTO w6_candidates SELECT device,inode FROM w6_path_delta WHERE device IS NOT NULL;
                """)
            defer { try? db.execute("DROP TABLE IF EXISTS w6_candidates") }
            let revision = current.baseRevision + 1
            let version = try db.prepare("INSERT INTO w6_versions SELECT ?,checkpoint,?,0 FROM w6_meta")
            try version.bind(revision, at: 1)
            try version.bind(date.timeIntervalSince1970, at: 2)
            _ = try version.step()
            let oldObjects = try db.prepare(
                """
                INSERT INTO w6_old_objects SELECT ?,c.device,c.inode,o.payload FROM w6_candidates c
                  LEFT JOIN w6_objects o USING(device,inode)
                """)
            try oldObjects.bind(revision, at: 1)
            _ = try oldObjects.step()
            let oldPaths = try db.prepare(
                """
                INSERT INTO w6_old_members SELECT ?,d.path_id,m.device,m.inode,m.classification
                  FROM w6_path_delta d LEFT JOIN w6_members m USING(path_id)
                """)
            try oldPaths.bind(revision, at: 1)
            _ = try oldPaths.step()
            let objectCount = try db.scalarInt64("SELECT COUNT(*) FROM w6_object_delta") ?? 0
            let pathCount = try db.scalarInt64("SELECT COUNT(*) FROM w6_path_delta") ?? 0
            try db.execute(
                """
                DELETE FROM w6_canonical WHERE (device,inode) IN (SELECT device,inode FROM w6_candidates);
                INSERT INTO w6_objects SELECT * FROM w6_object_delta WHERE 1
                  ON CONFLICT(device,inode) DO UPDATE SET payload=excluded.payload;
                DELETE FROM w6_members WHERE path_id IN (SELECT path_id FROM w6_path_delta WHERE device IS NULL);
                INSERT INTO w6_members SELECT * FROM w6_path_delta WHERE device IS NOT NULL
                  ON CONFLICT(path_id) DO UPDATE SET device=excluded.device,inode=excluded.inode,classification=excluded.classification;
                DELETE FROM w6_objects WHERE (device,inode) IN (SELECT device,inode FROM w6_candidates)
                  AND NOT EXISTS(SELECT 1 FROM w6_members m WHERE m.device=w6_objects.device AND m.inode=w6_objects.inode);
                INSERT INTO w6_canonical SELECT c.device,c.inode,
                  (SELECT m.path_id FROM w6_members m JOIN w6_paths p ON p.id=m.path_id
                   WHERE m.device=c.device AND m.inode=c.inode ORDER BY p.raw LIMIT 1)
                  FROM w6_candidates c WHERE EXISTS(SELECT 1 FROM w6_objects o WHERE o.device=c.device AND o.inode=c.inode);
                """)
            let update = try db.prepare("UPDATE w6_meta SET revision=?,checkpoint=?")
            try update.bind(revision, at: 1)
            try update.bind(checkpoint, at: 2)
            _ = try update.step()
            try db.execute("DELETE FROM w6_object_delta; DELETE FROM w6_path_delta; DELETE FROM w6_run;")
            try beforeCommit?()
            return Result(revision: revision, changedObjects: objectCount, changedPaths: pathCount)
        }
        session = nil
        return result
    }

    func cancel() throws {
        try discardPending()
        session = nil
    }

    func markPublished(revision: Int64) throws {
        try db.transaction {
            let update = try db.prepare("UPDATE w6_versions SET published=1 WHERE revision=?")
            try update.bind(revision, at: 1)
            _ = try update.step()
        }
    }

    func prune(at date: Date) throws {
        guard session == nil else { throw StoreInvariantError.invalidRunState }
        // Pending report recovery pins all undo history; deletion is separate from activation.
        guard try db.scalarInt64("SELECT COUNT(*) FROM w6_versions WHERE published=0") == 0 else { return }
        try db.transaction {
            let remove = try db.prepare("DELETE FROM w6_versions WHERE committed_at<?")
            try remove.bind(date.addingTimeInterval(-86400).timeIntervalSince1970, at: 1)
            _ = try remove.step()
            try collectPaths()
        }
    }

    func records() throws -> [InventoryRecord] {
        let query = try db.prepare(
            """
            SELECT p.raw,o.payload,m.classification FROM w6_paths p JOIN w6_members m ON m.path_id=p.id
              JOIN w6_objects o ON o.device=m.device AND o.inode=m.inode ORDER BY p.raw
            """)
        var records: [InventoryRecord] = []
        while try query.step() {
            guard let raw = query.columnData(0), let payload = query.columnData(1),
                let classification = query.columnText(2).flatMap(InventoryClassification.init(rawValue:))
            else { throw StoreInvariantError.corruptStoredValue("W6 record") }
            let object = try decoder.decode(InventoryObject.self, from: payload)
            let path = try RelativePath(validating: raw)
            records.append(
                try InventoryRecord(
                    object: object,
                    path: InventoryPath(
                        volumeID: volume, relativePath: path, parentPath: PathPolicy.parent(of: path),
                        objectIdentity: object.identity, classification: classification)))
        }
        return records
    }

    /// Exact retained historical lookup. Missing undo chains fail rather than return current data.
    func record(path: RelativePath, at revision: Int64) throws -> InventoryRecord? {
        let latest = try db.scalarInt64("SELECT revision FROM w6_meta") ?? 0
        let chain = try db.prepare("SELECT COUNT(*) FROM w6_versions WHERE revision>?")
        try chain.bind(revision, at: 1)
        guard revision >= 0, revision <= latest, try chain.step(), chain.columnInt64(0) == latest - revision else {
            throw StoreInvariantError.corruptStoredValue("W6 history expired")
        }
        let member = try db.prepare(
            """
            SELECT device,inode,classification FROM w6_old_members WHERE path_id=(SELECT id FROM w6_paths WHERE raw=?1)
              AND revision>?2 ORDER BY revision LIMIT 1
            """)
        try member.bind(path.bytes, at: 1)
        try member.bind(revision, at: 2)
        let current = try db.prepare(
            "SELECT device,inode,classification FROM w6_members WHERE path_id=(SELECT id FROM w6_paths WHERE raw=?)")
        try current.bind(path.bytes, at: 1)
        let source: SQLiteStatement
        if try member.step() { source = member } else if try current.step() { source = current } else { return nil }
        guard !source.columnIsNull(0),
            let classification = source.columnText(2).flatMap(InventoryClassification.init(rawValue:))
        else { return nil }
        let object = try db.prepare(
            "SELECT payload FROM w6_old_objects WHERE device=?1 AND inode=?2 AND revision>?3 ORDER BY revision LIMIT 1")
        try object.bind(source.columnInt64(0), at: 1)
        try object.bind(source.columnInt64(1), at: 2)
        try object.bind(revision, at: 3)
        let payload: Data?
        if try object.step() {
            payload = object.columnData(0)
        } else {
            let live = try db.prepare("SELECT payload FROM w6_objects WHERE device=? AND inode=?")
            try live.bind(source.columnInt64(0), at: 1)
            try live.bind(source.columnInt64(1), at: 2)
            payload = try live.step() ? live.columnData(0) : nil
        }
        guard let payload else { throw StoreInvariantError.corruptStoredValue("W6 history object missing") }
        let value = try decoder.decode(InventoryObject.self, from: payload)
        return try InventoryRecord(
            object: value,
            path: InventoryPath(
                volumeID: volume, relativePath: path, parentPath: PathPolicy.parent(of: path),
                objectIdentity: value.identity, classification: classification))
    }

    func checkpointStorage() throws { try db.checkpointWAL() }

    func counters() throws -> (objects: Int64, paths: Int64, undo: Int64, seenBytes: Int) {
        (
            try db.scalarInt64("SELECT COUNT(*) FROM w6_objects") ?? 0,
            try db.scalarInt64("SELECT COUNT(*) FROM w6_members") ?? 0,
            try db.scalarInt64("SELECT COUNT(*) FROM w6_old_objects") ?? 0,
            session?.seen.allocatedBytes ?? 0
        )
    }

    func verify() throws -> Bool {
        guard try db.scalarText("PRAGMA integrity_check") == "ok" else { return false }
        let fk = try db.prepare("PRAGMA foreign_key_check")
        guard try !fk.step() else { return false }
        return try db.scalarInt64("SELECT COUNT(*) FROM w6_objects")
            == db.scalarInt64("SELECT COUNT(*) FROM w6_canonical")
    }

    private func discardPending() throws {
        try db.transaction {
            try db.execute("DELETE FROM w6_object_delta; DELETE FROM w6_path_delta; DELETE FROM w6_run;")
            try collectPaths()
        }
    }

    private func collectPaths() throws {
        try db.execute(
            """
            DELETE FROM w6_paths WHERE NOT EXISTS(SELECT 1 FROM w6_members m WHERE m.path_id=w6_paths.id)
              AND NOT EXISTS(SELECT 1 FROM w6_old_members o WHERE o.path_id=w6_paths.id)
              AND NOT EXISTS(SELECT 1 FROM w6_path_delta d WHERE d.path_id=w6_paths.id);
            """)
    }
}
