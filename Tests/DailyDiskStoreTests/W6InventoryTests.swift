import DailyDiskCore
import Foundation
import Testing

@testable import DailyDiskStore

private struct W6Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("W6-\(UUID())")
    let volume = MonitoredVolume.ID("synthetic-w6")
    var url: URL { root.appendingPathComponent("prototype.sqlite") }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func record(_ raw: Data, inode: UInt64, bytes: Int64 = 4096, device: UInt64 = 1) throws -> InventoryRecord {
        let path = try RelativePath(validating: raw)
        let identity = FileIdentity(volumeID: volume, deviceID: device, inode: inode)
        return try InventoryRecord(
            object: InventoryObject(
                identity: identity, kind: .regular,
                footprint: FileFootprint(logicalBytes: bytes, allocatedBytes: bytes), linkCount: 2,
                modifiedAt: nil, metadataChangedAt: nil),
            path: InventoryPath(
                volumeID: volume, relativePath: path, parentPath: PathPolicy.parent(of: path), objectIdentity: identity)
        )
    }
    func commit(_ store: W6InventoryPrototype, records: [InventoryRecord], at: Date = Date()) async throws
        -> W6InventoryPrototype.Result
    {
        try await store.begin()
        try await store.observe(records)
        try await store.finishTraversal()
        let result = try await store.commit(checkpoint: Data([1]), at: at)
        try await store.markPublished(revision: result.revision)
        return result
    }
}

@Test("W6 unchanged scans write no inventory deltas and share exact historical values")
func w6UnchangedAndUndo() async throws {
    let f = W6Fixture()
    defer { f.remove() }
    let store = try W6InventoryPrototype(url: f.url, volume: f.volume)
    let a = try f.record(Data("a".utf8), inode: 1)
    let b = try f.record(Data("b".utf8), inode: 2)
    _ = try await f.commit(store, records: [a, b])
    let undo = try await store.counters().undo
    let same = try await f.commit(store, records: [b, a])
    #expect(same.changedObjects == 0 && same.changedPaths == 0)
    #expect(try await store.counters().undo == undo)
    let changed = try f.record(Data("a".utf8), inode: 1, bytes: 8192)
    let result = try await f.commit(store, records: [changed])
    #expect(result.changedObjects == 1 && result.changedPaths == 1)
    #expect(try await store.records() == [changed])
    #expect(try await store.record(path: a.path.relativePath, at: 1) == a)
    #expect(try await store.record(path: b.path.relativePath, at: 2) == b)
    #expect(try await store.record(path: b.path.relativePath, at: 3) == nil)
    #expect(try await store.verify())
}

@Test("W6 handles hardlinks, opaque boundaries, raw bytes and scan-time compensation")
func w6OpaqueAliasesAndCatchup() async throws {
    let f = W6Fixture()
    defer { f.remove() }
    let store = try W6InventoryPrototype(url: f.url, volume: f.volume)
    let alias = try f.record(Data("alias".utf8), inode: UInt64.max)
    let hidden = try f.record(Data("opaque/".utf8) + Data([255, 128]), inode: UInt64.max)
    let neighbor = try f.record(Data("opaque-neighbor".utf8), inode: 2)
    _ = try await f.commit(store, records: [alias, hidden, neighbor])
    try await store.begin()
    try await store.observe([alias])
    try await store.finishTraversal(opaqueRoots: [RelativePath(validating: "opaque")])
    let added = try f.record(Data("new".utf8), inode: 3)
    try await store.compensate(upserts: [added], removals: [alias.path.relativePath])
    _ = try await store.commit(checkpoint: Data([2]), at: Date())
    #expect(try await store.records() == [added, hidden])
    #expect(try await store.counters().objects == 2)
    #expect(try await store.verify())
}

@Test("W6 preserves observation order, reverts transient updates and safely rolls back activation")
func w6RollbackAndRevertedObservation() async throws {
    enum Injected: Error { case fault }
    let f = W6Fixture()
    defer { f.remove() }
    let store = try W6InventoryPrototype(url: f.url, volume: f.volume)
    let a = try f.record(Data("a".utf8), inode: 1)
    let b = try f.record(Data("a".utf8), inode: 1, bytes: 8192)
    _ = try await f.commit(store, records: [a])
    try await store.begin()
    try await store.observe([b])
    try await store.observe([a])
    try await store.finishTraversal()
    let unchanged = try await store.commit(checkpoint: Data([2]), at: Date())
    #expect(unchanged.changedObjects == 0)
    try await store.markPublished(revision: unchanged.revision)
    try await store.begin()
    try await store.observe([b])
    try await store.finishTraversal()
    await #expect(throws: Injected.self) {
        try await store.commit(checkpoint: Data([3]), at: Date(), beforeCommit: { throw Injected.fault })
    }
    #expect(try await store.records() == [a])
    #expect(try await store.verify())
    try await store.cancel()
    #expect(try await store.records() == [a])
}

