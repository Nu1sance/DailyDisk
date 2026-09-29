import Foundation
import Testing

@testable import DailyDiskStore

@Test("Hybrid node insertion failure does not poison reusable statements")
func hybridNodeInsertionRecovery() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("HybridRecovery-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try StorageLayoutPrototype(url: root.appendingPathComponent("inventory.sqlite"), layout: .treeOrdered)
    try store.addGeneration(1)
    let original = LayoutRecord(path: Data("stable/file".utf8), inode: 1)
    try store.append([original], generation: 1)
    try store.seal(1)
    try store.activate(1)
    let nodes = try store.database.scalarInt64("SELECT COUNT(*) FROM path_dictionary")
    try store.database.execute(
        """
        CREATE TRIGGER reject_node BEFORE INSERT ON path_dictionary
        WHEN NEW.name=x'626c6f636b6564' BEGIN SELECT RAISE(ABORT,'synthetic node failure'); END;
        """)
    let incoming = LayoutRecord(path: Data("new/blocked/file".utf8), inode: 2)
    #expect(throws: (any Error).self) { try store.append([incoming], generation: 1) }
    #expect(try store.database.scalarInt64("SELECT COUNT(*) FROM path_dictionary") == nodes)
    #expect(try store.auditTreeOrder(generation: 1) == 1)
    try store.database.execute("DROP TRIGGER reject_node")
    // Retry on the same connection: native sqlite3_step errors require reset/finalize.
    try store.append([incoming], generation: 1)
    try store.seal(1)
    #expect(try store.auditTreeOrder(generation: 1) == 2)
    #expect(try store.canonicalPaths(generation: 1) == [incoming.path, original.path])
    #expect(try store.database.scalarInt64("SELECT event_id FROM checkpoints") == 10)
}

@Test("Hybrid deep orphan cleanup does not rescan unrelated live nodes at every depth")
func hybridDeepCleanupScaling() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("HybridGC-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var batchCounts: [Int] = []
    for liveCount in [1024, 8192] {
        let store = try StorageLayoutPrototype(
            url: root.appendingPathComponent("\(liveCount)/inventory.sqlite"), layout: .treeOrdered)
        try store.addGeneration(1)
        try store.addGeneration(2)
        for offset in stride(from: 0, to: liveCount, by: 1024) {
            try store.append(
                (offset..<offset + 1024).map {
                    LayoutRecord(path: Data("live/file-\($0)".utf8), inode: Int64($0 + 1))
                }, generation: 1)
        }
        try store.seal(1)
        try store.activate(1)
        let obsolete = LayoutRecord(path: Data((String(repeating: "old/", count: 64) + "leaf").utf8), inode: 99999)
        try store.append([obsolete], generation: 2)
        try store.deleteGeneration(2)
        var batches = 0
        #expect(try store.collectDictionary { batches += 1 } == 65)
        batchCounts.append(batches)
        #expect(try store.auditTreeOrder(generation: 1) == liveCount)
        #expect(try store.database.scalarInt64("SELECT event_id FROM checkpoints") == 10)
    }
    print("Hybrid deep GC batch counts (1024/8192 unrelated live paths): \(batchCounts)")
    // Fixed garbage should not need repeated sweeps of the larger live inventory.
    #expect(batchCounts[1] < batchCounts[0] * 2)
}

private func adversarialRecords(_ view: HybridTreeExperiment) throws -> [LayoutRecord] {
    var result: [LayoutRecord] = []
    var cursor: Data?
    while true {
        let page = try view.page(after: cursor, limit: 7)
        guard let last = page.last else { return result }
        result += page
        cursor = last.path
    }
}

private func adversarialUpsert(_ record: LayoutRecord, _ state: inout [Data: LayoutRecord]) {
    for (path, previous) in state where previous.device == record.device && previous.inode == record.inode {
        var next = previous
        next.allocated = record.allocated
        next.links = record.links
        state[path] = next
    }
    state[record.path] = record
}

