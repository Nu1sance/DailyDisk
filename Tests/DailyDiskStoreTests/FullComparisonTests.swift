import DailyDiskCore
import Foundation
import Testing

@testable import DailyDiskStore

private func fullReuseCommit(
    _ f: StoreFixture, baseline: BaselineResult, records: [InventoryRecord], opaque: [RelativePath] = [],
    batchSize: Int = 1024, at: TimeInterval = 40
) async throws -> ScanCommit {
    let run = ScanRun(kind: .full, reason: .dailySchedule, status: .running, startedAt: Date(timeIntervalSince1970: 30))
    try await f.store.begin(run: run)
    #expect(try await f.store.beginFullComparison(volumeID: f.volume.id, runID: run.id))
    for offset in stride(from: 0, to: records.count, by: batchSize) {
        try await f.store.observeFullComparison(
            records: Array(records[offset..<min(offset + batchSize, records.count)]), volumeID: f.volume.id,
            runID: run.id)
    }
    try await f.store.finishFullComparison(
        opaqueRoots: opaque, volumeID: f.volume.id, runID: run.id, observer: TaskOnlyScanWorkObserver())
    let target = InventoryMutationTarget.expectedActive(volumeID: f.volume.id)
    try await f.store.finalizeCanonicalAttribution(target: target, runID: run.id, consume: { _ in })
    let changes = try await f.store.deriveSnapshotChanges(
        authoritative: target, runID: run.id, observer: TaskOnlyScanWorkObserver())
    let checkpoint = Checkpoint(
        volumeID: f.volume.id, eventStoreUUID: f.volume.eventStoreUUID,
        lastCommittedEventID: 20, activeGenerationID: baseline.generation.id,
        topologyFingerprint: f.volume.topologyFingerprint,
        lastSuccessfulIncrementalAt: nil, lastSuccessfulFullScanAt: Date(timeIntervalSince1970: at))
    return try ScanCommit(
        runID: run.id, runKind: .full, scope: f.scope, volumeID: f.volume.id,
        activatedGenerationID: nil, previousCheckpoint: baseline.checkpoint, checkpoint: checkpoint,
        eventFence: EventCursorFence(
            volumeID: f.volume.id, eventStoreUUID: f.volume.eventStoreUUID,
            highestFullyDeliveredEventID: 20, phase: .liveFlush, trust: .trusted),
        changes: changes, storageSamples: [f.sample(usedBytes: 500000, at: at)], snapshotSamples: [],
        comparesSnapshots: true, reusesActiveInventory: true)
}

@Test("Production W6 zero-change run does not update compact inventory or create another generation")
func fullReuseZeroWrites() async throws {
    let f = try await StoreFixture()
    defer { f.removeFiles() }
    let baseline = try await establishBaseline(in: f)
    let db = try SQLiteDatabase(url: f.databaseURL)
    for table in ["hybrid_objects", "hybrid_paths", "hybrid_order", "hybrid_canonical"] {
        for operation in ["INSERT", "UPDATE", "DELETE"] {
            try db.execute(
                "CREATE TRIGGER reject_\(table)_\(operation) BEFORE \(operation) ON \(table) BEGIN SELECT RAISE(ABORT,'unchanged inventory was written'); END"
            )
        }
    }
    let commit = try await fullReuseCommit(f, baseline: baseline, records: baseline.records)
    #expect(commit.changes.isEmpty)
    try await f.store.commit(commit, finishedAt: Date(timeIntervalSince1970: 40))
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM inventory_generations") == 1)
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM inventory_reuse_old_objects") == 0)
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM inventory_reuse_old_paths") == 0)
    #expect(try await f.store.state(for: f.volume.id)?.checkpoint == commit.checkpoint)
}

@Test("Production W6 keeps deleted and modified old values and rolls back checkpoint, undo and inventory together")
func fullReuseRollbackAndHistory() async throws {
    let f = try await StoreFixture()
    defer { f.removeFiles() }
    let old = try f.record(path: "old", inode: 1, logicalBytes: 100, allocatedBytes: 128)
    let gone = try f.record(path: "gone", inode: 2, logicalBytes: 50, allocatedBytes: 64)
    let baseline = try await establishBaseline(in: f, records: [old, gone])
    let changed = try f.record(path: "old", inode: 1, logicalBytes: 200, allocatedBytes: 256)
    let commit = try await fullReuseCommit(f, baseline: baseline, records: [changed])
    let db = try SQLiteDatabase(url: f.databaseURL)
    try db.execute("CREATE TRIGGER fail_activation BEFORE UPDATE ON checkpoints BEGIN SELECT RAISE(ABORT,'fault'); END")
    await #expect(throws: SQLiteStoreError.self) {
        try await f.store.commit(commit, finishedAt: Date(timeIntervalSince1970: 40))
    }
    #expect(try await f.store.state(for: f.volume.id)?.checkpoint == baseline.checkpoint)
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM inventory_reuse_history") == 0)
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM hybrid_paths") == 2)
    try db.execute("DROP TRIGGER fail_activation")
    try await f.store.commit(commit, finishedAt: Date(timeIntervalSince1970: 40))
    #expect(try await f.store.retainedRecord(before: commit.runID, path: old.path.relativePath) == old)
    #expect(try await f.store.retainedRecord(before: commit.runID, path: gone.path.relativePath) == gone)
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM hybrid_paths") == 1)
    #expect(try db.verifyHybridOrdering() == 0)
    // Missing report prevents retention deletion even long after the 24h window.
    try await f.store.pruneReuseHistory(at: Date().addingTimeInterval(172800))
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM inventory_reuse_history") == 1)
}

