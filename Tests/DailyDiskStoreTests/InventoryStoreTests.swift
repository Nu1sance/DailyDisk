import DailyDiskCore
import Foundation
import Testing

@testable import DailyDiskStore

@Test("A temporary file created and removed within one replay has no net change")
func transientReplayObjectHasNoEndpoints() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let baseline = try await establishBaseline(in: fixture)
    let run = ScanRun(kind: .incremental, reason: .manual, status: .running, startedAt: Date())
    try await fixture.store.begin(run: run)
    let target = InventoryMutationTarget.expectedActive(volumeID: fixture.volume.id)
    let temporary = try fixture.record(path: "temp/short-lived", inode: 42, logicalBytes: 50, allocatedBytes: 64)
    try await fixture.store.stage(mutations: [.upsert(temporary)], target: target, for: run.id)
    try await fixture.store.stage(
        mutations: [.remove(volumeID: fixture.volume.id, path: temporary.path.relativePath)],
        target: target, for: run.id
    )
    try await fixture.store.finalizeCanonicalAttribution(target: target, runID: run.id, consume: { _ in })
    let changes = try await fixture.store.deriveIncrementalChanges(target: target, runID: run.id)
    #expect(changes.isEmpty)
    #expect(try await fixture.store.state(for: fixture.volume.id)?.checkpoint == baseline.checkpoint)
}

@Test("Populated inventories use identity bounds for foreign-key orphan cleanup")
func orphanCleanupUsesIdentityIndex() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let run = ScanRun(kind: .full, reason: .manual, status: .running, startedAt: Date())
    try await fixture.store.begin(run: run)
    let generation = try await fixture.store.createStagingGeneration(
        volumeID: fixture.volume.id, runID: run.id, at: run.startedAt
    )
    let records = try (1...5_000).map { inode in
        try fixture.record(path: "files/\(inode)", inode: UInt64(inode), logicalBytes: 1, allocatedBytes: 1)
    }
    try await fixture.store.append(records: records, to: generation.id)
    try await fixture.store.finalizeCanonicalAttribution(
        target: .stagingGeneration(generation.id), runID: run.id, consume: { _ in }
    )
    let database = try SQLiteDatabase(url: fixture.databaseURL, readOnly: true)
    let plan = try database.prepare(
        "EXPLAIN QUERY PLAN DELETE FROM inventory_objects WHERE generation_id = ? AND device_id = ? AND inode = ?"
    )
    try plan.bind(generation.id.rawValue.uuidString, at: 1)
    try plan.bind(Int64(1), at: 2)
    try plan.bind(Int64(1), at: 3)
    var boundedForeignKeyLookup = false
    while try plan.step() {
        let detail = plan.columnText(3) ?? ""
        if detail.contains("inventory_paths"), detail.contains("device_id=?"), detail.contains("inode=?") {
            boundedForeignKeyLookup = true
        }
    }
    #expect(boundedForeignKeyLookup)
}

@Test("Canonical pagination retains every identity across pages and signed inode boundaries")
func canonicalPaginationPreservesIdentities() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let run = ScanRun(kind: .full, reason: .manual, status: .running, startedAt: Date())
    try await fixture.store.begin(run: run)
    let generation = try await fixture.store.createStagingGeneration(
        volumeID: fixture.volume.id, runID: run.id, at: run.startedAt
    )
    let inodes = (1...2_050).map { UInt64($0) } + [UInt64.max]
    let records = try inodes.map { inode in
        try fixture.record(path: "files/\(inode)", inode: inode, logicalBytes: 1, allocatedBytes: 1)
    }
    try await fixture.store.append(records: records, to: generation.id)
    let collector = CanonicalCollector()
    try await fixture.store.finalizeCanonicalAttribution(
        target: .stagingGeneration(generation.id), runID: run.id,
        consume: { await collector.append($0) }
    )
    let values = await collector.values
    #expect(values.count == inodes.count)
    #expect(Set(values.map(\.objectIdentity.inode)) == Set(inodes))
}

