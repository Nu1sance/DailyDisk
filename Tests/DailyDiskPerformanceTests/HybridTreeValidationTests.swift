import Foundation
import Testing

@testable import DailyDiskStore

private func hybridRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("DailyDiskHybrid-" + UUID().uuidString)
}

private func hybridFixture(_ index: Int) -> LayoutRecord {
    // Identity ordering deliberately has no correlation with path ordering.
    LayoutRecord(
        path: Data(String(format: "synthetic/repeated/long/component/cache/%04d/%08d", index / 1000, index).utf8),
        inode: Int64(bitPattern: UInt64(index + 1) &* 0x9e37_79b9_7f4a_7c15),
        allocated: Int64(4096 + index % 7 * 512))
}

private func hybridAll(_ view: HybridTreeExperiment, root: Data? = nil) throws -> [LayoutRecord] {
    var result: [LayoutRecord] = []
    var cursor: Data?
    while true {
        let page = try view.page(after: cursor, root: root, limit: 37)
        guard let last = page.last else { return result }
        result += page
        cursor = last.path
    }
}

private func rawSorted(_ records: [LayoutRecord]) -> [LayoutRecord] {
    records.sorted { $0.path.lexicographicallyPrecedes($1.path) }
}

private func oracleUpsert(_ record: LayoutRecord, into records: inout [Data: LayoutRecord]) {
    for (path, previous) in records where previous.device == record.device && previous.inode == record.inode {
        var updated = previous
        updated.allocated = record.allocated
        updated.links = record.links
        records[path] = updated
    }
    records[record.path] = record
}

