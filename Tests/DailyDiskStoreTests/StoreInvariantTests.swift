import DailyDiskCore
import Foundation
import Testing

@testable import DailyDiskStore

@Test("Only one inventory writer can own recovery and commits")
func writerLeaseIsExclusive() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }

    #expect(throws: WriterLeaseError.alreadyHeld) {
        _ = try SQLiteInventoryStore(databaseURL: fixture.databaseURL)
    }
}

@Test("Mutating a target after canonical finalization invalidates its seal")
func mutationAfterCanonicalFinalizationIsRejected() async throws {
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
    let firstUpdate = try fixture.record(
        path: "Users/alice/file.dat",
        inode: 1,
        logicalBytes: 200,
        allocatedBytes: 256
    )
    try await fixture.store.stage(mutations: [.upsert(firstUpdate)], target: target, for: run.id)
    try await fixture.store.finalizeCanonicalAttribution(target: target, runID: run.id, consume: { _ in })

    let secondUpdate = try fixture.record(
        path: "Users/alice/file.dat",
        inode: 1,
        logicalBytes: 300,
        allocatedBytes: 384
    )
    try await fixture.store.stage(mutations: [.upsert(secondUpdate)], target: target, for: run.id)

    let change = try ChangeRecord(
        runID: run.id,
        volumeID: fixture.volume.id,
        objectIdentity: secondUpdate.object.identity,
        kind: .eventModified,
        pathBefore: secondUpdate.path.relativePath,
        pathAfter: secondUpdate.path.relativePath,
        effect: .objectTransition(
            before: baseline.records[0].object.footprint,
            after: secondUpdate.object.footprint
        )
    )
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
        storageSamples: [],
        snapshotSamples: []
    )

    await #expect(throws: StoreInvariantError.targetNotSealed) {
        try await fixture.store.commit(commit, finishedAt: Date(timeIntervalSince1970: 40))
    }
}

@Test("A run cannot use another run's staging generation")
func stagingGenerationOwnershipIsEnforced() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let owner = ScanRun(
        kind: .full,
        reason: .manual,
        status: .running,
        startedAt: Date(timeIntervalSince1970: 10)
    )
    let intruder = ScanRun(
        kind: .recovery,
        reason: .eventHistoryLost,
        status: .running,
        startedAt: Date(timeIntervalSince1970: 11)
    )
    try await fixture.store.begin(run: owner)
    try await fixture.store.begin(run: intruder)
    #expect(try await fixture.store.activeRuns() == [intruder, owner])
    let generation = try await fixture.store.createStagingGeneration(
        volumeID: fixture.volume.id,
        runID: owner.id,
        at: owner.startedAt
    )

    await #expect(throws: StoreInvariantError.generationOwnershipMismatch) {
        try await fixture.store.finalizeCanonicalAttribution(
            target: .stagingGeneration(generation.id),
            runID: intruder.id,
            consume: { _ in }
        )
    }
}

@Test("Streaming canonical output fails if its sealed revision changes during callback")
func canonicalStreamingDetectsReentrantMutation() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    _ = try await establishBaseline(in: fixture)

    let run = ScanRun(
        kind: .incremental,
        reason: .dailySchedule,
        status: .running,
        startedAt: Date(timeIntervalSince1970: 30)
    )
    try await fixture.store.begin(run: run)
    let target = InventoryMutationTarget.expectedActive(volumeID: fixture.volume.id)
    let initial = try fixture.record(path: "Users/alice/initial", inode: 2, logicalBytes: 1, allocatedBytes: 1)
    let added = try fixture.record(path: "Users/alice/new", inode: 3, logicalBytes: 1, allocatedBytes: 1)
    try await fixture.store.stage(mutations: [.upsert(initial)], target: target, for: run.id)

    await #expect(throws: StoreInvariantError.targetRevisionMismatch) {
        try await fixture.store.finalizeCanonicalAttribution(
            target: target,
            runID: run.id,
            consume: { _ in
                try await fixture.store.stage(mutations: [.upsert(added)], target: target, for: run.id)
            }
        )
    }
}