@Test("Inventory preserves UInt64 identity bits and non-UTF-8 path bytes")
func inventoryPreservesRawBoundaryValues() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let run = ScanRun(
        kind: .full,
        reason: .manual,
        status: .running,
        startedAt: Date(timeIntervalSince1970: 1)
    )
    try await fixture.store.begin(run: run)
    let generation = try await fixture.store.createStagingGeneration(
        volumeID: fixture.volume.id,
        runID: run.id,
        at: run.startedAt
    )
    let rawPath = try RelativePath(validating: Data([0x66, 0x80, 0x6F]))
    let identity = FileIdentity(volumeID: fixture.volume.id, deviceID: .max, inode: .max)
    let object = InventoryObject(
        identity: identity,
        kind: .regular,
        footprint: FileFootprint.zero,
        linkCount: .max,
        modifiedAt: nil,
        metadataChangedAt: nil
    )
    let path = try InventoryPath(
        volumeID: fixture.volume.id,
        relativePath: rawPath,
        parentPath: .root,
        objectIdentity: identity
    )
    let record = try InventoryRecord(object: object, path: path)
    try await fixture.store.append(records: [record], to: generation.id)

    let decoded = try await fixture.store.records(
        target: .stagingGeneration(generation.id),
        runID: run.id,
        paths: [rawPath]
    )
    #expect(decoded == [record])
}

@Test("A full scan atomically activates an indexed generation")
func fullScanActivatesGeneration() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let baseline = try await establishBaseline(in: fixture)

    let state = try #require(try await fixture.store.state(for: fixture.volume.id))
    #expect(state.activeGeneration.id == baseline.generation.id)
    #expect(state.checkpoint == baseline.checkpoint)

    let database = try SQLiteDatabase(url: fixture.databaseURL, readOnly: true)
    #expect(try database.scalarInt64("SELECT COUNT(*) FROM inventory_objects") == 1)
    #expect(try database.scalarInt64("SELECT COUNT(*) FROM canonical_attributions") == 1)
    #expect(try database.scalarInt64("SELECT COUNT(*) FROM run_mutations") == 0)
}