@Test("Production W6 honors alias observation order and opaque path boundaries", arguments: [1, 1024])
func fullReuseAliasesAndOpaque(batchSize: Int) async throws {
    let f = try await StoreFixture()
    defer { f.removeFiles() }
    let a = try f.record(path: "a", inode: 1, logicalBytes: 100, allocatedBytes: 128, linkCount: 2)
    let b = try f.record(path: "b", inode: 1, logicalBytes: 100, allocatedBytes: 128, linkCount: 2)
    let opaque = try f.record(path: "opaque/hidden", inode: 3, logicalBytes: 100, allocatedBytes: 128)
    let adjacent = try f.record(path: "opaque-neighbor", inode: 4, logicalBytes: 100, allocatedBytes: 128)
    let baseline = try await establishBaseline(in: f, records: [a, b, opaque, adjacent])
    let temporary = try f.record(path: "a", inode: 1, logicalBytes: 200, allocatedBytes: 256, linkCount: 2)
    let commit = try await fullReuseCommit(
        f, baseline: baseline, records: [temporary, b],
        opaque: [
            RelativePath(validating: "opaque"), RelativePath(validating: "opaque-hidden"),
            RelativePath(validating: "opaque/hidden/deeper"), RelativePath(validating: "opaque"),
        ],
        batchSize: batchSize)
    #expect(commit.changes.count == 1)
    #expect(commit.changes.first?.pathBefore == adjacent.path.relativePath)
    try await f.store.commit(commit, finishedAt: Date(timeIntervalSince1970: 40))
    let db = try SQLiteDatabase(url: f.databaseURL)
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM hybrid_paths") == 3)
    #expect(try db.scalarInt64("SELECT allocated_bytes FROM hybrid_objects WHERE inode=1") == 128)
    #expect(try db.verifyHybridOrdering() == 0)
}

private func publishReuse(_ f: StoreFixture, commit: ScanCommit, previous: StorageSample) async throws {
    let sample = try #require(commit.storageSamples.first)
    let report = try DailyReport(
        runID: commit.runID, generatedAt: sample.sampledAt, storageDomainID: f.scope.domain.id,
        accounting: SpaceAccounting.summarize(
            changes: commit.changes, scope: f.scope, previousSample: previous, currentSample: sample),
        reconciliation: nil,
        coverage: ScanCoverage(
            visitedPathCount: 1, indexedObjectCount: 1, unreadablePathCount: 0, transientErrorCount: 0),
        largestGrowth: [], largestShrinkage: [], diagnostics: [])
    try await f.store.commitReport(
        ReportCommit(
            runID: commit.runID, scope: f.scope, changes: commit.changes, previousStorageSample: previous,
            currentStorageSample: sample, previousOverheadSample: nil, currentOverheadSample: nil, report: report))
}

@Test("Production W6 reconstructs retained versions across deletion, inode replacement and clock reversal")
func fullReuseHistoryChain() async throws {
    let f = try await StoreFixture()
    defer { f.removeFiles() }
    let original = try f.record(path: "same", inode: 1, logicalBytes: 100, allocatedBytes: 128)
    let baseline = try await establishBaseline(in: f, records: [original])
    let first = try await fullReuseCommit(f, baseline: baseline, records: [])
    try await f.store.commit(first, finishedAt: Date(timeIntervalSince1970: 40))
    try await publishReuse(f, commit: first, previous: baseline.sample)
    let intermediate = BaselineResult(
        run: baseline.run, generation: baseline.generation, checkpoint: first.checkpoint,
        records: [], changes: first.changes, sample: first.storageSamples[0])
    let replacement = try f.record(path: "same", inode: 2, logicalBytes: 200, allocatedBytes: 256)
    let second = try await fullReuseCommit(f, baseline: intermediate, records: [replacement], at: 60)
    try await f.store.commit(second, finishedAt: Date(timeIntervalSince1970: 60))
    try await publishReuse(f, commit: second, previous: intermediate.sample)
    #expect(try await f.store.retainedRecord(before: first.runID, path: original.path.relativePath) == original)
    #expect(try await f.store.retainedRecord(before: second.runID, path: original.path.relativePath) == nil)
    let db = try SQLiteDatabase(url: f.databaseURL)
    // A backwards clock makes the later version appear older. Retention must
    // preserve the entire suffix required to reconstruct the newer-dated first version.
    try db.execute("UPDATE inventory_reuse_history SET retired_at=CASE version WHEN 1 THEN 200000 ELSE 0 END")
    try await f.store.pruneReuseHistory(at: Date(timeIntervalSince1970: 200001))
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM inventory_reuse_history") == 2)
    #expect(try await f.store.retainedRecord(before: first.runID, path: original.path.relativePath) == original)
    try await f.store.pruneReuseHistory(at: Date(timeIntervalSince1970: 300000))
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM inventory_reuse_history") == 0)
    await #expect(throws: StoreInvariantError.self) {
        _ = try await f.store.retainedRecord(before: first.runID, path: original.path.relativePath)
    }
}

