import DailyDiskCore
import Darwin
import Foundation
import Testing

@testable import DailyDiskStore

private func w6Usage() throws -> rusage_info_v2 {
    var info = rusage_info_v2()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0)
        }
    }
    guard result == 0 else { throw POSIXError(.EIO) }
    return info
}

@Test(
    "W6 synthetic steady-state write measurement",
    .enabled(if: ProcessInfo.processInfo.environment["DAILYDISK_W6_STRESS"] == "1"))
func w6WriteMeasurement() async throws {
    let count = Int(ProcessInfo.processInfo.environment["DAILYDISK_W6_ROWS"] ?? "100000")!
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("W6Writes-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("experiment.sqlite")
    let volume = MonitoredVolume.ID("synthetic")
    let store = try W6InventoryPrototype(url: url, volume: volume)
    for cycle in 0..<3 {
        let before = try w6Usage().ri_diskio_byteswritten
        let started = Date()
        try await store.begin()
        for offset in stride(from: 0, to: count, by: 1024) {
            var batch: [InventoryRecord] = []
            for i in offset..<min(count, offset + 1024) {
                // Repeated long prefixes and non-monotonic object identity; no real paths.
                let raw = "synthetic/Library/Application Support/group-\(i % 100)/deep/path/\(i)"
                let path = try RelativePath(validating: raw)
                let identity = FileIdentity(volumeID: volume, deviceID: 1, inode: UInt64(i) &* 2_654_435_761)
                let bytes: Int64 = cycle == 2 && i % 100 < 3 ? 8192 : 4096
                batch.append(
                    try InventoryRecord(
                        object: InventoryObject(
                            identity: identity, kind: .regular,
                            footprint: FileFootprint(logicalBytes: bytes, allocatedBytes: bytes), linkCount: 1,
                            modifiedAt: nil, metadataChangedAt: nil),
                        path: InventoryPath(
                            volumeID: volume, relativePath: path, parentPath: PathPolicy.parent(of: path),
                            objectIdentity: identity)))
            }
            try await store.observe(batch)
        }
        let seen = try await store.counters().seenBytes
        try await store.finishTraversal()
        let result = try await store.commit(checkpoint: Data([UInt8(cycle)]), at: Date())
        try await store.markPublished(revision: result.revision)
        try await store.checkpointStorage()
        let usage = try w6Usage()
        let written = usage.ri_diskio_byteswritten - before
        print(
            "W6 rows=\(count) cycle=\(cycle) writes=\(written) seconds=\(Date().timeIntervalSince(started)) rss=\(usage.ri_resident_size) seenPayload=\(seen) objectsUpserted=\(result.changedObjects) pathsChanged=\(result.changedPaths)"
        )
        if cycle == 1 { #expect(result.changedObjects == 0 && result.changedPaths == 0) }
        if cycle == 2 {
            #expect(result.changedObjects == Int64((0..<count).filter { $0 % 100 < 3 }.count))
            #expect(result.changedPaths == 0)
        }
        #expect(try await store.verify())
    }
}
