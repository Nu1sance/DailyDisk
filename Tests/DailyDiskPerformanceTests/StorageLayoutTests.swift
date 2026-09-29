import Foundation
import Testing

@testable import DailyDiskStore

private let layoutPrefix = "synthetic/Library/Application Support/Example/Cache/RepeatedDirectoryPrefix/files"

private func layoutFixture(_ index: Int, generation: Int = 1) -> LayoutRecord {
    let changed = generation == 2 && index % 10 == 0
    return LayoutRecord(
        path: Data(
            (layoutPrefix + String(format: "/%06d/%08d", index / 1000, index) + (changed ? "-new.bin" : ".bin")).utf8),
        inode: Int64(index + 1 + (generation == 2 && index % 101 == 0 ? 2_000_000 : 0)),
        allocated: Int64(4096 + index % 3 * 512),
        classification: index % 5000 == 0 ? "dailyDiskInternal" : "ordinary")
}

private func prototypeRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("DailyDiskLayout-" + UUID().uuidString)
}

private func layoutAliases(count: Int, variant: Int) -> [LayoutRecord] {
    (0..<10).map { index in
        let original = layoutFixture(count - 1 - index, generation: variant)
        return LayoutRecord(
            path: Data((layoutPrefix + "/aliases/").utf8) + Data([255, UInt8(97 + index)]),
            inode: original.inode, allocated: original.allocated, classification: "dailyDiskInternal", links: 2)
    }
}

private func canonicalPaths(_ store: StorageLayoutPrototype, generation: Int) throws -> [Data] {
    try store.canonicalPaths(generation: generation)
}

@Test(
    "Layout prototypes preserve raw paths, aliases, generation isolation and protected activation",
    arguments: StorageLayout.allCases)
func layoutPrototypeSemantics(layout: StorageLayout) throws {
    let root = prototypeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try StorageLayoutPrototype(url: root.appendingPathComponent("inventory.sqlite"), layout: layout)
    try store.addGeneration(1)
    try store.addGeneration(2)
    let raw = Data([99, 97, 99, 104, 101, 47, 255, 128])
    let first = LayoutRecord(path: Data("cache/a".utf8), inode: Int64.min, links: 2)
    let alias = LayoutRecord(path: raw, inode: Int64.min, links: 2)
    let neighbors = ["cache-neighbor", "cache.more", "cache0"].enumerated().map {
        LayoutRecord(path: Data(($0.element + "/file").utf8), inode: Int64($0.offset + 10))
    }
    try store.append([alias, first] + neighbors, generation: 1)
    let replacement = LayoutRecord(
        path: first.path, inode: Int64.max, allocated: 8192, classification: "dailyDiskInternal")
    try store.append([replacement], generation: 2)
    try store.seal(1)
    try store.seal(2)
    try store.activate(1)
    #expect(try store.page(generation: 1, after: Data("cache/".utf8), before: Data("cache0".utf8), limit: 1) == [first])
    #expect(try store.page(generation: 1, after: first.path, before: Data("cache0".utf8)) == [alias])
    #expect(try store.page(generation: 2, after: Data("cache/".utf8), before: Data("cache0".utf8)) == [replacement])
    #expect(
        try canonicalPaths(store, generation: 1)
            == (neighbors.map(\.path) + [first.path]).sorted { $0.lexicographicallyPrecedes($1) })
    #expect(throws: (any Error).self) { try store.deleteGeneration(1) }
    #expect(try store.database.scalarInt64("SELECT COUNT(*) FROM inventory_paths") == 6)
    #expect(throws: LayoutExperimentError.self) {
        try store.database.transaction {
            try store.clearCanonical(1)
            try store.remove(raw, generation: 1)
            throw LayoutExperimentError.rollback
        }
    }
    #expect(try store.page(generation: 1, after: first.path, before: Data("cache0".utf8)) == [alias])
    try store.database.transaction { try store.remove(first.path, generation: 1) }
    try store.seal(1)
    #expect(try canonicalPaths(store, generation: 1).contains(raw))
    try store.activate(2, eventID: 11)
    try store.deleteGeneration(1)
    _ = try store.collectDictionary()
    #expect(try store.page(generation: 2, after: Data("cache/".utf8), before: Data("cache0".utf8)) == [replacement])
    #expect(try store.database.scalarInt64("SELECT event_id FROM checkpoints") == 11)
    #expect(try store.database.scalarText("PRAGMA integrity_check") == "ok")
    let foreign = try store.database.prepare("PRAGMA foreign_key_check")
    #expect(try !foreign.step())
}

