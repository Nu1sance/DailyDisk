import Foundation
import Testing

@testable import DailyDiskCore

private struct InvariantFixture {
    let domain: StorageDomain
    let volume: MonitoredVolume
    let scope: StorageDomainScope

    init() throws {
        domain = StorageDomain(
            id: StorageDomain.ID("container"),
            containerIdentifier: "disk3",
            displayName: "Internal",
            isInternal: true
        )
        volume = MonitoredVolume(
            id: MonitoredVolume.ID("data"),
            storageDomainID: domain.id,
            filesystemUUID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"),
            eventStoreUUID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"),
            deviceID: 1,
            mountPath: "/System/Volumes/Data",
            displayName: "Data",
            role: .data,
            isInternal: true,
            isRemovable: false,
            isReadOnly: false,
            supportsPersistentEvents: true,
            topologyFingerprint: "fixture"
        )
        scope = try StorageDomainScope(domain: domain, volumes: [volume])
    }

    func checkpoint(
        generationID: InventoryGeneration.ID,
        eventID: UInt64?
    ) -> Checkpoint {
        Checkpoint(
            volumeID: volume.id,
            eventStoreUUID: volume.eventStoreUUID,
            lastCommittedEventID: eventID,
            activeGenerationID: generationID,
            topologyFingerprint: volume.topologyFingerprint,
            lastSuccessfulIncrementalAt: nil,
            lastSuccessfulFullScanAt: Date(timeIntervalSince1970: 1)
        )
    }
}

@Test("Attribution transfers must be persisted as one balanced pair")
func attributionTransferRequiresBalancedPair() throws {
    let fixture = try InvariantFixture()
    let identity = FileIdentity(volumeID: fixture.volume.id, deviceID: 1, inode: 7)
    let transferID = UUID()
    let loneDebit = try ChangeRecord(
        runID: ScanRun.ID(),
        volumeID: fixture.volume.id,
        objectIdentity: identity,
        kind: .eventAttributionTransfer,
        pathBefore: RelativePath(validating: "ordinary"),
        pathAfter: RelativePath(validating: "DailyDisk/internal"),
        transferID: transferID,
        effect: .attributionTransfer(
            footprint: FileFootprint(logicalBytes: 100, allocatedBytes: 128),
            direction: .debit
        ),
        classification: .ordinary
    )

    #expect(throws: ModelValidationError.unbalancedAttributionTransfer) {
        try ChangeSetValidator.validateAttributionTransfers(in: [loneDebit])
    }
}

@Test("Inventory state requires a matching active generation")
func inventoryStateRequiresMatchingActiveGeneration() throws {
    let fixture = try InvariantFixture()
    let runID = ScanRun.ID()
    let activeID = InventoryGeneration.ID()
    let otherID = InventoryGeneration.ID()
    let checkpoint = fixture.checkpoint(generationID: activeID, eventID: 1)
    let wrongGeneration = InventoryGeneration(
        id: otherID,
        volumeID: fixture.volume.id,
        createdByRunID: runID,
        state: .active,
        createdAt: Date()
    )

    #expect(throws: ModelValidationError.invalidInventoryState) {
        _ = try InventoryState(checkpoint: checkpoint, activeGeneration: wrongGeneration)
    }
}

@Test("An incremental commit cannot advance its event cursor without a trusted fence")
func incrementalCommitRequiresFenceWhenAdvancing() throws {
    let fixture = try InvariantFixture()
    let generationID = InventoryGeneration.ID()
    let previous = fixture.checkpoint(generationID: generationID, eventID: 1)
    let advanced = fixture.checkpoint(generationID: generationID, eventID: 2)

    #expect(throws: ModelValidationError.invalidScanCommit) {
        _ = try ScanCommit(
            runID: ScanRun.ID(),
            runKind: .incremental,
            scope: fixture.scope,
            volumeID: fixture.volume.id,
            activatedGenerationID: nil,
            previousCheckpoint: previous,
            checkpoint: advanced,
            eventFence: nil,
            changes: [],
            storageSamples: [],
            snapshotSamples: []
        )
    }
}

@Test("A full activation requires a post-scan live-flush fence")
func fullCommitRequiresLiveFlushFence() throws {
    let fixture = try InvariantFixture()
    let previousID = InventoryGeneration.ID()
    let nextID = InventoryGeneration.ID()
    let previous = fixture.checkpoint(generationID: previousID, eventID: 1)
    let advanced = fixture.checkpoint(generationID: nextID, eventID: 2)
    let historyFence = EventCursorFence(
        volumeID: fixture.volume.id,
        eventStoreUUID: fixture.volume.eventStoreUUID,
        highestFullyDeliveredEventID: 2,
        phase: .historyDone,
        trust: .trusted
    )

    #expect(throws: ModelValidationError.invalidScanCommit) {
        _ = try ScanCommit(
            runID: ScanRun.ID(),
            runKind: .full,
            scope: fixture.scope,
            volumeID: fixture.volume.id,
            activatedGenerationID: nextID,
            previousCheckpoint: previous,
            checkpoint: advanced,
            eventFence: historyFence,
            changes: [],
            storageSamples: [],
            snapshotSamples: []
        )
    }
}

