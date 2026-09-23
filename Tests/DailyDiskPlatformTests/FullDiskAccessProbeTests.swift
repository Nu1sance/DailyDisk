import DailyDiskCore
import Foundation
import Testing

@testable import DailyDiskPlatform

@Test("Full Disk Access probe reports accessible and inconclusive paths operationally")
func fullDiskAccessProbe() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DailyDiskFDAProbe", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = await FullDiskAccessProbe(
        protectedPaths: [root.path, root.appendingPathComponent("missing").path]
    ).probe()
    #expect(result.status == .likelyGranted)
    #expect(result.accessiblePaths == [root.path])
    #expect(result.missingPaths.count == 1)

    let inconclusive = await FullDiskAccessProbe(protectedPaths: []).probe()
    #expect(inconclusive.status == .inconclusive)
}

@Test("Local alert state persists cooldown data privately")
func localAlertStateStore() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DailyDiskAlertState", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let file = root.appendingPathComponent("AlertState.json")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalAlertStateStore(fileURL: file)
    let domain = StorageDomain.ID("domain")
    let state = AlertState(notifiedAt: Date(timeIntervalSince1970: 123), reasons: [.physicalGrowth])
    try await store.save(state, storageDomainID: domain)

    #expect(try await store.state(storageDomainID: domain) == state)
    let permissions =
        try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
        as? NSNumber
    #expect((permissions?.intValue ?? 0) & 0o077 == 0)
}
