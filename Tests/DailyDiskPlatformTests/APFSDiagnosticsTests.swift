import DailyDiskCore
import Darwin
import Foundation
import Testing

@testable import DailyDiskPlatform

private struct DiagnosticsProcessRunner: ProcessRunning {
    let output: Data
    var status: Int32 = 0

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        ProcessResult(terminationStatus: status, standardOutput: output, standardError: Data())
    }
}

private func diagnosticsVolume() -> MonitoredVolume {
    MonitoredVolume(
        id: MonitoredVolume.ID("diagnostics-volume"),
        storageDomainID: StorageDomain.ID("diagnostics-domain"),
        filesystemUUID: UUID(),
        eventStoreUUID: nil,
        deviceID: 1,
        mountPath: "/",
        displayName: "System",
        role: .system,
        isInternal: true,
        isRemovable: false,
        isReadOnly: true,
        supportsPersistentEvents: false,
        topologyFingerprint: "diagnostics",
        inventoryMode: .metricsOnly
    )
}

@Test("Snapshot parser retains optional metadata without inventing shared size")
func snapshotParser() throws {
    let testsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let data = try Data(
        contentsOf: testsDirectory.appendingPathComponent("Fixtures/diskutil/snapshots/list.plist")
    )
    let values = try DiskutilSnapshotParser.parse(data)

    #expect(values.count == 2)
    #expect(values[0].uuid == UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
    #expect(values[0].isPurgeable == true)
    #expect(values[0].allocatedBytesEstimate == 4_096)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    #expect(values[0].createdAt == formatter.date(from: "2026-08-27-101530"))
    #expect(values[1].allocatedBytesEstimate == nil)
    #expect(values[1].createdAt == nil)
}

@Test("Snapshot provider maps diskutil metadata to one sampled instant")
func snapshotProvider() async throws {
    let testsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let data = try Data(
        contentsOf: testsDirectory.appendingPathComponent("Fixtures/diskutil/snapshots/list.plist")
    )
    let instant = Date(timeIntervalSince1970: 123)
    let provider = APFSSnapshotProvider(
        processRunner: DiagnosticsProcessRunner(output: data),
        now: { instant }
    )
    let values = try await provider.snapshots(volume: diagnosticsVolume())

    #expect(values.count == 2)
    #expect(values.allSatisfy { $0.sampledAt == instant })
    #expect(values.allSatisfy { $0.volumeID == diagnosticsVolume().id })
}

@Test("lsof field parser handles spaces and keeps individual holders")
func deletedOpenFileParser() throws {
    let fields = [
        "p123", "ctest process", "f4u", "k0", "tREG", "D0x1000012", "i99", "s8192",
        "n/private/path with spaces/deleted", "\np124", "csecond", "f5r", "k0", "tREG",
        "D0x1000012", "i99", "s8192", "n/private/path with spaces/deleted",
    ]
    let data = fields.joined(separator: "\0").data(using: .utf8)!
    let values = try LsofDeletedFileParser.parse(data)

    #expect(values.count == 2)
    #expect(values[0].command == "test process")
    #expect(values[0].path == "/private/path with spaces/deleted")
    #expect(values[0].logicalBytes == 8_192)
    #expect(values[0].identityKey == values[1].identityKey)
}

@Test("Deleted-open probe treats lsof no-match status as an empty healthy result")
func deletedOpenProbeNoMatches() async throws {
    let probe = DeletedOpenFileProbe(
        processRunner: DiagnosticsProcessRunner(output: Data(), status: 1)
    )
    #expect(try await probe.deletedOpenFiles().isEmpty)
}

@Test("Real deleted-open probe parses lsof k link-count fields")
func realDeletedOpenProbe() async throws {
    guard ProcessInfo.processInfo.environment["CI"] == nil else { return }
    let values = try await DeletedOpenFileProbe().deletedOpenFiles()
    #expect(values.allSatisfy { $0.logicalBytes >= 0 && $0.nativeDeviceID != nil })
}

private struct OverheadVolumeDiscovery: VolumeDiscovering {
    let topology: VolumeTopology
    func discoverInternalAPFSVolumes() async throws -> VolumeTopology { topology }
}

@Test("DailyDisk overhead sampler reports allocated blocks under its actual storage domain")
func overheadSampler() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DailyDiskOverheadTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(repeating: 1, count: 8_192).write(to: root.appendingPathComponent("database"))

    let domainID = StorageDomain.ID("overhead-domain")
    let domain = StorageDomain(
        id: domainID,
        containerIdentifier: "disk-test",
        displayName: "Test",
        isInternal: true
    )
    var rootStatus = Darwin.stat()
    #expect(lstat(root.path, &rootStatus) == 0)
    let volume = MonitoredVolume(
        id: MonitoredVolume.ID("overhead-volume"),
        storageDomainID: domainID,
        filesystemUUID: UUID(),
        eventStoreUUID: UUID(),
        deviceID: UInt64(UInt32(bitPattern: rootStatus.st_dev)),
        mountPath: root.path,
        displayName: "Data",
        role: .data,
        isInternal: true,
        isRemovable: false,
        isReadOnly: false,
        supportsPersistentEvents: true,
        topologyFingerprint: "overhead"
    )
    let discovery = OverheadVolumeDiscovery(
        topology: VolumeTopology(domains: [domain], volumes: [volume], discoveredAt: Date())
    )
    let sample = try await DailyDiskOverheadSampler(
        rootURL: root,
        volumeDiscovery: discovery
    ).sample(storageDomainID: domainID)
    #expect(sample.storageDomainID == domainID)
    #expect(sample.allocatedBytes >= 8_192)
}