@Test(
    "Dictionary GC preserves overlay and parent references and reclaims removed identities in bounded passes",
    arguments: [StorageLayout.sharedPaths, .treePaths, .treeOrdered])
func layoutDictionaryReferences(layout: StorageLayout) throws {
    let root = prototypeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try StorageLayoutPrototype(url: root.appendingPathComponent("inventory.sqlite"), layout: layout)
    try store.addGeneration(1)
    try store.append([LayoutRecord(path: Data("root/child/file".utf8), inode: 1)], generation: 1)
    let pinned = try store.intern(Data("root/overlay/file".utf8))
    try store.database.execute("INSERT INTO overlay_path_refs VALUES('synthetic-run',\(pinned))")
    try store.deleteGeneration(1)
    #expect(try store.collectDictionary() == 2)
    #expect(try store.database.scalarInt64("SELECT COUNT(*) FROM path_dictionary") == 3)
    #expect(try store.database.scalarInt64("SELECT id FROM path_dictionary WHERE id=\(pinned)") == pinned)
    try store.database.execute("DELETE FROM overlay_path_refs")
    #expect(try store.collectDictionary() == 3)
    #expect(try store.database.scalarInt64("SELECT COUNT(*) FROM path_dictionary") == 0)
}

@Test("Layout identity constraints reject cross-volume objects and paths", arguments: StorageLayout.allCases)
func layoutIdentityConstraints(layout: StorageLayout) throws {
    let root = prototypeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try StorageLayoutPrototype(url: root.appendingPathComponent("inventory.sqlite"), layout: layout)
    try store.addGeneration(1)
    try store.append([LayoutRecord(path: Data("root/file".utf8), inode: 1)], generation: 1)
    try store.database.execute("INSERT INTO volumes VALUES(\(layout.key(2)),'\(layout.externalID(2))')")
    #expect(throws: (any Error).self) {
        try store.database.execute("UPDATE inventory_paths SET volume_id=\(layout.key(2))")
    }
    #expect(throws: (any Error).self) {
        try store.database.execute("UPDATE inventory_objects SET volume_id=\(layout.key(2))")
    }
    try store.seal(1)
    #expect(throws: (any Error).self) {
        try store.database.execute("UPDATE canonical_attributions SET inode=2")
    }
    #expect(try canonicalPaths(store, generation: 1) == [Data("root/file".utf8)])
}

@Test("Sparse generation exposes dictionary paging work hidden by LIMIT and preserves identity seeks")
func layoutSparsePaging() throws {
    let root = prototypeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var work: [StorageLayout: Int32] = [:]
    for layout in StorageLayout.allCases {
        let store = try StorageLayoutPrototype(
            url: root.appendingPathComponent(layout.rawValue + "/inventory.sqlite"), layout: layout)
        try store.addGeneration(1)
        try store.addGeneration(2)
        for offset in stride(from: 0, to: 4096, by: 1024) {
            try store.append((offset..<offset + 1024).map { layoutFixture($0) }, generation: 1)
        }
        let sparse = LayoutRecord(path: Data((layoutPrefix + "/zz/only").utf8), inode: 99999)
        try store.append([sparse], generation: 2)
        try store.database.execute("ANALYZE inventory_paths")
        let lower = Data((layoutPrefix + "/").utf8)
        let upper = Data((layoutPrefix + "0").utf8)
        let plan = try store.plan(generation: 2, lower: lower, upper: upper)
        if layout != .treePaths {
            #expect(!plan.contains { $0.contains("SCAN ") || $0.contains("TEMP B-TREE") })
        }
        #expect(try store.page(generation: 2, after: lower, before: upper) == [sparse])
        var cursor = lower
        var offset = 0
        while true {
            let page = try store.page(generation: 1, after: cursor, before: upper)
            guard let last = page.last else { break }
            #expect(page == (offset..<offset + page.count).map { layoutFixture($0) })
            offset += page.count
            cursor = last.path
        }
        #expect(offset == 4096)
        let measured = try store.pageWork(generation: 2, lower: lower, upper: upper)
        #expect(measured.rows == 1)
        #expect(try store.pageWork(generation: 2, lower: Data(), upper: Data([255])).rows == 1)
        work[layout] = measured.steps
        let identity = try store.database.prepare(
            "EXPLAIN QUERY PLAN SELECT * FROM inventory_paths WHERE generation_id=\(layout.key(1)) AND device_id=1 AND inode=1"
        )
        var identityPlan = ""
        while try identity.step() { identityPlan += identity.columnText(3)! }
        #expect(identityPlan.contains("device_id=? AND inode=?"))
    }
    // A range-seek plan alone is insufficient: a global dictionary still probes
    // thousands of members that do not belong to this generation.
    #expect(work[.sharedPaths]! > work[.integerPaths]! * 100)
    #expect(work[.integerPaths]! < 200)
    #expect(work[.treeOrdered]! < 250)
}