@Test("An incremental commit applies its staged overlay without changing generation")
func incrementalCommitAppliesOverlay() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let baseline = try await establishBaseline(in: fixture)

    let run = ScanRun(
        kind: .incremental,
        reason: .dailySchedule,
        status: .running,
        startedAt: Date(timeIntervalSince1970: 30)
    )
    try await fixture.store.begin(run: run)
    let modified = try fixture.record(
        path: "Users/alice/file.dat",
        inode: 1,
        logicalBytes: 200,
        allocatedBytes: 256
    )
    let added = try fixture.record(
        path: "Users/alice/new.dat",
        inode: 2,
        logicalBytes: 50,
        allocatedBytes: 64
    )
    let target = InventoryMutationTarget.expectedActive(volumeID: fixture.volume.id)
    try await fixture.store.stage(
        mutations: [.upsert(modified), .upsert(added)],
        target: target,
        for: run.id
    )

    let overlay = try await fixture.store.records(
        target: target,
        runID: run.id,
        paths: [modified.path.relativePath, added.path.relativePath]
    )
    #expect(overlay == [modified, added])
    try await fixture.store.finalizeCanonicalAttribution(target: target, runID: run.id, consume: { _ in })

    let changes = [
        try ChangeRecord(
            runID: run.id,
            volumeID: fixture.volume.id,
            objectIdentity: modified.object.identity,
            kind: .eventModified,
            pathBefore: modified.path.relativePath,
            pathAfter: modified.path.relativePath,
            effect: .objectTransition(
                before: baseline.records[0].object.footprint,
                after: modified.object.footprint
            )
        ),
        try ChangeRecord(
            runID: run.id,
            volumeID: fixture.volume.id,
            objectIdentity: added.object.identity,
            kind: .eventCreated,
            pathBefore: nil,
            pathAfter: added.path.relativePath,
            effect: .objectTransition(before: nil, after: added.object.footprint)
        ),
    ]
    let derivedChanges = try await fixture.store.deriveIncrementalChanges(target: target, runID: run.id)
    let derivedKinds = derivedChanges.map(\.kind).sorted { $0.rawValue < $1.rawValue }
    let expectedKinds = changes.map(\.kind).sorted { $0.rawValue < $1.rawValue }
    #expect(derivedKinds == expectedKinds)

    let checkpoint = Checkpoint(
        volumeID: fixture.volume.id,
        eventStoreUUID: fixture.volume.eventStoreUUID,
        lastCommittedEventID: 20,
        activeGenerationID: baseline.generation.id,
        topologyFingerprint: fixture.volume.topologyFingerprint,
        lastSuccessfulIncrementalAt: Date(timeIntervalSince1970: 40),
        lastSuccessfulFullScanAt: baseline.checkpoint.lastSuccessfulFullScanAt
    )
    let fence = EventCursorFence(
        volumeID: fixture.volume.id,
        eventStoreUUID: fixture.volume.eventStoreUUID,
        highestFullyDeliveredEventID: 20,
        phase: .liveFlush,
        trust: .trusted
    )
    let sample = try fixture.sample(usedBytes: 500_192, at: 40)
    let commit = try ScanCommit(
        runID: run.id,
        runKind: .incremental,
        scope: fixture.scope,
        volumeID: fixture.volume.id,
        activatedGenerationID: nil,
        previousCheckpoint: baseline.checkpoint,
        checkpoint: checkpoint,
        eventFence: fence,
        changes: changes,
        storageSamples: [sample],
        snapshotSamples: []
    )
    try await fixture.store.commit(commit, finishedAt: Date(timeIntervalSince1970: 40))

    let state = try #require(try await fixture.store.state(for: fixture.volume.id))
    #expect(state.activeGeneration.id == baseline.generation.id)
    #expect(state.checkpoint.lastCommittedEventID == 20)
    let database = try SQLiteDatabase(url: fixture.databaseURL, readOnly: true)
    #expect(try database.scalarInt64("SELECT COUNT(*) FROM inventory_objects") == 2)
    #expect(try database.scalarInt64("SELECT SUM(allocated_bytes) FROM inventory_objects") == 320)
}

