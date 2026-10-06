import Foundation
import Testing

@testable import DailyDiskCore

@Test("Core report models round-trip through JSON")
func reportModelsRoundTripThroughJSON() throws {
    let runID = ScanRun.ID(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
    let report = try DailyReport(
        runID: runID,
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        storageDomainID: StorageDomain.ID("container-1"),
        accounting: AccountingSummary(
            eventAttributedDelta: 10,
            reconciliationCorrection: -2,
            reconciledIndexedDelta: 8,
            dailyDiskOverheadDelta: 1,
            physicalUsedDelta: 12,
            physicalUnattributedDelta: 3
        ),
        reconciliation: ReconciliationBreakdown(
            missedAdditions: 0,
            staleRemovals: -2,
            sizeCorrections: 0,
            attributionTransfers: 0,
            affectedRecords: 1
        ),
        coverage: ScanCoverage(
            visitedPathCount: 100,
            indexedObjectCount: 98,
            unreadablePathCount: 1,
            transientErrorCount: 1
        ),
        largestGrowth: [
            RankedPathChange(
                path: try RelativePath(validating: "Users/alice/cache"),
                allocatedDelta: 10,
                logicalDelta: 12
            )
        ],
        largestShrinkage: [],
        diagnostics: ["One path was unreadable"]
    )

    let data = try JSONEncoder().encode(report)
    let decoded = try JSONDecoder().decode(DailyReport.self, from: data)

    #expect(decoded == report)
    #expect(decoded.pathRanking == nil)
    let ranking = try ReportPathRankingBuilder().finish()
    let enriched = try decoded.replacingPathRanking(ranking)
    #expect(enriched.accounting == report.accounting)
    #expect(enriched.coverage == report.coverage)
    #expect(enriched.generatedAt == report.generatedAt)
    #expect(try JSONDecoder().decode(DailyReport.self, from: JSONEncoder().encode(enriched)) == enriched)
}

@Test("FSEvent flags use native CoreServices bit values and preserve unknown bits")
func fileEventFlagsUseNativeValues() throws {
    #expect(FileSystemEventFlags.mustScanSubdirectories.rawValue == 0x0000_0001)
    #expect(FileSystemEventFlags.historyDone.rawValue == 0x0000_0010)
    #expect(FileSystemEventFlags.created.rawValue == 0x0000_0100)
    #expect(FileSystemEventFlags.isFile.rawValue == 0x0001_0000)

    let flags = FileSystemEventFlags.created
        .union(.isFile)
        .union(FileSystemEventFlags(rawValue: 0x8000_0000))
    let data = try JSONEncoder().encode(flags)
    let decoded = try JSONDecoder().decode(FileSystemEventFlags.self, from: data)

    #expect(decoded == flags)
}

@Test("Decoding cannot bypass relative-path validation")
func relativePathDecodingValidates() throws {
    struct EncodedPath: Encodable {
        let bytes: Data
    }
    let invalid = try JSONEncoder().encode(EncodedPath(bytes: Data("/absolute".utf8)))

    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(RelativePath.self, from: invalid)
    }
}

@Test("Decoding cannot bypass footprint validation")
func footprintDecodingValidates() throws {
    let invalid = Data(#"{"logicalBytes":-1,"allocatedBytes":0}"#.utf8)

    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(FileFootprint.self, from: invalid)
    }
}

@Test("Decoding rejects a change whose stored delta disagrees with its effect")
func changeDecodingValidatesDerivedDelta() throws {
    let volumeID = MonitoredVolume.ID("data")
    let identity = FileIdentity(volumeID: volumeID, deviceID: 1, inode: 1)
    let change = try ChangeRecord(
        runID: ScanRun.ID(),
        volumeID: volumeID,
        objectIdentity: identity,
        kind: .eventCreated,
        pathBefore: nil,
        pathAfter: RelativePath(validating: "file"),
        effect: .objectTransition(
            before: nil,
            after: FileFootprint(logicalBytes: 10, allocatedBytes: 16)
        )
    )
    let encoded = try JSONEncoder().encode(change)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["allocatedDelta"] = 99
    let invalid = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(ChangeRecord.self, from: invalid)
    }
}

@Test("Decoding rejects an inconsistent accounting summary")
func accountingSummaryDecodingValidatesFormula() {
    let invalid = Data(
        #"{"eventAttributedDelta":10,"reconciliationCorrection":2,"reconciledIndexedDelta":99,"dailyDiskOverheadDelta":0}"#
            .utf8
    )

    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(AccountingSummary.self, from: invalid)
    }
}

@Test("Inventory records reject mismatched identity and parent data")
func inventoryRecordValidation() throws {
    let volumeID = MonitoredVolume.ID("data")
    let identity = FileIdentity(volumeID: volumeID, deviceID: 1, inode: 1)
    let otherIdentity = FileIdentity(volumeID: volumeID, deviceID: 1, inode: 2)
    let path = try InventoryPath(
        volumeID: volumeID,
        relativePath: RelativePath(validating: "file"),
        parentPath: .root,
        objectIdentity: identity
    )
    let object = InventoryObject(
        identity: otherIdentity,
        kind: .regular,
        footprint: try FileFootprint(logicalBytes: 1, allocatedBytes: 1),
        linkCount: 1,
        modifiedAt: nil,
        metadataChangedAt: nil
    )

    #expect(throws: ModelValidationError.inconsistentObjectIdentity) {
        _ = try InventoryRecord(object: object, path: path)
    }
}
