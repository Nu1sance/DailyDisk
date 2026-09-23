import DailyDiskCore
import DailyDiskStore
import Foundation
import Testing

@testable import DailyDiskPlatform

@Test("Safe reset atomically replaces only the trusted DailyDisk root and preserves control")
func safeDataReset() async throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("DailyDiskResetTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let root = parent.appendingPathComponent("DailyDisk", isDirectory: true)
    let databaseURL = root.appendingPathComponent("DailyDisk.sqlite")
    defer { try? FileManager.default.removeItem(at: parent) }

    var store: SQLiteInventoryStore? = try SQLiteInventoryStore(databaseURL: databaseURL)
    try await store?.prepare()
    store = nil
    let control = try RunControlStore(rootURL: root.appendingPathComponent("Control"))
    try await control.enqueue(DailyDiskRunRequest())
    _ = try await control.cancelPendingRequest(
        requestID: try #require(try await control.latestProgress()?.requestID)
    )
    let reports = root.appendingPathComponent("Reports", isDirectory: true)
    try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
    try Data("private".utf8).write(to: reports.appendingPathComponent("report.json"))
    let sibling = parent.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: sibling)

    do {
        let reader = try SQLiteReportStore(databaseURL: databaseURL)
        #expect(throws: (any Error).self) {
            _ = try DatabaseResetLease(databaseURL: databaseURL)
        }
        _ = reader
    }
    let lease = try DatabaseResetLease(databaseURL: databaseURL)
    #expect(throws: (any Error).self) {
        _ = try SQLiteInventoryStore(databaseURL: databaseURL)
    }
    try await control.clearInactiveState()
    try DailyDiskDataResetter(testDataRootURL: root).reset(holding: lease)
    _ = lease

    #expect(FileManager.default.fileExists(atPath: root.path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Control").path))
    #expect(!FileManager.default.fileExists(atPath: databaseURL.path))
    #expect(!FileManager.default.fileExists(atPath: reports.path))
    #expect(FileManager.default.fileExists(atPath: sibling.path))
}

@Test("Safe reset rejects symlink and non-DailyDisk roots")
func safeResetRejectsUntrustedRoots() throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("DailyDiskResetUnsafe", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    let target = parent.appendingPathComponent("target", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let link = parent.appendingPathComponent("DailyDisk")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    let databaseURL = target.appendingPathComponent("DailyDisk.sqlite")
    let lease = try DatabaseResetLease(databaseURL: databaseURL)
    #expect(throws: DailyDiskDataResetError.unsafeRoot) {
        try DailyDiskDataResetter(testDataRootURL: link).reset(holding: lease)
    }
    #expect(throws: DailyDiskDataResetError.untrustedRoot) {
        try DailyDiskDataResetter(testDataRootURL: parent).reset(holding: lease)
    }
}