@Test("W6 unpublished report pins history and expired undo becomes explicitly unavailable")
func w6RetentionAndPendingReport() async throws {
    let f = W6Fixture()
    defer { f.remove() }
    let store = try W6InventoryPrototype(url: f.url, volume: f.volume)
    let epoch = Date(timeIntervalSince1970: 100000)
    let a = try f.record(Data("a".utf8), inode: 1)
    _ = try await f.commit(store, records: [a], at: epoch)
    try await store.begin()
    try await store.finishTraversal()
    let result = try await store.commit(checkpoint: Data([2]), at: epoch.addingTimeInterval(10))
    await #expect(throws: StoreInvariantError.self) { try await store.begin() }
    try await store.prune(at: epoch.addingTimeInterval(100000))
    #expect(try await store.record(path: a.path.relativePath, at: 1) == a)
    try await store.markPublished(revision: result.revision)
    try await store.prune(at: epoch.addingTimeInterval(100000))
    #expect(try await store.counters().undo == 0)
    await #expect(throws: StoreInvariantError.self) { try await store.record(path: a.path.relativePath, at: 1) }
    #expect(try await store.verify())
}

@Test("W6 exact seen bitmap handles sparse IDs without allocating to the largest ID")
func w6SparseSeen() throws {
    var seen = W6SeenPaths()
    #expect(throws: StoreInvariantError.self) { try seen.insert(0) }
    #expect(throws: StoreInvariantError.self) { try seen.insert(-1) }
    try seen.insert(1)
    try seen.insert(Int64.max)
    #expect(seen.contains(1) && seen.contains(Int64.max))
    #expect(!seen.contains(2) && !seen.contains(Int64.max - 1))
    #expect(seen.allocatedBytes == 1024)
}

@Test("W6 isolated prototype refuses a production inventory")
func w6RefusesProductionDatabase() async throws {
    let f = try await StoreFixture()
    defer { f.removeFiles() }
    #expect(throws: StoreInvariantError.self) {
        try W6InventoryPrototype(url: f.databaseURL, volume: f.volume.id)
    }
}

private func w6LeaveInterrupted(_ f: W6Fixture, baseline: InventoryRecord, pending: InventoryRecord) async throws {
    let store = try W6InventoryPrototype(url: f.url, volume: f.volume)
    _ = try await f.commit(store, records: [baseline])
    try await store.begin()
    try await store.observe([pending])
}

@Test("W6 restart discards uncommitted traversal and cannot reuse a lost seen bitmap")
func w6InterruptedRestart() async throws {
    let f = W6Fixture()
    defer { f.remove() }
    let old = try f.record(Data("old".utf8), inode: 1)
    let new = try f.record(Data("new".utf8), inode: 2)
    try await w6LeaveInterrupted(f, baseline: old, pending: new)
    let reopened = try W6InventoryPrototype(url: f.url, volume: f.volume)
    #expect(try await reopened.records() == [old])
    await #expect(throws: StoreInvariantError.self) { try await reopened.finishTraversal() }
    let result = try await f.commit(reopened, records: [old])
    #expect(result.changedObjects == 0 && result.changedPaths == 0)
    #expect(try await reopened.verify())
}

@Test("W6 rejects continuing after a failed observation batch")
func w6FailedBatchPoisoned() async throws {
    let f = W6Fixture()
    defer { f.remove() }
    let store = try W6InventoryPrototype(url: f.url, volume: f.volume)
    let baseline = try f.record(Data("base".utf8), inode: 1)
    _ = try await f.commit(store, records: [baseline])
    try await store.begin()
    let alienIdentity = FileIdentity(volumeID: MonitoredVolume.ID("alien"), deviceID: 1, inode: 9)
    let alien = try InventoryRecord(
        object: InventoryObject(
            identity: alienIdentity, kind: .regular,
            footprint: FileFootprint(logicalBytes: 1, allocatedBytes: 1), linkCount: 1, modifiedAt: nil,
            metadataChangedAt: nil),
        path: InventoryPath(
            volumeID: alienIdentity.volumeID, relativePath: RelativePath(validating: "alien"),
            parentPath: .root, objectIdentity: alienIdentity))
    await #expect(throws: StoreInvariantError.self) { try await store.observe([baseline, alien]) }
    await #expect(throws: StoreInvariantError.self) { try await store.finishTraversal() }
    try await store.cancel()
    #expect(try await store.records() == [baseline])
}