@Test("Hybrid overlay, opaque copy, diff and atomic candidate commit agree with independent records")
func hybridRuntimeSemantics() throws {
    let root = hybridRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try StorageLayoutPrototype(url: root.appendingPathComponent("inventory.sqlite"), layout: .treeOrdered)
    for generation in 1...3 { try store.addGeneration(generation) }
    var initial = (0..<4096).map { hybridFixture($0) }
    initial[0].links = 2
    let alias = LayoutRecord(path: Data("opaque/".utf8) + Data([255, 128]), inode: initial[0].inode, links: 2)
    initial += [alias, LayoutRecord(path: Data(), inode: 7)]
    initial += ["opaque", "opaque-neighbor/file", "opaque.more/file", "opaque0/file"].enumerated().map {
        LayoutRecord(path: Data($0.element.utf8), inode: Int64($0.offset + 10))
    }
    for generation in [1, 2] {
        // Reverse insertion exercises IDs that do not follow lexical path order.
        let shuffled = Array(initial.reversed())
        for offset in stride(from: 0, to: shuffled.count, by: 1024) {
            try store.append(Array(shuffled[offset..<min(offset + 1024, shuffled.count)]), generation: generation)
        }
        try store.seal(generation)
    }
    try store.activate(1)
    let view = try HybridTreeExperiment(store: store, generation: 1)
    let unmodified = try HybridTreeExperiment(store: store, generation: 1, run: 99)
    let old = try HybridTreeExperiment(store: store, generation: 2)
    var expected = Dictionary(uniqueKeysWithValues: initial.map { ($0.path, $0) })
    for index in 0..<80 {
        var record = initial[index]
        record.allocated += 8192
        record.classification = "dailyDiskInternal"
        try view.stage(record)
        oracleUpsert(record, into: &expected)
    }
    // One object update must reach a surviving alias outside the changed path range.
    for index in 40..<100 {
        try view.remove(initial[index].path)
        expected.removeValue(forKey: initial[index].path)
    }
    var replacement = initial[200]
    replacement = LayoutRecord(path: replacement.path, inode: Int64.max, allocated: 12345)
    try view.stage(replacement)
    oracleUpsert(replacement, into: &expected)
    let fleeting = LayoutRecord(path: Data("opaque/transient".utf8), inode: Int64.min)
    try view.stage(fleeting)
    try view.remove(fleeting.path)
    let added = LayoutRecord(path: Data("opaque/added".utf8), inode: 99999, allocated: 7777)
    try view.stage(added)
    oracleUpsert(added, into: &expected)
    #expect(try hybridAll(view) == rawSorted(Array(expected.values)))
    #expect(try hybridAll(view, root: Data()) == rawSorted(Array(expected.values)))
    #expect(try hybridAll(unmodified) == rawSorted(initial))
    #expect(try hybridAll(old) == rawSorted(initial))
    let opaque = Array(expected.values).filter {
        $0.path == Data("opaque".utf8) || $0.path.starts(with: Data("opaque/".utf8))
    }
    #expect(try hybridAll(view, root: Data("opaque".utf8)) == rawSorted(opaque))
    #expect(
        try view.preserve(
            roots: [Data("opaque".utf8), Data("opaque/added".utf8), Data("opaque".utf8)],
            destination: 3) == opaque.count)
    let preserved = try HybridTreeExperiment(store: store, generation: 3)
    #expect(try hybridAll(preserved) == rawSorted(opaque))
    var actualChanges: Set<Data> = []
    let changes = try hybridDiff(old, view) { a, b in
        let path = (a ?? b)!.path
        #expect(a == initial.first { $0.path == path })
        #expect(b == expected[path])
        actualChanges.insert(path)
    }
    let previous = Dictionary(uniqueKeysWithValues: initial.map { ($0.path, $0) })
    let expectedChanges = Set(previous.keys).union(expected.keys).filter { previous[$0] != expected[$0] }
    #expect(actualChanges == expectedChanges)
    #expect(changes == expectedChanges.count)
    #expect(throws: LayoutExperimentError.self) {
        try view.commit(eventID: 11) { throw LayoutExperimentError.rollback }
    }
    #expect(try hybridAll(unmodified) == rawSorted(initial))
    #expect(try store.auditTreeOrder(generation: 1) == initial.count)
    #expect(try store.database.scalarInt64("SELECT event_id FROM checkpoints") == 10)
    try view.commit(eventID: 11)
    #expect(try hybridAll(unmodified) == rawSorted(Array(expected.values)))
    #expect(try store.auditTreeOrder(generation: 1) == expected.count)
    #expect(try store.database.scalarInt64("SELECT event_id FROM checkpoints") == 11)
    let byObject = Dictionary(grouping: Array(expected.values), by: \.inode)
    let canonical = byObject.values.map { rawSorted($0)[0].path }.sorted { $0.lexicographicallyPrecedes($1) }
    #expect(try store.canonicalPaths(generation: 1) == canonical)
    #expect(
        try store.database.scalarInt64("SELECT COUNT(*) FROM inventory_objects WHERE generation_id=1")
            == Int64(byObject.count))
    // Remove the old canonical alias, then introduce a lexically earlier alias
    // in another classification; only the candidate object must be re-attributed.
    try view.remove(alias.path)
    expected.removeValue(forKey: alias.path)
    try view.commit(eventID: 12)
    let replacementCanonical = try store.database.prepare(
        """
        SELECT classification FROM canonical_attributions WHERE generation_id=1 AND device_id=1 AND inode=?
        """)
    try replacementCanonical.bind(alias.inode, at: 1)
    #expect(try replacementCanonical.step())
    #expect(replacementCanonical.columnText(0) == "dailyDiskInternal")
    try replacementCanonical.reset()
    let earlierAlias = LayoutRecord(
        path: Data([1]), inode: alias.inode,
        allocated: expected[initial[0].path]!.allocated, links: 2)
    try view.stage(earlierAlias)
    oracleUpsert(earlierAlias, into: &expected)
    try view.commit(eventID: 13)
    #expect(try hybridAll(unmodified) == rawSorted(Array(expected.values)))
    #expect(try store.canonicalPaths(generation: 1).contains(earlierAlias.path))
    #expect(try store.auditTreeOrder(generation: 1) == expected.count)
    // The same run ID in a different generation cannot be consumed by this commit.
    #expect(try hybridAll(old) == rawSorted(initial))
    _ = try store.collectDictionary()
    #expect(try store.auditTreeOrder(generation: 2) == initial.count)
    #expect(try store.database.scalarText("PRAGMA integrity_check") == "ok")
    let foreign = try store.database.prepare("PRAGMA foreign_key_check")
    #expect(try !foreign.step())
}