@Test(
    "Million-row comparison of UUID, integer, shared-path and tree storage",
    .enabled(if: ProcessInfo.processInfo.environment["DAILYDISK_RUN_LAYOUT_STRESS"] == "1"))
func millionRecordLayoutComparison() throws {
    let root = prototypeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let selected = ProcessInfo.processInfo.environment["DAILYDISK_LAYOUT_ONLY"]
    for layout in StorageLayout.allCases where selected == nil || layout.rawValue == selected {
        try measureLayout(layout, root: root, count: 1_000_000)
    }
}

private func measureLayout(_ layout: StorageLayout, root: URL, count: Int) throws {
    let store = try StorageLayoutPrototype(
        url: root.appendingPathComponent(layout.rawValue + "/inventory.sqlite"), layout: layout)
    var metrics: [String: Double] = [:]
    var bytes: [String: Int64] = [:]
    let aliasCount = 10
    let sampler = LayoutAllocationSampler(url: store.url)
    defer { _ = sampler.finish() }
    for generation in 1...2 {
        try store.addGeneration(generation)
        sampler.setPhase("generation-\(generation)-build")
        let start = Date()
        for offset in stride(from: 0, to: count, by: 1024) {
            try store.append(
                (offset..<min(offset + 1024, count)).map { layoutFixture($0, generation: generation) },
                generation: generation)
        }
        try store.append(layoutAliases(count: count, variant: generation), generation: generation)
        metrics["build\(generation)"] = Date().timeIntervalSince(start)
        sampler.setPhase("generation-\(generation)-seal")
        let sealStart = Date()
        try store.seal(generation)
        metrics["seal\(generation)"] = Date().timeIntervalSince(sealStart)
        try store.activate(generation, eventID: 10 + generation)
        sampler.setPhase("generation-\(generation)-compact")
        let compactStart = Date()
        bytes["compact\(generation)"] = try store.compactBytes()
        metrics["compact\(generation)"] = Date().timeIntervalSince(compactStart)
        print("Layout \(layout.rawValue) generation \(generation): bytes=\(bytes), timings=\(metrics)")
    }
    try store.database.execute("ANALYZE inventory_paths")
    sampler.setPhase("incremental-and-paging")
    let narrowStart = Date()
    for index in 0..<(layout == .treePaths ? 1 : 32) {
        let directory = layoutPrefix + String(format: "/%06d", index)
        let page = try store.page(
            generation: 2, after: Data((directory + "/").utf8), before: Data((directory + "0").utf8))
        #expect(page.count == 128)
    }
    metrics["narrowLookups"] = Date().timeIntervalSince(narrowStart)
    if layout != .treePaths { #expect(metrics["narrowLookups"]! < 10) }
    let mutationStart = Date()
    try store.database.transaction {
        for index in 0..<32 { try store.remove(layoutFixture(index * 1000, generation: 2).path, generation: 2) }
    }
    metrics["incrementalRemovals"] = Date().timeIntervalSince(mutationStart)
    #expect(metrics["incrementalRemovals"]! < 10)
    let pageStart = Date()
    var cursor = Data((layoutPrefix + "/").utf8)
    let upper = Data((layoutPrefix + "0").utf8)
    var rows = 0
    while true {
        let page = try store.page(generation: 2, after: cursor, before: upper, limit: 1024)
        guard let last = page.last else { break }
        cursor = last.path
        rows += page.count
        if layout == .treePaths { break }
    }
    if layout == .treePaths {
        #expect(rows == 1024)
    } else {
        #expect(rows == count + aliasCount - 32)
    }
    metrics[layout == .treePaths ? "firstPageOnly" : "fullPaging"] = Date().timeIntervalSince(pageStart)
    if layout != .treePaths { #expect(metrics["fullPaging"]! < 60) }
    try store.addGeneration(3)
    try store.append([LayoutRecord(path: Data((layoutPrefix + "/zz/sparse").utf8), inode: 9_000_000)], generation: 3)
    let lower = Data((layoutPrefix + "/").utf8)
    let sparseStart = Date()
    let work = try store.pageWork(generation: 3, lower: lower, upper: upper)
    metrics["sparsePage"] = Date().timeIntervalSince(sparseStart)
    #expect(work.rows == 1)
    if layout == .sharedPaths {
        #expect(work.steps > 1_000_000)
    } else {
        #expect(work.steps < (layout == .treePaths ? 2000 : 250))
    }
    print(
        "Layout \(layout.rawValue) sparse VM steps=\(work.steps); plan=\(try store.plan(generation: 3, lower: lower, upper: upper))"
    )
    try store.deleteGeneration(3)
    sampler.setPhase("retired-cleanup")
    let cleanupStart = Date()
    try store.deleteGeneration(1)
    metrics["retiredCleanup"] = Date().timeIntervalSince(cleanupStart)
    sampler.setPhase("dictionary-gc")
    let gcStart = Date()
    let reclaimed = try store.collectDictionary()
    metrics["dictionaryGC"] = Date().timeIntervalSince(gcStart)
    sampler.setPhase("final-compact")
    bytes["finalCompact"] = try store.compactBytes()
    #expect(try store.database.scalarInt64("SELECT COUNT(*) FROM inventory_objects") == Int64(count - 32))
    #expect(try store.database.scalarInt64("SELECT COUNT(*) FROM canonical_attributions") == Int64(count - 32))

    // A second authoritative replacement must recreate dictionary entries that
    // the preceding GC removed, without retaining obsolete membership/objects.
    sampler.setPhase("replacement-build-and-seal")
    let replacementStart = Date()
    try store.addGeneration(4)
    for offset in stride(from: 0, to: count, by: 1024) {
        try store.append((offset..<min(offset + 1024, count)).map { layoutFixture($0) }, generation: 4)
    }
    try store.append(layoutAliases(count: count, variant: 1), generation: 4)
    try store.seal(4)
    try store.activate(4, eventID: 14)
    metrics["replacementBuildAndSeal"] = Date().timeIntervalSince(replacementStart)
    sampler.setPhase("replacement-cleanup-and-gc")
    let replacementCleanup = Date()
    try store.deleteGeneration(2)
    let replacedDictionaryRows = try store.collectDictionary()
    metrics["replacementCleanupAndGC"] = Date().timeIntervalSince(replacementCleanup)
    sampler.setPhase("replacement-compact")
    bytes["replacementCompact"] = try store.compactBytes()
    let peaks = sampler.finish()
    bytes["sampledPeak"] = peaks.values.max()
    #expect(try store.database.scalarInt64("SELECT COUNT(*) FROM inventory_objects") == Int64(count))
    #expect(try store.database.scalarInt64("SELECT COUNT(*) FROM canonical_attributions") == Int64(count))
    #expect(try store.database.scalarInt64("SELECT COUNT(*) FROM inventory_paths") == Int64(count + aliasCount))
    #expect(try store.database.scalarInt64("SELECT event_id FROM checkpoints") == 14)
    if layout.shared {
        #expect(
            try store.database.scalarInt64(
                """
                SELECT COUNT(*) FROM path_dictionary d
                WHERE NOT EXISTS(SELECT 1 FROM inventory_paths p WHERE p.path_id=d.id)
                  AND NOT EXISTS(SELECT 1 FROM overlay_path_refs r WHERE r.path_id=d.id)
                  AND NOT EXISTS(SELECT 1 FROM path_dictionary c WHERE c.parent_id=d.id)
                """) == 0)
    }
    #expect(try store.database.scalarText("PRAGMA integrity_check") == "ok")
    let foreign = try store.database.prepare("PRAGMA foreign_key_check")
    #expect(try !foreign.step())
    print("Layout sampled database/WAL/SHM peaks \(layout.rawValue): \(peaks)")
    print(
        "Layout RESULT \(layout.rawValue): bytes=\(bytes), seconds=\(metrics), sparseVM=\(work.steps), dictionaryRowsReclaimed=\(reclaimed)/\(replacedDictionaryRows)"
    )
}

@Test(
    "Tree layouts retain deep raw paths, wide sibling order and old views after whole-directory rename",
    arguments: [StorageLayout.integerPaths, .sharedPaths, .treePaths, .treeOrdered])
func layoutTreeRenames(layout: StorageLayout) throws {
    let root = prototypeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try StorageLayoutPrototype(url: root.appendingPathComponent("inventory.sqlite"), layout: layout)
    try store.addGeneration(1)
    try store.addGeneration(2)
    let deep = String(repeating: "long-component/", count: 80)
    var old = (0..<256).map {
        LayoutRecord(path: Data(("/old/wide/" + String(format: "%04d", $0)).utf8), inode: Int64($0 + 1))
    }
    old += ["a", "a.more", "a/file", "a0/file"].enumerated().map {
        LayoutRecord(path: Data(("/old/" + $0.element).utf8), inode: Int64(500 + $0.offset))
    }
    old += [
        LayoutRecord(path: Data(("/old/" + deep).utf8) + Data([255, 128, 1]), inode: 900, links: 2),
        LayoutRecord(path: Data("/old/alias".utf8), inode: 900, links: 2),
    ]
    let renamed = old.map {
        LayoutRecord(
            path: Data("/new".utf8) + $0.path.dropFirst(4), inode: $0.inode,
            allocated: $0.allocated, classification: $0.classification, device: $0.device, links: $0.links)
    }
    try store.append(Array(old.reversed()), generation: 1)
    try store.append(renamed, generation: 2)
    try store.seal(1)
    try store.seal(2)
    for (generation, expected) in [(1, old), (2, renamed)] {
        var cursor = Data()
        var actual: [LayoutRecord] = []
        while true {
            let page = try store.page(generation: generation, after: cursor, before: Data([255]), limit: 7)
            guard let last = page.last else { break }
            actual += page
            cursor = last.path
        }
        #expect(actual == expected.sorted { $0.path.lexicographicallyPrecedes($1.path) })
        let canonical = try store.canonicalPaths(generation: generation)
        #expect(canonical.count == expected.count - 1)
        #expect(canonical.contains(Data((generation == 1 ? "/old/alias" : "/new/alias").utf8)))
    }
    try store.activate(2)
    try store.deleteGeneration(1)
    _ = try store.collectDictionary()
    #expect(try store.canonicalPaths(generation: 2).count == renamed.count - 1)
    let foreign = try store.database.prepare("PRAGMA foreign_key_check")
    #expect(try !foreign.step())
}

@Test("Pure tree ordered paging reconstructs generation members before LIMIT")
func layoutTreePagingScaling() throws {
    let root = prototypeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for layout in [StorageLayout.treePaths, .treeOrdered] {
        let store = try StorageLayoutPrototype(
            url: root.appendingPathComponent(layout.rawValue + "/inventory.sqlite"), layout: layout)
        try store.addGeneration(1)
        var samples: [Int32] = []
        for end in [1024, 4096] {
            let start = end == 1024 ? 0 : 1024
            for offset in stride(from: start, to: end, by: 1024) {
                try store.append((offset..<offset + 1024).map { layoutFixture($0) }, generation: 1)
            }
            let work = try store.pageWork(generation: 1, lower: Data(), upper: Data([255]))
            #expect(work.rows == 128)
            samples.append(work.steps)
        }
        if layout == .treePaths {
            #expect(samples[1] > samples[0] * 3)
        } else {
            #expect(samples[1] < samples[0] * 2)
        }
        print("Tree dense paging scaling \(layout.rawValue): 1024/4096 rows, VM steps=\(samples)")
    }
}

@Test("Hybrid tree canonical lookup is identity-bounded before raw-path sorting")
func layoutTreeCanonicalPlan() throws {
    let root = prototypeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try StorageLayoutPrototype(url: root.appendingPathComponent("inventory.sqlite"), layout: .treeOrdered)
    try store.addGeneration(1)
    try store.append((0..<1024).map { layoutFixture($0) }, generation: 1)
    let query = try store.database.prepare(
        """
        EXPLAIN QUERY PLAN SELECT (\(store.canonicalCandidateSQL))
        FROM inventory_objects o WHERE o.generation_id=1
        """)
    var plan: [String] = []
    while try query.step() { plan.append(query.columnText(3)!) }
    #expect(plan.contains { $0.contains("SEARCH q") && $0.contains("device_id=? AND inode=?") })
    #expect(plan.contains { $0.contains("SEARCH d") && $0.contains("generation_id=? AND path_id=?") })
    #expect(!plan.contains { $0.contains("SEARCH d USING PRIMARY KEY (generation_id=?)") })
    try store.seal(1)
    #expect(try store.canonicalPaths(generation: 1) == (0..<1024).map { layoutFixture($0).path })
}