@Test("A staged hard-link object update is visible through every linked path")
func hardLinkObjectOverlayIsIdentityScoped() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let first = try fixture.record(
        path: "Users/alice/a-link",
        inode: 7,
        logicalBytes: 100,
        allocatedBytes: 128,
        linkCount: 2
    )
    let second = try fixture.record(
        path: "Users/alice/b-link",
        inode: 7,
        logicalBytes: 100,
        allocatedBytes: 128,
        linkCount: 2
    )
    let baseline = try await establishBaseline(in: fixture, records: [first, second])

    let run = ScanRun(
        kind: .incremental,
        reason: .dailySchedule,
        status: .running,
        startedAt: Date(timeIntervalSince1970: 30)
    )
    try await fixture.store.begin(run: run)
    let updatedFirst = try fixture.record(
        path: "Users/alice/a-link",
        inode: 7,
        logicalBytes: 200,
        allocatedBytes: 256,
        linkCount: 2
    )
    let target = InventoryMutationTarget.expectedActive(volumeID: fixture.volume.id)
    try await fixture.store.stage(mutations: [.upsert(updatedFirst)], target: target, for: run.id)

    let overlay = try await fixture.store.records(
        target: target,
        runID: run.id,
        paths: [first.path.relativePath, second.path.relativePath]
    )
    #expect(overlay.count == 2)
    #expect(overlay.allSatisfy { $0.object.footprint == updatedFirst.object.footprint })
    try await fixture.store.finalizeCanonicalAttribution(target: target, runID: run.id, consume: { _ in })

    let change = try ChangeRecord(
        runID: run.id,
        volumeID: fixture.volume.id,
        objectIdentity: updatedFirst.object.identity,
        kind: .eventModified,
        pathBefore: first.path.relativePath,
        pathAfter: first.path.relativePath,
        effect: .objectTransition(
            before: baseline.records[0].object.footprint,
            after: updatedFirst.object.footprint
        )
    )
    let derivedChanges = try await fixture.store.deriveIncrementalChanges(target: target, runID: run.id)
    #expect(derivedChanges == [change])

    let checkpoint = Checkpoint(
        volumeID: fixture.volume.id,
        eventStoreUUID: fixture.volume.eventStoreUUID,
        lastCommittedEventID: 11,
        activeGenerationID: baseline.generation.id,
        topologyFingerprint: fixture.volume.topologyFingerprint,
        lastSuccessfulIncrementalAt: Date(timeIntervalSince1970: 40),
        lastSuccessfulFullScanAt: baseline.checkpoint.lastSuccessfulFullScanAt
    )
    let commit = try ScanCommit(
        runID: run.id,
        runKind: .incremental,
        scope: fixture.scope,
        volumeID: fixture.volume.id,
        activatedGenerationID: nil,
        previousCheckpoint: baseline.checkpoint,
        checkpoint: checkpoint,
        eventFence: EventCursorFence(
            volumeID: fixture.volume.id,
            eventStoreUUID: fixture.volume.eventStoreUUID,
            highestFullyDeliveredEventID: 11,
            phase: .liveFlush,
            trust: .trusted
        ),
        changes: [change],
        storageSamples: [fixture.sample(usedBytes: 500_128, at: 40)],
        snapshotSamples: []
    )
    try await fixture.store.commit(commit, finishedAt: Date(timeIntervalSince1970: 40))

    let database = try SQLiteDatabase(url: fixture.databaseURL, readOnly: true)
    #expect(try database.scalarInt64("SELECT COUNT(*) FROM inventory_paths") == 2)
    #expect(try database.scalarInt64("SELECT allocated_bytes FROM inventory_objects") == 256)
}

@Test("A committed report is derived from and readable with its exact basis")
func reportCommitRoundTrip() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let baseline = try await establishBaseline(in: fixture)

    let persistedBasis = try #require(
        try await fixture.store.latestUnreportedBasis(storageDomainID: fixture.scope.domain.id)
    )
    #expect(persistedBasis.runID == baseline.run.id)
    #expect(persistedBasis.currentStorageSample == baseline.sample)

    let accounting = try SpaceAccounting.summarize(
        changes: baseline.changes,
        scope: fixture.scope,
        previousSample: nil,
        currentSample: baseline.sample
    )
    let report = try DailyReport(
        runID: baseline.run.id,
        generatedAt: Date(timeIntervalSince1970: 21),
        storageDomainID: fixture.scope.domain.id,
        accounting: accounting,
        reconciliation: nil,
        coverage: ScanCoverage(
            visitedPathCount: 1,
            indexedObjectCount: 1,
            unreadablePathCount: 0,
            transientErrorCount: 0
        ),
        largestGrowth: [],
        largestShrinkage: [],
        diagnostics: []
    )
    let reportCommit = try ReportCommit(
        runID: baseline.run.id,
        scope: fixture.scope,
        changes: baseline.changes,
        previousStorageSample: nil,
        currentStorageSample: baseline.sample,
        previousOverheadSample: nil,
        currentOverheadSample: nil,
        report: report
    )
    try await fixture.store.commitReport(reportCommit)
    try await fixture.store.commitReport(reportCommit)

    #expect(try await fixture.store.latestUnreportedBasis(storageDomainID: fixture.scope.domain.id) == nil)
    let reader = try SQLiteReportStore(databaseURL: fixture.databaseURL)
    #expect(try await reader.latestReport(for: fixture.scope.domain.id) == report)
    #expect(try await reader.reportHistory(for: fixture.scope.domain.id) == [report])
    let runs = try await reader.recentRuns()
    #expect(runs.count == 1)
    #expect(runs[0].status == .succeeded)
}