@Test("Hybrid audit detects missing ordering rows, wrong raw paths and cycles despite valid foreign keys")
func hybridCorruptionAudit() throws {
    let root = hybridRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try StorageLayoutPrototype(url: root.appendingPathComponent("inventory.sqlite"), layout: .treeOrdered)
    try store.addGeneration(1)
    try store.append([hybridFixture(0)], generation: 1)
    try store.seal(1)
    try store.activate(1)
    for corruption in [
        "DELETE FROM path_order",
        "UPDATE path_order SET path=x'626164'",
        "UPDATE path_dictionary SET parent_id=id WHERE id=(SELECT path_id FROM inventory_paths LIMIT 1)",
    ] {
        do {
            try store.database.transaction {
                try store.database.execute(corruption)
                let foreign = try store.database.prepare("PRAGMA foreign_key_check")
                #expect(try !foreign.step())
                #expect(throws: HybridValidationError.self) { _ = try store.auditTreeOrder(generation: 1) }
                throw LayoutExperimentError.rollback
            }
        } catch LayoutExperimentError.rollback {}
        #expect(try store.auditTreeOrder(generation: 1) == 1)
        #expect(try store.database.scalarInt64("SELECT event_id FROM checkpoints") == 10)
    }
    let before = try store.database.scalarInt64("SELECT COUNT(*) FROM path_dictionary")
    try store.database.execute(
        """
        CREATE TRIGGER reject_order BEFORE INSERT ON path_order BEGIN SELECT RAISE(ABORT,'synthetic failure'); END;
        """)
    #expect(throws: (any Error).self) { try store.append([hybridFixture(100)], generation: 1) }
    #expect(try store.database.scalarInt64("SELECT COUNT(*) FROM path_dictionary") == before)
    #expect(try store.auditTreeOrder(generation: 1) == 1)
    try store.database.execute("DROP TRIGGER reject_order")
    try store.append([hybridFixture(100)], generation: 1)
    #expect(try store.auditTreeOrder(generation: 1) == 2)
}

@Test("Interrupted opaque copy leaves only staging batches and preserves active checkpoint")
func hybridOpaqueInterruption() throws {
    let root = hybridRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try StorageLayoutPrototype(url: root.appendingPathComponent("inventory.sqlite"), layout: .treeOrdered)
    try store.addGeneration(1)
    try store.addGeneration(2)
    for offset in stride(from: 0, to: 3072, by: 1024) {
        try store.append((offset..<offset + 1024).map { hybridFixture($0) }, generation: 1)
    }
    try store.seal(1)
    try store.activate(1)
    let view = try HybridTreeExperiment(store: store, generation: 1)
    #expect(throws: LayoutExperimentError.self) {
        _ = try view.preserve(roots: [Data(), Data("synthetic".utf8)], destination: 2) {
            throw LayoutExperimentError.rollback
        }
    }
    #expect(try store.auditTreeOrder(generation: 2) == 1024)
    #expect(try store.database.scalarInt64("SELECT active_generation_id FROM checkpoints") == 1)
    try store.deleteGeneration(2)
    _ = try store.collectDictionary()
    #expect(try store.auditTreeOrder(generation: 1) == 3072)
    let plan = try view.plan(root: Data("synthetic/repeated/long/component/cache/0001".utf8))
    #expect(plan.contains { $0.contains("SEARCH d") && $0.contains("path>? AND path<?") })
    #expect(plan.contains { $0.contains("SEARCH m") && $0.contains("path>? AND path<?") })
}

@Test(
    "Million-row hybrid overlay, opaque, diff, candidate commit and audit",
    .enabled(if: ProcessInfo.processInfo.environment["DAILYDISK_RUN_HYBRID_STRESS"] == "1"))
