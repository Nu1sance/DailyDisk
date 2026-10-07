import DailyDiskCore
import Foundation
import Testing

@testable import DailyDiskStore

@Test("Published change ledger pages are complete, filtered, bounded and read-only")
func reportChangePages() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let run = ScanRun(kind: .full, reason: .initialBaseline, status: .running, startedAt: Date())
    try await fixture.store.begin(run: run)
    let db = try SQLiteDatabase(url: fixture.databaseURL)
    let report = try db.prepare(
        """
        INSERT INTO daily_reports(run_id,storage_domain_id,generated_at,event_attributed_delta,
        reconciliation_correction,reconciled_indexed_delta,dailydisk_overhead_delta,payload_json)
        VALUES (?,?,0,0,0,0,0,?)
        """)
    try report.bind(run.id.rawValue.uuidString, at: 1)
    try report.bind(fixture.scope.domain.id.rawValue, at: 2)
    try report.bind(Data("{}".utf8), at: 3)
    _ = try report.step()
    try db.transaction {
        for index in 0..<231 {
            let path = try RelativePath(validating: "changes/file-\(index)")
            let before: Int64 = index % 3 == 1 ? 100 : 0
            let after: Int64 = index % 3 == 0 ? 100 : 0
            let change = try ChangeRecord(
                runID: run.id, volumeID: fixture.volume.id,
                objectIdentity: FileIdentity(volumeID: fixture.volume.id, deviceID: 42, inode: UInt64(index)),
                kind: .eventModified, pathBefore: path, pathAfter: path,
                effect: .objectTransition(
                    before: FileFootprint(logicalBytes: before, allocatedBytes: before),
                    after: FileFootprint(logicalBytes: after + 1, allocatedBytes: after)))
            let row = try db.prepare(
                """
                INSERT INTO change_ledger(run_id,volume_id,kind,source,logical_delta,allocated_delta,classification,payload_json)
                VALUES (?,?,'eventModified','event',?,?,'ordinary',?)
                """)
            try row.bind(run.id.rawValue.uuidString, at: 1)
            try row.bind(fixture.volume.id.rawValue, at: 2)
            try row.bind(change.logicalDelta, at: 3)
            try row.bind(change.allocatedDelta, at: 4)
            try row.bind(JSONEncoder().encode(change), at: 5)
            _ = try row.step()
        }
    }
    let actualWAL = URL(fileURLWithPath: fixture.databaseURL.path + "-wal")
    let beforeData = try Data(contentsOf: actualWAL)
    let reader = try SQLiteReportStore(databaseURL: fixture.databaseURL)
    var cursor: Int64 = 0
    var ids: [Int64] = []
    repeat {
        let page = try await reader.reportChangePage(
            runID: run.id, storageDomainID: fixture.scope.domain.id,
            afterSequence: cursor, limit: 17)
        #expect(page.entries.count <= 17)
        ids += page.entries.map(\.id)
        guard let next = page.nextSequence else { break }
        #expect(next > cursor)
        cursor = next
    } while true
    #expect(ids.count == 231)
    #expect(Set(ids).count == 231)
    #expect(ids == ids.sorted())
    for filter in [ReportChangeFilter.growth, .release, .logicalOnly] {
        let page = try await reader.reportChangePage(
            runID: run.id, storageDomainID: fixture.scope.domain.id,
            limit: 100, filter: filter)
        #expect(page.entries.count == 77)
        #expect(page.nextSequence == nil)
    }
    let absent = try await reader.reportChangePage(runID: run.id, storageDomainID: StorageDomain.ID("other"))
    #expect(absent.entries.isEmpty)
    await #expect(throws: (any Error).self) {
        try await reader.reportChangePage(runID: run.id, storageDomainID: fixture.scope.domain.id, afterSequence: -1)
    }
    let ranking = try await reader.rebuiltPathRanking(runID: run.id, storageDomainID: fixture.scope.domain.id)
    #expect(ranking.growthPathCount == 77)
    #expect(ranking.releasePathCount == 77)
    #expect(ranking.logicalOnlyPathCount == 77)
    #expect(ranking.growth.count == 10)
    #expect(try Data(contentsOf: actualWAL) == beforeData)
}

@Test("Notification samples use the exact committed run and domain")
func notificationSampleScope() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let baseline = try await establishBaseline(in: fixture)
    let reader = try SQLiteReportStore(databaseURL: fixture.databaseURL)
    let sample = try await reader.storageSampleForReport(runID: baseline.run.id, domainID: fixture.scope.domain.id)
    #expect(sample?.availableBytes == baseline.sample.availableBytes)
    #expect(sample?.sampledAt == baseline.sample.sampledAt)
    #expect(try await reader.storageSampleForReport(runID: baseline.run.id, domainID: StorageDomain.ID("other")) == nil)
    #expect(try await reader.storageSampleForReport(runID: ScanRun.ID(), domainID: fixture.scope.domain.id) == nil)
}