@Test("A successful scan persists tolerated diagnostics")
func successfulScanPersistsDiagnostics() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let baseline = try await establishBaseline(in: fixture)
    let run = ScanRun(
        kind: .incremental,
        reason: .dailySchedule,
        status: .running,
        startedAt: Date(timeIntervalSince1970: 30)
    )
    try await fixture.store.begin(run: run)
    let target = InventoryMutationTarget.expectedActive(volumeID: fixture.volume.id)
    try await fixture.store.finalizeCanonicalAttribution(target: target, runID: run.id, consume: { _ in })
    let diagnostic = ScanErrorRecord(
        runID: run.id,
        volumeID: fixture.volume.id,
        kind: .disappearedDuringScan,
        path: try RelativePath(validating: "temporary"),
        errorCode: 2,
        message: "Disappeared during scan"
    )
    let checkpoint = Checkpoint(
        volumeID: fixture.volume.id,
        eventStoreUUID: fixture.volume.eventStoreUUID,
        lastCommittedEventID: baseline.checkpoint.lastCommittedEventID,
        activeGenerationID: baseline.generation.id,
        topologyFingerprint: fixture.volume.topologyFingerprint,
        lastSuccessfulIncrementalAt: Date(timeIntervalSince1970: 40),
        lastSuccessfulFullScanAt: baseline.checkpoint.lastSuccessfulFullScanAt
    )
    let commit = try ScanCommit(
        runID: run.id,
        runKind: .incremental,
        scope: fixture.scope,
        volumeID: fixture.volume.id,
        activatedGenerationID: nil,
        previousCheckpoint: baseline.checkpoint,
        checkpoint: checkpoint,
        eventFence: EventCursorFence(
            volumeID: fixture.volume.id,
            eventStoreUUID: fixture.volume.eventStoreUUID,
            highestFullyDeliveredEventID: baseline.checkpoint.lastCommittedEventID,
            phase: .liveFlush,
            trust: .trusted
        ),
        changes: [],
        storageSamples: [],
        snapshotSamples: [],
        snapshotObservedVolumeIDs: [fixture.volume.id],
        overheadSample: DailyDiskOverheadSample(
            storageDomainID: fixture.scope.domain.id,
            sampledAt: Date(timeIntervalSince1970: 39),
            allocatedBytes: 4_096
        ),
        scanErrors: [diagnostic]
    )
    try await fixture.store.commit(commit, finishedAt: Date(timeIntervalSince1970: 40))

    let reader = try SQLiteReportStore(databaseURL: fixture.databaseURL)
    #expect(try await reader.errors(for: run.id) == [diagnostic])
    let storedRun = try #require(try await reader.recentRuns().first { $0.id == run.id })
    #expect(storedRun.status == .succeeded)
    #expect(storedRun.errorCount == 1)
    #expect(
        try await fixture.store.latestOverheadSample(
            storageDomainID: fixture.scope.domain.id,
            before: Date(timeIntervalSince1970: 50)
        )?.allocatedBytes
            == 4_096
    )
    #expect(
        try await fixture.store.latestSnapshotSamples(
            volumeIDs: [fixture.volume.id],
            before: Date(timeIntervalSince1970: 50)
        ).isEmpty
    )
}