@Test("Production W6 mixed churn equals a fresh full generation's inventory and signed semantic ledger")
func fullReuseFreshGenerationOracle() async throws {
    let reuse = try await StoreFixture()
    let control = try await StoreFixture()
    defer {
        reuse.removeFiles()
        control.removeFiles()
    }
    var before: [InventoryRecord] = []
    var after: [InventoryRecord] = []
    for i in 0..<256 {
        before.append(try reuse.record(path: "old/\(i)", inode: UInt64(i + 1), logicalBytes: 100, allocatedBytes: 128))
        if i % 4 == 0 { continue }
        let name = i % 4 == 1 ? "renamed/\(i)" : "old/\(i)"
        after.append(
            try reuse.record(
                path: name, inode: UInt64(i + 1), logicalBytes: i % 4 == 2 ? 200 : 100,
                allocatedBytes: i % 4 == 2 ? 256 : 128))
    }
    let raw = try RelativePath(validating: Data([0x78, 0xff]))
    let alias = try reuse.record(path: "alias", inode: 900, logicalBytes: 77, allocatedBytes: 128, linkCount: 2)
    let rawAlias = try InventoryRecord(
        object: alias.object,
        path: InventoryPath(
            volumeID: reuse.volume.id, relativePath: raw, parentPath: .root, objectIdentity: alias.object.identity))
    before += [alias, rawAlias]
    after += [rawAlias, try reuse.record(path: "new", inode: 901, logicalBytes: 11, allocatedBytes: 64)]
    let baseline = try await establishBaseline(in: reuse, records: before)
    _ = try await establishBaseline(in: control, records: before)
    let commit = try await fullReuseCommit(reuse, baseline: baseline, records: after, batchSize: 17)
    let run = ScanRun(kind: .full, reason: .dailySchedule, status: .running, startedAt: Date())
    try await control.store.begin(run: run)
    let generation = try await control.store.createStagingGeneration(
        volumeID: control.volume.id, runID: run.id, at: run.startedAt)
    try await control.store.append(records: after, to: generation.id)
    let target = InventoryMutationTarget.stagingGeneration(generation.id)
    try await control.store.finalizeCanonicalAttribution(target: target, runID: run.id, consume: { _ in })
    let expected = try await control.store.deriveSnapshotChanges(
        authoritative: target, runID: run.id, observer: TaskOnlyScanWorkObserver())
    let normalized = try expected.map { value in
        try ChangeRecord(
            runID: commit.runID, volumeID: value.volumeID, objectIdentity: value.objectIdentity,
            kind: value.kind, pathBefore: value.pathBefore, pathAfter: value.pathAfter,
            transferID: value.transferID, effect: value.effect, classification: value.classification)
    }
    #expect(commit.changes.count == normalized.count)
    #expect(commit.changes.allSatisfy { normalized.contains($0) })
    let paths = Array(Set((before + after).map(\.path.relativePath)))
    let actualRecords = try await reuse.store.records(
        target: .expectedActive(volumeID: reuse.volume.id), runID: commit.runID, paths: paths)
    let expectedRecords = try await control.store.records(target: target, runID: run.id, paths: paths)
    #expect(actualRecords == expectedRecords)
    try await reuse.store.commit(commit, finishedAt: Date(timeIntervalSince1970: 40))
    let db = try SQLiteDatabase(url: reuse.databaseURL)
    #expect(try db.verifyHybridOrdering() == 0)
    for record in before {
        #expect(try await reuse.store.retainedRecord(before: commit.runID, path: record.path.relativePath) == record)
    }
}