@Test("Hybrid repeated transactions match a raw-byte oracle across devices, aliases, rollback and GC")
func hybridRepeatedTransactions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("HybridCycles-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    for seed in 1...4 {
        let store = try StorageLayoutPrototype(
            url: root.appendingPathComponent("\(seed)/inventory.sqlite"), layout: .treeOrdered)
        try store.addGeneration(1)
        try store.addGeneration(2)
        let paths: [Data] =
            [Data(), Data([255]), Data("cache".utf8), Data("cache0".utf8)]
            + (0..<124).map { Data("cache/\($0)/".utf8) + Data([128, UInt8($0 + 1)]) }
        var state: [Data: LayoutRecord] = [:]
        for (index, path) in paths.enumerated() {
            let record = LayoutRecord(path: path, inode: Int64(index % 24), device: Int64(index % 3), links: 8)
            try store.append([record], generation: 1)
            try store.append([record], generation: 2)
            adversarialUpsert(record, &state)
        }
        for generation in 1...2 { try store.seal(generation) }
        try store.activate(1)
        let view = try HybridTreeExperiment(store: store, generation: 1)
        let base = try HybridTreeExperiment(store: store, generation: 1, run: 99)
        let retained = try HybridTreeExperiment(store: store, generation: 2)
        let original = try adversarialRecords(retained)
        var random = UInt64(seed)
        func next() -> UInt64 {
            random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return random >> 16
        }
        for cycle in 1...12 {
            let previous = try adversarialRecords(base)
            for _ in 0..<48 {
                let path = paths[Int(next() % UInt64(paths.count))]
                if next() % 4 == 0 {
                    try view.remove(path)
                    state.removeValue(forKey: path)
                } else {
                    let record = LayoutRecord(
                        path: path, inode: Int64(bitPattern: (next() % 24) &* 0x9e37_79b9_7f4a_7c15),
                        allocated: Int64(next() % 100_000),
                        classification: next() % 2 == 0 ? "ordinary" : "dailyDiskInternal",
                        device: Int64(next() % 3), links: Int64(next() % 8 + 1))
                    try view.stage(record)
                    adversarialUpsert(record, &state)
                }
            }
            let expected = state.values.sorted { $0.path.lexicographicallyPrecedes($1.path) }
            #expect(try adversarialRecords(view) == expected)
            if cycle % 3 == 0 {
                #expect(throws: LayoutExperimentError.self) {
                    try view.commit(eventID: 10 + cycle) { throw LayoutExperimentError.rollback }
                }
                #expect(try adversarialRecords(base) == previous)
                #expect(try adversarialRecords(view) == expected)
            }
            // Raw overlay paths need not intern nodes until commit; GC must not
            // invalidate retained generations or any live references.
            _ = try store.collectDictionary()
            try view.commit(eventID: 10 + cycle)
            #expect(try adversarialRecords(base) == expected)
            #expect(try adversarialRecords(retained) == original)
            #expect(try store.auditTreeOrder(generation: 1) == expected.count)
            let groups = Dictionary(grouping: expected) { "\($0.device):\($0.inode)" }
            let canonical = groups.values.map { $0.first!.path }.sorted { $0.lexicographicallyPrecedes($1) }
            #expect(try store.canonicalPaths(generation: 1) == canonical)
            #expect(
                try store.database.scalarInt64("SELECT COUNT(*) FROM inventory_objects WHERE generation_id=1")
                    == Int64(groups.count))
            let foreign = try store.database.prepare("PRAGMA foreign_key_check")
            #expect(try !foreign.step())
        }
    }
}

@Test("Hybrid leaf-queue GC resumes after interruption and retains overlay references and ancestors")
func hybridCleanupInterruption() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("HybridGCResume-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try StorageLayoutPrototype(url: root.appendingPathComponent("inventory.sqlite"), layout: .treeOrdered)
    try store.addGeneration(1)
    let live = LayoutRecord(path: Data("live/file".utf8), inode: 1)
    try store.append([live], generation: 1)
    try store.seal(1)
    try store.activate(1)
    let protected = try store.intern(Data("pending/deep/leaf".utf8))
    try store.database.execute("INSERT INTO overlay_path_refs VALUES('run',\(protected))")
    for index in 0..<2200 { _ = try store.intern(Data("garbage/\(index)/leaf".utf8)) }
    var batches = 0
    #expect(throws: LayoutExperimentError.self) {
        _ = try store.collectDictionary {
            batches += 1
            throw LayoutExperimentError.rollback
        }
    }
    #expect(batches == 1)
    _ = try store.collectDictionary()
    #expect(try store.database.scalarInt64("SELECT COUNT(*) FROM path_dictionary") == 5)
    #expect(try store.auditTreeOrder(generation: 1) == 1)
    #expect(try store.database.scalarInt64("SELECT event_id FROM checkpoints") == 10)
    try store.database.execute("DELETE FROM overlay_path_refs")
    #expect(try store.collectDictionary() == 3)
    #expect(try store.database.scalarInt64("SELECT COUNT(*) FROM path_dictionary") == 2)
    #expect(try store.canonicalPaths(generation: 1) == [live.path])
}