@Test("Opaque permission subtrees preserve prior inventory into a full staging generation")
func opaqueSubtreePreservation() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    _ = try await establishBaseline(in: fixture)
    let run = ScanRun(
        kind: .full,
        reason: .weeklyReconciliation,
        status: .running,
        startedAt: Date(timeIntervalSince1970: 50)
    )
    try await fixture.store.begin(run: run)
    let generation = try await fixture.store.createStagingGeneration(
        volumeID: fixture.volume.id,
        runID: run.id,
        at: run.startedAt
    )
    let source = InventoryMutationTarget.expectedActive(volumeID: fixture.volume.id)
    let destination = InventoryMutationTarget.stagingGeneration(generation.id)
    try await fixture.store.preserveOpaqueSubtrees(
        roots: [RelativePath(validating: "Users/alice")],
        from: source,
        to: destination,
        for: run.id
    )
    let preserved = try await fixture.store.records(
        target: destination,
        runID: run.id,
        paths: [RelativePath(validating: "Users/alice/file.dat")]
    )
    #expect(preserved.count == 1)
}

@Test("Run-scoped diff streams expected and authoritative differences")
func runScopedDiff() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    _ = try await establishBaseline(in: fixture)

    let run = ScanRun(
        kind: .full,
        reason: .weeklyReconciliation,
        status: .running,
        startedAt: Date(timeIntervalSince1970: 50)
    )
    try await fixture.store.begin(run: run)
    let generation = try await fixture.store.createStagingGeneration(
        volumeID: fixture.volume.id,
        runID: run.id,
        at: run.startedAt
    )
    let changed = try fixture.record(
        path: "Users/alice/file.dat",
        inode: 1,
        logicalBytes: 300,
        allocatedBytes: 384
    )
    let added = try fixture.record(
        path: "Users/alice/another.dat",
        inode: 3,
        logicalBytes: 25,
        allocatedBytes: 32
    )
    try await fixture.store.append(records: [changed, added], to: generation.id)
    try await fixture.store.finalizeCanonicalAttribution(
        target: .expectedActive(volumeID: fixture.volume.id),
        runID: run.id,
        consume: { _ in }
    )
    try await fixture.store.finalizeCanonicalAttribution(
        target: .stagingGeneration(generation.id),
        runID: run.id,
        consume: { _ in }
    )

    let collector = DiffCollector()
    try await fixture.store.diff(
        expected: .expectedActive(volumeID: fixture.volume.id),
        authoritative: .stagingGeneration(generation.id),
        runID: run.id,
        consume: { batch in await collector.append(batch) }
    )
    let differences = await collector.values
    #expect(differences.count == 2)
    #expect(differences.contains { $0.expected == nil && $0.authoritative?.path == added.path })
    #expect(differences.contains { $0.expected != nil && $0.authoritative?.object == changed.object })
}

@Test("Bounded subtree paging excludes neighboring names and handles mutation overlays")
func subtreePagingKeepsNeighborPrefixes() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let run = ScanRun(kind: .full, reason: .manual, status: .running, startedAt: Date())
    try await fixture.store.begin(run: run)
    let generation = try await fixture.store.createStagingGeneration(
        volumeID: fixture.volume.id,
        runID: run.id, at: run.startedAt)
    let names = ["cache", "cache/item", "cache-neighbor", "cache.more", "cache0"]
    let records = try names.enumerated().map { index, name in
        try fixture.record(path: name, inode: UInt64(index + 100), logicalBytes: 1, allocatedBytes: 4096)
    }
    try await fixture.store.append(records: records, to: generation.id)
    let target = InventoryMutationTarget.stagingGeneration(generation.id)
    try await fixture.store.stageRemovalSubtree(
        root: RelativePath(validating: "cache"),
        target: target, for: run.id, observer: TaskOnlyScanWorkObserver())
    let remaining = try await fixture.store.records(
        target: target, runID: run.id,
        paths: records.map(\.path.relativePath))
    #expect(Set(remaining.map(\.path.relativePath.displayString)) == ["cache-neighbor", "cache.more", "cache0"])
    try await fixture.store.interrupt(runID: run.id, finishedAt: Date())
}
