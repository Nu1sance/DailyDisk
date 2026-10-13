import DailyDiskCore
import Foundation
import Testing

@testable import DailyDiskStore

private func subtreeResult(errors: [ScanErrorRecord] = []) -> InventoryScanResult {
    InventoryScanResult(
        coverage: ScanCoverage(
            visitedPathCount: 0, indexedObjectCount: 0,
            unreadablePathCount: UInt64(errors.filter { $0.kind.preservesOpaqueInventory }.count),
            transientErrorCount: 0), errors: errors)
}

@Test("Subtree reconcile preserves opaque ranges and staged data, removes only proven absences")
func subtreeReconcileOpaqueRanges() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let paths = [
        "tree/blocked/old", "tree/blocked-neighbor/removed", "tree/deleted", "tree/kept", "tree-neighbor/safe",
    ]
    let records = try paths.enumerated().map {
        try fixture.record(path: $0.element, inode: UInt64($0.offset + 1), logicalBytes: 100, allocatedBytes: 4096)
    }
    let baseline = try await establishBaseline(in: fixture, records: records)
    let run = ScanRun(kind: .incremental, reason: .manual, status: .running, startedAt: Date())
    try await fixture.store.begin(run: run)
    let target = InventoryMutationTarget.expectedActive(volumeID: fixture.volume.id)
    let staged = try fixture.record(path: "tree/blocked/new", inode: 77, logicalBytes: 200, allocatedBytes: 8192)
    try await fixture.store.stage(mutations: [.upsert(staged)], target: target, for: run.id)
    let error = ScanErrorRecord(
        runID: run.id, volumeID: fixture.volume.id, kind: .permissionDenied,
        path: try RelativePath(validating: "tree/blocked"), errorCode: 13, message: "Synthetic opaque subtree")
    _ = try await fixture.store.reconcileSubtree(
        root: RelativePath(validating: "tree"), target: target, for: run.id,
        observer: TaskOnlyScanWorkObserver()
    ) { consume in
        try await consume(InventoryRecordBatch(records: [records[3]]))
        return subtreeResult(errors: [error])
    }
    let actual = try await fixture.store.records(
        target: target, runID: run.id, paths: records.map(\.path.relativePath) + [staged.path.relativePath])
    #expect(Set(actual.map(\.path.relativePath.displayString)) == [paths[0], paths[3], paths[4], "tree/blocked/new"])
    #expect(try await fixture.store.state(for: fixture.volume.id)?.checkpoint == baseline.checkpoint)
    try await fixture.store.interrupt(runID: run.id, finishedAt: Date())
}

@Test("Failed or cancelled subtree reconciliation cannot change the committed baseline", arguments: [false, true])
func subtreeReconcileAborts(cancelled: Bool) async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let baseline = try await establishBaseline(in: fixture)
    let run = ScanRun(kind: .incremental, reason: .manual, status: .running, startedAt: Date())
    try await fixture.store.begin(run: run)
    let target = InventoryMutationTarget.expectedActive(volumeID: fixture.volume.id)
    let changed = try fixture.record(path: "Users/alice/file.dat", inode: 1, logicalBytes: 9000, allocatedBytes: 12288)
    do {
        _ = try await fixture.store.reconcileSubtree(
            root: .root, target: target, for: run.id,
            observer: TaskOnlyScanWorkObserver()
        ) { consume in
            try await consume(InventoryRecordBatch(records: [changed]))
            if cancelled { throw CancellationError() }
            throw POSIXError(.EIO)
        }
        Issue.record("Incomplete scan must not succeed")
    } catch is CancellationError {
        #expect(cancelled)
    } catch let error as POSIXError { #expect(!cancelled && error.code == .EIO) }
    #expect(try await fixture.store.state(for: fixture.volume.id)?.checkpoint == baseline.checkpoint)
    try await fixture.store.interrupt(runID: run.id, finishedAt: Date())
    let next = ScanRun(kind: .incremental, reason: .manual, status: .running, startedAt: Date())
    try await fixture.store.begin(run: next)
    #expect(
        try await fixture.store.records(target: target, runID: next.id, paths: [changed.path.relativePath])
            == baseline.records)
    try await fixture.store.interrupt(runID: next.id, finishedAt: Date())
}

