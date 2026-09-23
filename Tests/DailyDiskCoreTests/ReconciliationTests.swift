import Foundation
import Testing

@testable import DailyDiskCore

@Test("Reconciliation keeps event attribution and signed correction separate")
func reconciliationSeparatesSources() throws {
    let volumeID = MonitoredVolume.ID("data")
    let identity = FileIdentity(volumeID: volumeID, deviceID: 1, inode: 1)
    let runID = ScanRun.ID()
    let path = try RelativePath(validating: "file")
    let eventChange = try ChangeRecord(
        runID: runID,
        volumeID: volumeID,
        objectIdentity: identity,
        kind: .eventModified,
        pathBefore: path,
        pathAfter: path,
        effect: .objectTransition(
            before: FileFootprint(logicalBytes: 100, allocatedBytes: 128),
            after: FileFootprint(logicalBytes: 200, allocatedBytes: 256)
        )
    )
    let correction = try ChangeRecord(
        runID: runID,
        volumeID: volumeID,
        objectIdentity: identity,
        kind: .reconciliationCorrection,
        pathBefore: path,
        pathAfter: path,
        effect: .objectTransition(
            before: FileFootprint(logicalBytes: 200, allocatedBytes: 256),
            after: FileFootprint(logicalBytes: 180, allocatedBytes: 192)
        )
    )

    let result = try ReconciliationResult(
        eventChanges: [eventChange],
        reconciliationChanges: [correction]
    )
    #expect(result.allChanges == [eventChange, correction])
    #expect(result.breakdown?.sizeCorrections == -64)
    #expect(result.breakdown?.affectedRecords == 1)
}

@Test("Reconciliation rejects incorrectly sourced changes")
func reconciliationRejectsSourceMixup() throws {
    let volumeID = MonitoredVolume.ID("data")
    let identity = FileIdentity(volumeID: volumeID, deviceID: 1, inode: 1)
    let path = try RelativePath(validating: "file")
    let event = try ChangeRecord(
        runID: ScanRun.ID(),
        volumeID: volumeID,
        objectIdentity: identity,
        kind: .eventCreated,
        pathBefore: nil,
        pathAfter: path,
        effect: .objectTransition(
            before: nil,
            after: FileFootprint(logicalBytes: 1, allocatedBytes: 1)
        )
    )
    #expect(throws: ReconciliationError.invalidChangeSource) {
        _ = try ReconciliationResult(eventChanges: [], reconciliationChanges: [event])
    }
}