func millionRecordHybridValidation() throws {
    let root = hybridRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try StorageLayoutPrototype(url: root.appendingPathComponent("inventory.sqlite"), layout: .treeOrdered)
    var timings: [String: Double] = [:]
    let sampler = LayoutAllocationSampler(url: store.url)
    defer { _ = sampler.finish() }
    try store.addGeneration(1)
    sampler.setPhase("build-random-identities")
    var start = Date()
    for offset in stride(from: 0, to: 1_000_000, by: 1024) {
        try store.append((offset..<min(offset + 1024, 1_000_000)).map { hybridFixture($0) }, generation: 1)
    }
    try store.seal(1)
    try store.activate(1)
    timings["buildAndSeal"] = Date().timeIntervalSince(start)
    let view = try HybridTreeExperiment(store: store, generation: 1)
    for index in 0..<32 {
        var record = hybridFixture(index * 1000)
        record.allocated += 8192
        try view.stage(record)
        try view.remove(hybridFixture(index * 1000 + 1).path)
    }
    try store.database.execute("ANALYZE inventory_paths")
    sampler.setPhase("overlay")
    start = Date()
    for index in 0..<32 {
        let page = try view.page(root: Data(String(format: "synthetic/repeated/long/component/cache/%04d", index).utf8))
        #expect(page.count == 128)
        #expect(page[0].allocated == hybridFixture(index * 1000).allocated + 8192)
        #expect(page[1].path == hybridFixture(index * 1000 + 2).path)
    }
    timings["32NarrowLookups"] = Date().timeIntervalSince(start)
    #expect(timings["32NarrowLookups"]! < 10)
    start = Date()
    var cursor: Data?
    var count = 0
    while true {
        let page = try view.page(after: cursor, limit: 1024)
        guard let last = page.last else { break }
        count += page.count
        cursor = last.path
    }
    #expect(count == 1_000_000 - 32)
    timings["fullOverlayPaging"] = Date().timeIntervalSince(start)
    #expect(timings["fullOverlayPaging"]! < 60)
    sampler.setPhase("opaque-copy")
    try store.addGeneration(2)
    start = Date()
    let copied = try view.preserve(
        roots: [
            Data("synthetic/repeated/long/component/cache/0000".utf8),
            Data("synthetic/repeated/long/component/cache/0000/00000000".utf8),
        ],
        destination: 2)
    #expect(copied == 999)
    timings["opaqueCopy"] = Date().timeIntervalSince(start)
    #expect(timings["opaqueCopy"]! < 10)
    sampler.setPhase("diff")
    let original = try HybridTreeExperiment(store: store, generation: 1, run: 99)
    start = Date()
    var removed = 0
    var modified = 0
    let changes = try hybridDiff(original, view) { before, after in
        if after == nil {
            removed += 1
        } else {
            #expect(before!.path == after!.path)
            #expect(after!.allocated == before!.allocated + 8192)
            modified += 1
        }
    }
    #expect(changes == 64 && removed == 32 && modified == 32)
    timings["diff"] = Date().timeIntervalSince(start)
    #expect(timings["diff"]! < 60)
    sampler.setPhase("candidate-commit")
    start = Date()
    try view.commit(eventID: 11)
    timings["candidateCommit"] = Date().timeIntervalSince(start)
    #expect(timings["candidateCommit"]! < 10)
    #expect(try store.database.scalarInt64("SELECT COUNT(*) FROM inventory_objects WHERE generation_id=1") == 999968)
    #expect(
        try store.database.scalarInt64("SELECT COUNT(*) FROM canonical_attributions WHERE generation_id=1") == 999968)
    #expect(try store.database.scalarInt64("SELECT event_id FROM checkpoints") == 11)
    sampler.setPhase("explicit-audit")
    start = Date()
    #expect(try store.auditTreeOrder(generation: 1) == 999968)
    #expect(try store.auditTreeOrder(generation: 2) == 999)
    timings["audit"] = Date().timeIntervalSince(start)
    sampler.setPhase("gc-and-compact")
    try store.deleteGeneration(2)
    _ = try store.collectDictionary()
    let bytes = try store.compactBytes()
    #expect(try store.database.scalarText("PRAGMA integrity_check") == "ok")
    let foreign = try store.database.prepare("PRAGMA foreign_key_check")
    #expect(try !foreign.step())
    print("Hybrid validation RESULT seconds=\(timings), compactBytes=\(bytes), sampledPeaks=\(sampler.finish())")
}

@Test("Hybrid commits isolate other runs and generations and refuse inactive checkpoints")
func hybridRunIsolation() throws {
    let root = hybridRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try StorageLayoutPrototype(url: root.appendingPathComponent("inventory.sqlite"), layout: .treeOrdered)
    for generation in 1...2 {
        try store.addGeneration(generation)
        try store.append([hybridFixture(0), hybridFixture(1)], generation: generation)
        try store.seal(generation)
    }
    try store.activate(1)
    let current = try HybridTreeExperiment(store: store, generation: 1)
    let otherRun = try HybridTreeExperiment(store: store, generation: 1, run: 2)
    let otherGeneration = try HybridTreeExperiment(store: store, generation: 2)
    var first = hybridFixture(0)
    first.allocated = 11111
    try current.stage(first)
    var second = hybridFixture(1)
    second.allocated = 22222
    try otherRun.stage(second)
    var retained = hybridFixture(0)
    retained.allocated = 33333
    try otherGeneration.stage(retained)
    #expect(throws: HybridValidationError.self) { try otherGeneration.commit(eventID: 99) }
    #expect(try store.database.scalarInt64("SELECT event_id FROM checkpoints") == 10)
    let oldBase = try HybridTreeExperiment(store: store, generation: 2, run: 99)
    #expect(try hybridAll(oldBase) == [hybridFixture(0), hybridFixture(1)])
    try current.commit(eventID: 11)
    #expect(try hybridAll(otherRun) == [first, second])
    #expect(try hybridAll(otherGeneration) == [retained, hybridFixture(1)])
    #expect(try store.database.scalarInt64("SELECT COUNT(*) FROM experiment_mutations") == 2)
    #expect(try store.auditTreeOrder(generation: 1) == 2)
    #expect(try store.auditTreeOrder(generation: 2) == 2)
}
