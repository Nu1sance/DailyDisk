import Foundation
import Testing

@testable import DailyDiskCore

private func rankingChange(
    _ path: String, before: Int64 = 0, after: Int64, logicalAfter: Int64? = nil,
    classification: InventoryClassification = .ordinary
) throws -> ChangeRecord {
    let volume = MonitoredVolume.ID("test-volume")
    return try ChangeRecord(
        runID: ScanRun.ID(), volumeID: volume,
        objectIdentity: FileIdentity(volumeID: volume, deviceID: 1, inode: 1), kind: .eventModified,
        pathBefore: RelativePath(validating: path), pathAfter: RelativePath(validating: path),
        effect: .objectTransition(
            before: FileFootprint(logicalBytes: before, allocatedBytes: before),
            after: FileFootprint(logicalBytes: logicalAfter ?? after, allocatedBytes: after)),
        classification: classification)
}

@Test("Deep ancestor rollups cannot displace unrelated direct changes")
func directRankingSeparatesAncestors() throws {
    var builder = ReportPathRankingBuilder()
    let deep = "a/b/c/d/e/f/g/h/i/j/k/backup.sqlite"
    try builder.append(rankingChange(deep, after: 5_000_000))
    for index in 0..<15 { try builder.append(rankingChange("sessions/record-\(index)", after: 100)) }
    let ranking = try builder.finish()
    #expect(ranking.growth.count == 10)
    #expect(ranking.growth.first?.path.displayString == deep)
    #expect(ranking.growth.dropFirst().allSatisfy { $0.path.displayString.hasPrefix("sessions/record-") })
    #expect(ranking.growthPathCount == 16)
    #expect(ranking.directoryGrowth.contains { $0.path.displayString == "a" })
    #expect(!ranking.growth.contains { $0.path.displayString == "a" })
    #expect(ranking.growth[1].path.displayString == "sessions/record-0")
    #expect(ranking.growth[3].path.displayString == "sessions/record-10")
}

@Test("Ranking nets repeated paths, counts logical-only changes and excludes internal overhead")
func directRankingNetsPaths() throws {
    var builder = ReportPathRankingBuilder()
    try builder.append(rankingChange("cancelled", after: 100))
    try builder.append(rankingChange("cancelled", before: 100, after: 0))
    try builder.append(rankingChange("logical", before: 100, after: 100, logicalAfter: 150))
    try builder.append(rankingChange("released", before: 200, after: 10))
    try builder.append(rankingChange("internal", after: 999, classification: .dailyDiskInternal))
    let ranking = try builder.finish()
    #expect(ranking.growthPathCount == 0)
    #expect(ranking.releasePathCount == 1)
    #expect(ranking.logicalOnlyPathCount == 1)
    #expect(ranking.release.first?.allocatedDelta == -190)
    #expect(try JSONDecoder().decode(ReportPathRanking.self, from: JSONEncoder().encode(ranking)) == ranking)
}

@Test("Canonical transfers debit the old path and credit the new path")
func rankingTransferPaths() throws {
    let volume = MonitoredVolume.ID("test-volume")
    let transfer = UUID()
    var builder = ReportPathRankingBuilder()
    for direction: AttributionTransferDirection in [.debit, .credit] {
        try builder.append(
            ChangeRecord(
                runID: ScanRun.ID(), volumeID: volume,
                objectIdentity: FileIdentity(volumeID: volume, deviceID: 1, inode: 1),
                kind: .eventAttributionTransfer,
                pathBefore: RelativePath(validating: "old/file"), pathAfter: RelativePath(validating: "new/file"),
                transferID: transfer,
                effect: .attributionTransfer(
                    footprint: FileFootprint(logicalBytes: 10, allocatedBytes: 16), direction: direction)))
    }
    let ranking = try builder.finish()
    #expect(ranking.growth.first?.path.displayString == "new/file")
    #expect(ranking.release.first?.path.displayString == "old/file")
    #expect(ranking.growth.first!.allocatedDelta + ranking.release.first!.allocatedDelta == 0)
}