@Test("An incremental commit cannot regress its event cursor")
func incrementalCommitRejectsCursorRegression() throws {
    let fixture = try InvariantFixture()
    let generationID = InventoryGeneration.ID()
    let previous = fixture.checkpoint(generationID: generationID, eventID: 100)
    let regressed = fixture.checkpoint(generationID: generationID, eventID: 50)
    let fence = EventCursorFence(
        volumeID: fixture.volume.id,
        eventStoreUUID: fixture.volume.eventStoreUUID,
        highestFullyDeliveredEventID: 50,
        phase: .liveFlush,
        trust: .trusted
    )

    #expect(throws: ModelValidationError.invalidScanCommit) {
        _ = try ScanCommit(
            runID: ScanRun.ID(),
            runKind: .incremental,
            scope: fixture.scope,
            volumeID: fixture.volume.id,
            activatedGenerationID: nil,
            previousCheckpoint: previous,
            checkpoint: regressed,
            eventFence: fence,
            changes: [],
            storageSamples: [],
            snapshotSamples: []
        )
    }
}

@Test("A full commit cannot regress a cursor in the same event store")
func fullCommitRejectsSameStoreCursorRegression() throws {
    let fixture = try InvariantFixture()
    let previousID = InventoryGeneration.ID()
    let nextID = InventoryGeneration.ID()
    let previous = fixture.checkpoint(generationID: previousID, eventID: 100)
    let regressed = fixture.checkpoint(generationID: nextID, eventID: 50)
    let fence = EventCursorFence(
        volumeID: fixture.volume.id,
        eventStoreUUID: fixture.volume.eventStoreUUID,
        highestFullyDeliveredEventID: 50,
        phase: .liveFlush,
        trust: .trusted
    )

    #expect(throws: ModelValidationError.invalidScanCommit) {
        _ = try ScanCommit(
            runID: ScanRun.ID(),
            runKind: .recovery,
            scope: fixture.scope,
            volumeID: fixture.volume.id,
            activatedGenerationID: nextID,
            previousCheckpoint: previous,
            checkpoint: regressed,
            eventFence: fence,
            changes: [],
            storageSamples: [],
            snapshotSamples: []
        )
    }
}

@Test("A checkpoint must match the scoped volume topology and event store")
func scanCommitBindsCheckpointToTopology() throws {
    let fixture = try InvariantFixture()
    let generationID = InventoryGeneration.ID()
    let previous = fixture.checkpoint(generationID: generationID, eventID: 1)
    let wrongCheckpoint = Checkpoint(
        volumeID: fixture.volume.id,
        eventStoreUUID: UUID(),
        lastCommittedEventID: 1,
        activeGenerationID: generationID,
        topologyFingerprint: "wrong-topology",
        lastSuccessfulIncrementalAt: nil,
        lastSuccessfulFullScanAt: Date()
    )

    #expect(throws: ModelValidationError.invalidScanCommit) {
        _ = try ScanCommit(
            runID: ScanRun.ID(),
            runKind: .incremental,
            scope: fixture.scope,
            volumeID: fixture.volume.id,
            activatedGenerationID: nil,
            previousCheckpoint: previous,
            checkpoint: wrongCheckpoint,
            eventFence: nil,
            changes: [],
            storageSamples: [],
            snapshotSamples: []
        )
    }
}

@Test("Report commits must derive from their exact ledger and sample basis")
func reportCommitValidatesItsBasis() throws {
    let fixture = try InvariantFixture()
    let runID = ScanRun.ID()
    let currentSample = try StorageSample(
        storageDomainID: fixture.domain.id,
        sampledAt: Date(timeIntervalSince1970: 2),
        capacityBytes: 1_000,
        usedBytes: 500,
        availableBytes: 500
    )
    let emptyAccounting = try AccountingSummary(
        eventAttributedDelta: 0,
        reconciliationCorrection: 0,
        reconciledIndexedDelta: 0,
        dailyDiskOverheadDelta: 0,
        physicalUsedDelta: nil,
        physicalUnattributedDelta: nil
    )
    let report = try DailyReport(
        runID: runID,
        generatedAt: Date(timeIntervalSince1970: 2),
        storageDomainID: fixture.domain.id,
        accounting: emptyAccounting,
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

    let valid = try ReportCommit(
        runID: runID,
        scope: fixture.scope,
        changes: [],
        previousStorageSample: nil,
        currentStorageSample: currentSample,
        previousOverheadSample: nil,
        currentOverheadSample: nil,
        report: report
    )
    #expect(valid.report == report)

    #expect(throws: ModelValidationError.invalidReportCommit) {
        _ = try ReportCommit(
            runID: ScanRun.ID(),
            scope: fixture.scope,
            changes: [],
            previousStorageSample: nil,
            currentStorageSample: currentSample,
            previousOverheadSample: nil,
            currentOverheadSample: nil,
            report: report
        )
    }
}

@Test("A trusted live-flush fence can atomically activate a full generation")
func validFullCommit() throws {
    let fixture = try InvariantFixture()
    let previousID = InventoryGeneration.ID()
    let nextID = InventoryGeneration.ID()
    let previous = fixture.checkpoint(generationID: previousID, eventID: 1)
    let advanced = fixture.checkpoint(generationID: nextID, eventID: 2)
    let liveFence = EventCursorFence(
        volumeID: fixture.volume.id,
        eventStoreUUID: fixture.volume.eventStoreUUID,
        highestFullyDeliveredEventID: 2,
        phase: .liveFlush,
        trust: .trusted
    )

    let commit = try ScanCommit(
        runID: ScanRun.ID(),
        runKind: .full,
        scope: fixture.scope,
        volumeID: fixture.volume.id,
        activatedGenerationID: nextID,
        previousCheckpoint: previous,
        checkpoint: advanced,
        eventFence: liveFence,
        changes: [],
        storageSamples: [],
        snapshotSamples: []
    )

    #expect(commit.checkpoint.activeGenerationID == nextID)
    #expect(commit.eventFence?.phase == .liveFlush)
}