@Test("A report must use the immediately preceding physical sample")
func reportRequiresImmediatePreviousSample() async throws {
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
    let currentSample = try fixture.sample(usedBytes: baseline.sample.usedBytes, at: 40)
    let checkpoint = Checkpoint(
        volumeID: fixture.volume.id,
        eventStoreUUID: fixture.volume.eventStoreUUID,
        lastCommittedEventID: baseline.checkpoint.lastCommittedEventID,
        activeGenerationID: baseline.generation.id,
        topologyFingerprint: fixture.volume.topologyFingerprint,
        lastSuccessfulIncrementalAt: Date(timeIntervalSince1970: 40),
        lastSuccessfulFullScanAt: baseline.checkpoint.lastSuccessfulFullScanAt
    )
    let scanCommit = try ScanCommit(
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
        storageSamples: [currentSample],
        snapshotSamples: []
    )
    try await fixture.store.commit(scanCommit, finishedAt: Date(timeIntervalSince1970: 40))

    let accountingWithoutBaseline = try SpaceAccounting.summarize(
        changes: [],
        scope: fixture.scope,
        previousSample: nil,
        currentSample: currentSample
    )
    let report = try DailyReport(
        runID: run.id,
        generatedAt: Date(timeIntervalSince1970: 41),
        storageDomainID: fixture.scope.domain.id,
        accounting: accountingWithoutBaseline,
        reconciliation: nil,
        coverage: ScanCoverage(
            visitedPathCount: 0,
            indexedObjectCount: 0,
            unreadablePathCount: 0,
            transientErrorCount: 0
        ),
        largestGrowth: [],
        largestShrinkage: [],
        diagnostics: []
    )
    let invalidBasis = try ReportCommit(
        runID: run.id,
        scope: fixture.scope,
        changes: [],
        previousStorageSample: nil,
        currentStorageSample: currentSample,
        previousOverheadSample: nil,
        currentOverheadSample: nil,
        report: report
    )

    await #expect(throws: StoreInvariantError.reportBasisMismatch) {
        try await fixture.store.commitReport(invalidBasis)
    }
}

@Test("A same-net but semantically false ledger cannot commit")
func mutationRequiresSemanticallyMatchingLedger() async throws {
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
    let modified = try fixture.record(
        path: "Users/alice/file.dat",
        inode: 1,
        logicalBytes: 200,
        allocatedBytes: 256
    )
    try await fixture.store.stage(mutations: [.upsert(modified)], target: target, for: run.id)
    try await fixture.store.finalizeCanonicalAttribution(target: target, runID: run.id, consume: { _ in })

    let checkpoint = Checkpoint(
        volumeID: fixture.volume.id,
        eventStoreUUID: fixture.volume.eventStoreUUID,
        lastCommittedEventID: 11,
        activeGenerationID: baseline.generation.id,
        topologyFingerprint: fixture.volume.topologyFingerprint,
        lastSuccessfulIncrementalAt: Date(timeIntervalSince1970: 40),
        lastSuccessfulFullScanAt: baseline.checkpoint.lastSuccessfulFullScanAt
    )
    let falseCreation = try ChangeRecord(
        runID: run.id,
        volumeID: fixture.volume.id,
        objectIdentity: modified.object.identity,
        kind: .eventCreated,
        pathBefore: nil,
        pathAfter: modified.path.relativePath,
        effect: .objectTransition(
            before: nil,
            after: FileFootprint(logicalBytes: 100, allocatedBytes: 128)
        )
    )
    // This false creation has the same +128 allocated-byte net as the real
    // 128 -> 256 modification. Net-only validation would accept it.
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
        changes: [falseCreation],
        storageSamples: [],
        snapshotSamples: []
    )

    await #expect(throws: StoreInvariantError.ledgerMismatch) {
        try await fixture.store.commit(commit, finishedAt: Date(timeIntervalSince1970: 40))
    }
    let state = try #require(try await fixture.store.state(for: fixture.volume.id))
    #expect(state.checkpoint == baseline.checkpoint)
}