@Test("Production W6 metadata-only changes reuse paths, order and canonical rows")
func fullReuseObjectOnlyWrites() async throws {
    let f = try await StoreFixture()
    defer { f.removeFiles() }
    let original = try f.record(path: "unchanged-path", inode: 1, logicalBytes: 100, allocatedBytes: 128)
    let baseline = try await establishBaseline(in: f, records: [original])
    let db = try SQLiteDatabase(url: f.databaseURL)
    for table in ["hybrid_paths", "hybrid_order", "hybrid_canonical"] {
        for operation in ["INSERT", "UPDATE", "DELETE"] {
            try db.execute(
                "CREATE TRIGGER object_only_\(table)_\(operation) BEFORE \(operation) ON \(table) BEGIN SELECT RAISE(ABORT,'unchanged path was written'); END"
            )
        }
    }
    let changed = try f.record(path: "unchanged-path", inode: 1, logicalBytes: 200, allocatedBytes: 256)
    let commit = try await fullReuseCommit(f, baseline: baseline, records: [changed])
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM run_mutations") == 0)
    #expect(commit.changes.count == 1)
    try await f.store.commit(commit, finishedAt: Date(timeIntervalSince1970: 40))
    #expect(try db.scalarInt64("SELECT allocated_bytes FROM hybrid_objects WHERE inode=1") == 256)
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM inventory_reuse_old_paths") == 0)
    #expect(try await f.store.retainedRecord(before: commit.runID, path: original.path.relativePath) == original)
}

@Test("Production W6 failed observation poisons the comparison and interruption preserves the baseline")
func fullReuseFailedBatch() async throws {
    let f = try await StoreFixture()
    defer { f.removeFiles() }
    let old = try f.record(path: "old", inode: 1, logicalBytes: 100, allocatedBytes: 128)
    let baseline = try await establishBaseline(in: f, records: [old])
    let run = ScanRun(kind: .full, reason: .dailySchedule, status: .running, startedAt: Date())
    try await f.store.begin(run: run)
    #expect(try await f.store.beginFullComparison(volumeID: f.volume.id, runID: run.id))
    let db = try SQLiteDatabase(url: f.databaseURL)
    try db.execute(
        "CREATE TRIGGER fail_batch BEFORE INSERT ON run_object_mutations WHEN NEW.inode=2 BEGIN SELECT RAISE(ABORT,'injected write failure'); END"
    )
    let changed = try f.record(path: "old", inode: 1, logicalBytes: 200, allocatedBytes: 256)
    let added = try f.record(path: "added", inode: 2, logicalBytes: 100, allocatedBytes: 128)
    await #expect(throws: SQLiteStoreError.self) {
        try await f.store.observeFullComparison(records: [changed, added], volumeID: f.volume.id, runID: run.id)
    }
    try db.execute("DROP TRIGGER fail_batch")
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM run_object_mutations") == 0)
    await #expect(throws: StoreInvariantError.self) {
        try await f.store.finishFullComparison(
            opaqueRoots: [], volumeID: f.volume.id, runID: run.id,
            observer: TaskOnlyScanWorkObserver())
    }
    try await f.store.recoverInterruptedRuns(at: Date())
    #expect(try await f.store.state(for: f.volume.id)?.checkpoint == baseline.checkpoint)
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM run_targets") == 0)
    #expect(try db.scalarInt64("SELECT COUNT(*) FROM inventory_reuse_history") == 0)
    let retry = try await fullReuseCommit(f, baseline: baseline, records: [old])
    #expect(retry.changes.isEmpty)
    try await f.store.commit(retry, finishedAt: Date(timeIntervalSince1970: 40))
}

@Test("Production W6 classification transfer remains balanced without changing total allocation")
func fullReuseClassificationTransfer() async throws {
    let f = try await StoreFixture()
    defer { f.removeFiles() }
    let old = try f.record(path: "classification", inode: 1, logicalBytes: 100, allocatedBytes: 128)
    let baseline = try await establishBaseline(in: f, records: [old])
    let changed = try f.record(
        path: "classification", inode: 1, logicalBytes: 100, allocatedBytes: 128,
        classification: .dailyDiskInternal)
    let commit = try await fullReuseCommit(f, baseline: baseline, records: [changed])
    #expect(commit.changes.count == 2)
    #expect(commit.changes.reduce(Int64(0)) { $0 + $1.allocatedDelta } == 0)
    #expect(commit.changes.filter { $0.classification == .ordinary }.map(\.allocatedDelta) == [-128])
    #expect(commit.changes.filter { $0.classification == .dailyDiskInternal }.map(\.allocatedDelta) == [128])
    try ChangeSetValidator.validateAttributionTransfers(in: commit.changes)
    try await f.store.commit(commit, finishedAt: Date(timeIntervalSince1970: 40))
    #expect(try await f.store.retainedRecord(before: commit.runID, path: old.path.relativePath) == old)
}
