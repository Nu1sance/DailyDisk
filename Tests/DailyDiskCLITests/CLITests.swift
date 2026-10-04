import CryptoKit
import DailyDiskCore
import DailyDiskStore
import Foundation
import Testing

@Test("CLI diagnostic formatter redacts raw paths deterministically")
func diagnosticPathRedaction() throws {
    let path = try RelativePath(validating: "Users/alice/private")
    let first = DiagnosticFormatter.redactedPath(path)
    let second = DiagnosticFormatter.redactedPath(path)

    #expect(first == second)
    #expect(first.hasPrefix("sha256:"))
    #expect(!first.contains("alice"))
}

@Test("Executable CLI performs database inspection without modifying source files")
func executableCLIReadOnlyInspection() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DailyDiskCLITests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let databaseURL = root.appendingPathComponent("DailyDisk.sqlite")
    try await createPreparedDatabase(at: databaseURL)
    defer { try? FileManager.default.removeItem(at: root) }

    let lockURL = databaseURL.appendingPathExtension("lock")
    #expect(FileManager.default.fileExists(atPath: lockURL.path))
    let before = try fileFingerprints(in: root)
    let verify = try runCLI(["verify", "--database", databaseURL.path])
    #expect(verify.status == 0)
    #expect(String(decoding: verify.stdout, as: UTF8.self).contains("healthy: true"))
    let status = try runCLI(["status", "--database", databaseURL.path])
    #expect(status.status == 0)
    #expect(!String(decoding: status.stdout, as: UTF8.self).contains("/Users/alice/private-mount"))
    let diagnostics = try runCLI(["diagnostics", "--database", databaseURL.path])
    #expect(diagnostics.status == 0)
    let after = try fileFingerprints(in: root)
    #expect(after == before)
    #expect(FileManager.default.fileExists(atPath: lockURL.path))

    let invalid = try runCLI(["bogus", "--database", "/does/not/exist.sqlite"])
    #expect(invalid.status == 64)
    #expect(String(decoding: invalid.stderr, as: UTF8.self).contains("unknown command"))
    let jsonWithoutConsent = try runCLI(["report", "--json", "--database", databaseURL.path])
    #expect(jsonWithoutConsent.status == 64)
    let noReport = try runCLI(["report", "--database", databaseURL.path])
    #expect(noReport.status == 66)
}

private func createPreparedDatabase(at url: URL) async throws {
    let store = try SQLiteInventoryStore(databaseURL: url)
    try await store.prepare()
    let domain = StorageDomain(
        id: StorageDomain.ID("cli-domain"),
        containerIdentifier: "disk-cli",
        displayName: "CLI",
        isInternal: true
    )
    let volume = MonitoredVolume(
        id: MonitoredVolume.ID("cli-volume"),
        storageDomainID: domain.id,
        filesystemUUID: UUID(),
        eventStoreUUID: nil,
        deviceID: 1,
        mountPath: "/Users/alice/private-mount",
        displayName: "Private volume",
        role: .data,
        isInternal: true,
        isRemovable: false,
        isReadOnly: true,
        supportsPersistentEvents: false,
        topologyFingerprint: "cli",
        inventoryMode: .metricsOnly
    )
    try await store.register(scope: StorageDomainScope(domain: domain, volumes: [volume]))
}

private struct FileFingerprint: Equatable {
    let size: Int
    let modificationDate: Date?
    let digest: String
}

private func fileFingerprints(in directory: URL) throws -> [String: FileFingerprint] {
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    return try Dictionary(
        uniqueKeysWithValues: names.map { name in
            let url = directory.appendingPathComponent(name)
            let data = try Data(contentsOf: url)
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return (
                name,
                FileFingerprint(
                    size: values.fileSize ?? 0,
                    modificationDate: values.contentModificationDate,
                    digest: digest
                )
            )
        })
}

private func runCLI(_ arguments: [String]) throws -> (status: Int32, stdout: Data, stderr: Data) {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let executable = root.appendingPathComponent(".build/debug/dailydiskctl")
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    return (
        process.terminationStatus,
        stdout.fileHandleForReading.readDataToEndOfFile(),
        stderr.fileHandleForReading.readDataToEndOfFile()
    )
}

@Test("CLI byte formatter preserves signed correction direction")
func diagnosticByteFormatting() {
    #expect(DiagnosticFormatter.bytes(1_024).hasPrefix("+"))
    #expect(DiagnosticFormatter.bytes(-1_024).hasPrefix("-"))
    #expect(DiagnosticFormatter.optionalBytes(nil) == "unknown")
}

@Test("CLI product metadata agrees with the shared source and rejects build-number options")
func cliSharedVersion() throws {
    for (command, expected) in [
        ("version", DailyDiskProduct.version), ("build-number", DailyDiskProduct.buildNumber),
        ("minimum-system-version", DailyDiskProduct.minimumMacOSVersion),
    ] {
        let result = try runCLI([command])
        #expect(result.status == 0)
        #expect(
            String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == expected)
    }
    #expect(try runCLI(["build-number", "--database", "/does/not/exist"]).status == 64)
}
