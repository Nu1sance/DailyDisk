import Foundation
import Testing

@testable import DailyDiskCore

@Test("Relative paths preserve raw filesystem bytes")
func relativePathsPreserveRawBytes() throws {
    let raw = Data([0x66, 0x6F, 0x80, 0x6F])
    let path = try RelativePath(validating: raw)

    #expect(path.bytes == raw)
    #expect(path != RelativePath.root)
}

@Test(
    "Relative path validation rejects traversal and malformed separators",
    arguments: [
        Data("/absolute".utf8),
        Data("trailing/".utf8),
        Data("double//separator".utf8),
        Data("a/./b".utf8),
        Data("a/../b".utf8),
        Data([0x61, 0x00, 0x62]),
    ])
func relativePathValidationRejectsMalformedInput(_ raw: Data) {
    do {
        _ = try RelativePath(validating: raw)
        Issue.record("Expected malformed path to be rejected")
    } catch is PathValidationError {
        // Expected.
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test("Parents and ancestors terminate at the volume root")
func parentAndAncestors() throws {
    let path = try RelativePath(validating: "Users/alice/file.dat")
    let aliceDirectory = try RelativePath(validating: "Users/alice")
    let usersDirectory = try RelativePath(validating: "Users")

    #expect(PathPolicy.parent(of: path) == aliceDirectory)
    #expect(PathPolicy.ancestors(of: path) == [aliceDirectory, usersDirectory, .root])
    #expect(PathPolicy.parent(of: .root) == nil)
}

@Test("Managed-root classification respects component boundaries")
func managedRootClassification() throws {
    let managedRoot = try RelativePath(validating: "Users/alice/Library/Application Support/DailyDisk")
    let managedChild = try RelativePath(validating: "Users/alice/Library/Application Support/DailyDisk/index.sqlite")
    let similarlyNamedSibling = try RelativePath(validating: "Users/alice/Library/Application Support/DailyDiskBackup")
    let roots: Set<RelativePath> = [managedRoot]

    #expect(PathPolicy.classify(managedRoot, dailyDiskManagedRoots: roots) == .dailyDiskInternal)
    #expect(PathPolicy.classify(managedChild, dailyDiskManagedRoots: roots) == .dailyDiskInternal)
    #expect(PathPolicy.classify(similarlyNamedSibling, dailyDiskManagedRoots: roots) == .ordinary)
}

@Test("Hard-link canonical attribution is deterministic by raw bytes")
func hardLinkCanonicalAttribution() throws {
    let volumeID = MonitoredVolume.ID("data")
    let identity = FileIdentity(volumeID: volumeID, deviceID: 1, inode: 99)
    let first = try RelativePath(validating: "z-link")
    let second = try RelativePath(validating: "a-link")
    let paths = [
        try InventoryPath(
            volumeID: volumeID,
            relativePath: first,
            parentPath: .root,
            objectIdentity: identity
        ),
        try InventoryPath(
            volumeID: volumeID,
            relativePath: second,
            parentPath: .root,
            objectIdentity: identity
        ),
    ]

    let forward = HardLinkCanonicalizer.canonicalAttributions(from: paths)
    let reversed = HardLinkCanonicalizer.canonicalAttributions(from: paths.reversed())
    #expect(forward[identity]?.path == second)
    #expect(reversed == forward)
}

@Test("Secondary hard-link mutations have zero allocation effect")
func secondaryHardLinkMutationHasNoAllocationEffect() throws {
    let volumeID = MonitoredVolume.ID("data")
    let identity = FileIdentity(volumeID: volumeID, deviceID: 1, inode: 99)
    let record = try ChangeRecord(
        runID: ScanRun.ID(),
        volumeID: volumeID,
        objectIdentity: identity,
        kind: .eventLinkAdded,
        pathBefore: nil,
        pathAfter: RelativePath(validating: "second-link"),
        effect: .pathOnly
    )

    #expect(record.logicalDelta == 0)
    #expect(record.allocatedDelta == 0)
}

@Test("Canonical transfer across classifications is a zero-sum pair")
func canonicalTransferAcrossClassificationsIsZeroSum() throws {
    let volumeID = MonitoredVolume.ID("data")
    let identity = FileIdentity(volumeID: volumeID, deviceID: 1, inode: 99)
    let old = CanonicalAttribution(
        objectIdentity: identity,
        path: try RelativePath(validating: "Users/alice/file"),
        classification: .ordinary
    )
    let new = CanonicalAttribution(
        objectIdentity: identity,
        path: try RelativePath(validating: "Users/alice/Library/Application Support/DailyDisk/file"),
        classification: .dailyDiskInternal
    )
    let records = try HardLinkCanonicalizer.attributionTransferRecords(
        runID: ScanRun.ID(),
        source: .fsevents,
        objectIdentity: identity,
        footprint: FileFootprint(logicalBytes: 100, allocatedBytes: 128),
        from: old,
        to: new
    )

    #expect(records.count == 2)
    #expect(try AccountingMath.sum(records.map(\.allocatedDelta)) == 0)
    #expect(records[0].classification == .ordinary)
    #expect(records[0].allocatedDelta == -128)
    #expect(records[1].classification == .dailyDiskInternal)
    #expect(records[1].allocatedDelta == 128)
}
