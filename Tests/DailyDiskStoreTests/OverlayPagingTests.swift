import DailyDiskCore
import Foundation
import Testing

@testable import DailyDiskStore

private actor PreservationObserver: ScanWorkObserving {
    var counters = ScanProgressCounters()
    let cancelAfterPage: Bool
    init(cancelAfterPage: Bool = false) { self.cancelAfterPage = cancelAfterPage }
    func checkpoint(_ delta: ScanProgressDelta) async throws {
        if cancelAfterPage && counters.preservedPaths > 0 { throw CancellationError() }
        counters = try counters.applying(delta)
    }
}

@Test("Opaque preservation pages merged records, deduplicates roots and preserves exact path boundaries")
func opaqueOverlayPaging() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    var records = try (0..<4_100).map {
        try fixture.record(
            path: String(format: "cache/sub/%05d", $0), inode: UInt64($0 + 1), logicalBytes: 1, allocatedBytes: 1)
    }
    for (index, name) in ["cache.more", "cache-neighbor", "cache0"].enumerated() {
        records.append(
            try fixture.record(path: name + "/file", inode: UInt64(10_000 + index), logicalBytes: 1, allocatedBytes: 1))
    }
    let baseline = try await establishBaseline(in: fixture, records: records)
    let run = ScanRun(kind: .full, reason: .manual, status: .running, startedAt: Date())
    try await fixture.store.begin(run: run)
    let generation = try await fixture.store.createStagingGeneration(
        volumeID: fixture.volume.id, runID: run.id, at: run.startedAt)
    let source = InventoryMutationTarget.expectedActive(volumeID: fixture.volume.id)
    let destination = InventoryMutationTarget.stagingGeneration(generation.id)
    var expected = Dictionary(uniqueKeysWithValues: records.map { ($0.path.relativePath, $0) })
    var mutations: [InventoryMutation] = []
    for i in 0..<2_100 {
        mutations.append(.remove(volumeID: fixture.volume.id, path: records[i].path.relativePath))
        expected.removeValue(forKey: records[i].path.relativePath)
    }
    for i in 2_100..<5_200 {
        let record = try fixture.record(
            path: String(format: "cache/sub/%05d", i), inode: UInt64(i + 1), logicalBytes: 2, allocatedBytes: 2)
        mutations.append(.upsert(record))
        expected[record.path.relativePath] = record
    }
    try await fixture.store.stage(mutations: mutations, target: source, for: run.id)
    let observer = PreservationObserver()
    try await fixture.store.preserveOpaqueSubtrees(
        roots: ["cache", "cache/sub", "cache", "cache.more"].map { try RelativePath(validating: $0) },
        from: source, to: destination, for: run.id, observer: observer
    )
    let wanted = expected.values.filter {
        $0.path.relativePath.displayString.hasPrefix("cache/")
            || $0.path.relativePath.displayString.hasPrefix("cache.more/")
    }
    let copied = try await fixture.store.records(target: destination, runID: run.id, paths: Array(expected.keys))
    #expect(Set(copied.map(\.path.relativePath)) == Set(wanted.map(\.path.relativePath)))
    for record in copied { #expect(record == expected[record.path.relativePath]) }
    let counters = await observer.counters
    #expect(counters.processedOpaqueRoots == 2)
    #expect(counters.preservedPaths == UInt64(wanted.count))
    #expect(try await fixture.store.state(for: fixture.volume.id)?.checkpoint == baseline.checkpoint)
    // The same pager drives full diffs; cover both branches across many pages.
    for target in [source, destination] {
        try await fixture.store.finalizeCanonicalAttribution(target: target, runID: run.id, consume: { _ in })
    }
    let collector = DiffCollector()
    try await fixture.store.diff(
        expected: source, authoritative: destination, runID: run.id, consume: { await collector.append($0) })
    #expect(await collector.values.count == 2)
}

@Test("Opaque preservation checks cancellation between bounded pages without changing the baseline")
func opaquePreservationCancellation() async throws {
    let fixture = try await StoreFixture()
    defer { fixture.removeFiles() }
    let records = try (0..<2_050).map {
        try fixture.record(
            path: String(format: "opaque/%05d", $0), inode: UInt64($0 + 1), logicalBytes: 1, allocatedBytes: 1)
    }
    let baseline = try await establishBaseline(in: fixture, records: records)
    let run = ScanRun(kind: .full, reason: .manual, status: .running, startedAt: Date())
    try await fixture.store.begin(run: run)
    let generation = try await fixture.store.createStagingGeneration(
        volumeID: fixture.volume.id, runID: run.id, at: run.startedAt)
    let observer = PreservationObserver(cancelAfterPage: true)
    await #expect(throws: CancellationError.self) {
        try await fixture.store.preserveOpaqueSubtrees(
            roots: [.root], from: .expectedActive(volumeID: fixture.volume.id), to: .stagingGeneration(generation.id),
            for: run.id, observer: observer)
    }
    #expect(await observer.counters.preservedPaths == 1_024)
    #expect(try await fixture.store.state(for: fixture.volume.id)?.checkpoint == baseline.checkpoint)
}
