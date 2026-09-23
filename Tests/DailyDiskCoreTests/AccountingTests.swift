import Foundation
import Testing

@testable import DailyDiskCore

private let accountingRunID = ScanRun.ID(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
private let accountingVolumeID = MonitoredVolume.ID("volume-data")
private let accountingDomainID = StorageDomain.ID("container-1")
private let accountingIdentity = FileIdentity(volumeID: accountingVolumeID, deviceID: 1, inode: 42)

private func accountingScope() throws -> StorageDomainScope {
    let domain = StorageDomain(
        id: accountingDomainID,
        containerIdentifier: "disk3",
        displayName: "Internal",
        isInternal: true
    )
    let volume = MonitoredVolume(
        id: accountingVolumeID,
        storageDomainID: accountingDomainID,
        filesystemUUID: nil,
        eventStoreUUID: nil,
        deviceID: 1,
        mountPath: "/",
        displayName: "Data",
        role: .data,
        isInternal: true,
        isRemovable: false,
        isReadOnly: false,
        supportsPersistentEvents: true,
        topologyFingerprint: "fixture"
    )
    return try StorageDomainScope(domain: domain, volumes: [volume])
}

private func footprint(_ bytes: Int64) throws -> FileFootprint {
    try FileFootprint(logicalBytes: bytes, allocatedBytes: bytes)
}

private func objectChange(
    before: Int64?,
    after: Int64?,
    kind: ChangeKind,
    classification: InventoryClassification = .ordinary
) throws -> ChangeRecord {
    try ChangeRecord(
        runID: accountingRunID,
        volumeID: accountingVolumeID,
        objectIdentity: accountingIdentity,
        kind: kind,
        pathBefore: before == nil ? nil : RelativePath(validating: "before"),
        pathAfter: after == nil ? nil : RelativePath(validating: "after"),
        effect: .objectTransition(
            before: try before.map(footprint),
            after: try after.map(footprint)
        ),
        classification: classification
    )
}

private func sample(used: Int64, at timestamp: TimeInterval) throws -> StorageSample {
    try StorageSample(
        storageDomainID: accountingDomainID,
        sampledAt: Date(timeIntervalSince1970: timestamp),
        capacityBytes: 1_000_000_000_000,
        usedBytes: used,
        availableBytes: 1_000_000_000_000 - used
    )
}

@Test("Accounting keeps event, reconciliation, internal, and physical deltas separate")
func accountingSeparatesDeltaClasses() throws {
    let changes = [
        try objectChange(before: nil, after: 5, kind: .eventCreated),
        try objectChange(before: 4, after: 3, kind: .eventModified),
        try objectChange(before: nil, after: 2, kind: .reconciliationAddition),
        try objectChange(before: nil, after: 1, kind: .eventCreated, classification: .dailyDiskInternal),
    ]

    let summary = try SpaceAccounting.summarize(
        changes: changes,
        scope: accountingScope(),
        previousSample: sample(used: 100, at: 1),
        currentSample: sample(used: 110, at: 2)
    )

    #expect(summary.eventAttributedDelta == 4)
    #expect(summary.reconciliationCorrection == 2)
    #expect(summary.reconciledIndexedDelta == 6)
    #expect(summary.dailyDiskOverheadDelta == 1)
    #expect(summary.physicalUsedDelta == 10)
    #expect(summary.physicalUnattributedDelta == 3)
}

@Test("Negative reconciliation remains signed")
func negativeReconciliationRemainsSigned() throws {
    let changes = [
        try objectChange(before: 1_720_000_000, after: nil, kind: .reconciliationRemoval)
    ]

    let summary = try SpaceAccounting.summarize(
        changes: changes,
        scope: accountingScope(),
        previousSample: sample(used: 10_000_000_000, at: 1),
        currentSample: sample(used: 8_500_000_000, at: 2)
    )

    #expect(summary.reconciliationCorrection == -1_720_000_000)
    #expect(summary.reconciledIndexedDelta == -1_720_000_000)
    #expect(summary.physicalUnattributedDelta == 220_000_000)
}

@Test("A missing physical baseline produces no fabricated physical delta")
func missingPhysicalBaselineStaysUnknown() throws {
    let changes = [try objectChange(before: nil, after: 42, kind: .eventCreated)]
    let summary = try SpaceAccounting.summarize(
        changes: changes,
        scope: accountingScope(),
        previousSample: nil,
        currentSample: sample(used: 100, at: 2)
    )

    #expect(summary.physicalUsedDelta == nil)
    #expect(summary.physicalUnattributedDelta == nil)
}

@Test("Reconciliation breakdown preserves signed categories")
func reconciliationBreakdownPreservesSigns() throws {
    let changes = [
        try objectChange(before: nil, after: 300, kind: .reconciliationAddition),
        try objectChange(before: 100, after: nil, kind: .reconciliationRemoval),
        try objectChange(before: 200, after: 180, kind: .reconciliationCorrection),
    ]

    let breakdown = try #require(try SpaceAccounting.reconciliationBreakdown(from: changes))
    #expect(breakdown.missedAdditions == 300)
    #expect(breakdown.staleRemovals == -100)
    #expect(breakdown.sizeCorrections == -20)
    #expect(breakdown.attributionTransfers == 0)
    #expect(try breakdown.correction == 180)
    #expect(breakdown.affectedRecords == 3)
}

@Test("Change kinds reject contradictory effects")
func changeKindsRejectContradictoryEffects() throws {
    do {
        _ = try ChangeRecord(
            runID: accountingRunID,
            volumeID: accountingVolumeID,
            objectIdentity: accountingIdentity,
            kind: .eventModified,
            pathBefore: RelativePath(validating: "before"),
            pathAfter: RelativePath(validating: "after"),
            effect: .pathOnly
        )
        Issue.record("Expected invalid change combination")
    } catch let error as ModelValidationError {
        #expect(error == .invalidChangeCombination)
    }
}

@Test("Checked accounting reports overflow instead of wrapping")
func checkedAccountingRejectsOverflow() {
    do {
        _ = try AccountingMath.add(.max, 1)
        Issue.record("Expected overflow")
    } catch let error as AccountingError {
        #expect(error == .overflow(operation: "9223372036854775807 + 1"))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    do {
        _ = try AccountingMath.subtract(.min, 1)
        Issue.record("Expected subtraction overflow")
    } catch is AccountingError {
        // Expected.
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    do {
        _ = try AccountingMath.allocatedBytes(blockCount: .max)
        Issue.record("Expected multiplication overflow")
    } catch is AccountingError {
        // Expected.
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test("File footprints and absolute samples reject negative byte counts")
func absoluteMeasurementsRejectNegativeBytes() throws {
    do {
        _ = try FileFootprint(logicalBytes: -1, allocatedBytes: 0)
        Issue.record("Expected validation error")
    } catch let error as ModelValidationError {
        #expect(error == .negativeByteCount)
    }

    do {
        _ = try StorageSample(
            storageDomainID: accountingDomainID,
            sampledAt: Date(),
            capacityBytes: 1,
            usedBytes: -1,
            availableBytes: 2
        )
        Issue.record("Expected validation error")
    } catch let error as ModelValidationError {
        #expect(error == .negativeByteCount)
    }
}

@Test("Accounting rejects mixed storage-domain inputs and reversed sample time")
func accountingValidatesScopeAndTime() throws {
    let foreignVolume = MonitoredVolume.ID("foreign")
    let foreignIdentity = FileIdentity(volumeID: foreignVolume, deviceID: 2, inode: 1)
    let foreignChange = try ChangeRecord(
        runID: accountingRunID,
        volumeID: foreignVolume,
        objectIdentity: foreignIdentity,
        kind: .eventCreated,
        pathBefore: nil,
        pathAfter: RelativePath(validating: "file"),
        effect: .objectTransition(before: nil, after: footprint(1))
    )

    do {
        _ = try SpaceAccounting.summarize(
            changes: [foreignChange],
            scope: accountingScope(),
            previousSample: nil,
            currentSample: sample(used: 1, at: 2)
        )
        Issue.record("Expected domain mismatch")
    } catch let error as ModelValidationError {
        #expect(error == .mismatchedStorageDomain)
    }

    do {
        _ = try SpaceAccounting.summarize(
            changes: [],
            scope: accountingScope(),
            previousSample: sample(used: 1, at: 3),
            currentSample: sample(used: 1, at: 2)
        )
        Issue.record("Expected chronology failure")
    } catch let error as ModelValidationError {
        #expect(error == .invalidSampleChronology)
    }
}