@Test("Large unchanged subtree spills bounded keys but writes no inventory mutations")
func subtreeReconcileWriteBudget() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let records = try (0..<6000).map {
        try fixture.record(path: "tree/\($0)", inode: UInt64($0 + 1), logicalBytes: 100, allocatedBytes: 4096)
    }
    _ = try await establishBaseline(in: fixture, records: records)
    let run = ScanRun(kind: .incremental, reason: .manual, status: .running, startedAt: Date())
    try await fixture.store.begin(run: run)
    let start = ContinuousClock.now
    _ = try await fixture.store.reconcileSubtree(
        root: RelativePath(validating: "tree"),
        target: .expectedActive(volumeID: fixture.volume.id), for: run.id, observer: TaskOnlyScanWorkObserver()
    ) { consume in
        for offset in stride(from: 0, to: records.count, by: 512) {
            try await consume(InventoryRecordBatch(records: Array(records[offset..<min(offset + 512, records.count)])))
        }
        return subtreeResult()
    }
    let elapsed = start.duration(to: .now)
    let db = try SQLiteDatabase(url: fixture.databaseURL)
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM run_mutations") == 0)
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM run_object_mutations") == 0)
    #expect(elapsed < .seconds(10))
    print("6000 unchanged subtree records, zero inventory mutations:", elapsed)
    try await fixture.store.interrupt(runID: run.id, finishedAt: Date())
    // Compare with the previous delete-and-reinsert strategy on the same baseline.
    let legacyRun = ScanRun(kind: .incremental, reason: .manual, status: .running, startedAt: Date())
    try await fixture.store.begin(run: legacyRun)
    let legacyStart = ContinuousClock.now
    let target = InventoryMutationTarget.expectedActive(volumeID: fixture.volume.id)
    try await fixture.store.stageRemovalSubtree(
        root: RelativePath(validating: "tree"), target: target,
        for: legacyRun.id, observer: TaskOnlyScanWorkObserver())
    for offset in stride(from: 0, to: records.count, by: 512) {
        try await fixture.store.stage(
            mutations: records[offset..<min(offset + 512, records.count)].map { .upsert($0) },
            target: target, for: legacyRun.id)
    }
    print("6000 unchanged subtree records, previous delete/reinsert strategy:", legacyStart.duration(to: .now))
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM run_mutations") == 6000)
    try await fixture.store.interrupt(runID: legacyRun.id, finishedAt: Date())
}

@Test("Unreadable replacement directory cannot inherit old descendants")
func subtreeReconcileRejectsOpaqueReplacement() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    func directory(inode: UInt64) throws -> InventoryRecord {
        let source = try fixture.record(path: "tree/replaced", inode: inode, logicalBytes: 0, allocatedBytes: 0)
        return try InventoryRecord(
            object: InventoryObject(
                identity: source.object.identity, kind: .directory,
                footprint: source.object.footprint, linkCount: 1, modifiedAt: nil, metadataChangedAt: nil),
            path: source.path)
    }
    let old = try directory(inode: 1)
    let replacement = try directory(inode: 2)
    let child = try fixture.record(path: "tree/replaced/child", inode: 3, logicalBytes: 100, allocatedBytes: 4096)
    let baseline = try await establishBaseline(in: fixture, records: [old, child])
    let run = ScanRun(kind: .incremental, reason: .manual, status: .running, startedAt: Date())
    try await fixture.store.begin(run: run)
    let error = ScanErrorRecord(
        runID: run.id, volumeID: fixture.volume.id, kind: .permissionDenied,
        path: old.path.relativePath, errorCode: 13, message: "Synthetic replacement")
    await #expect(throws: IncrementalMutationError.incompleteSubtree) {
        _ = try await fixture.store.reconcileSubtree(
            root: RelativePath(validating: "tree"),
            target: .expectedActive(volumeID: fixture.volume.id), for: run.id, observer: TaskOnlyScanWorkObserver()
        ) { consume in
            try await consume(InventoryRecordBatch(records: [replacement]))
            return subtreeResult(errors: [error])
        }
    }
    try await fixture.store.interrupt(runID: run.id, finishedAt: Date())
    #expect(try await fixture.store.state(for: fixture.volume.id)?.checkpoint == baseline.checkpoint)
}
