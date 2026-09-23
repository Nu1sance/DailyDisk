import DailyDiskCore
import Foundation
import Testing

@testable import DailyDiskPlatform

private func reportingFixture() throws -> DailyReport {
    try DailyReport(
        runID: ScanRun.ID(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!),
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        storageDomainID: StorageDomain.ID("domain"),
        accounting: AccountingSummary(
            eventAttributedDelta: 2_048,
            reconciliationCorrection: -1_024,
            reconciledIndexedDelta: 1_024,
            dailyDiskOverheadDelta: 512,
            physicalUsedDelta: 4_096,
            physicalUnattributedDelta: 2_560
        ),
        reconciliation: ReconciliationBreakdown(
            missedAdditions: 0,
            staleRemovals: 0,
            sizeCorrections: -1_024,
            attributionTransfers: 0,
            affectedRecords: 1
        ),
        coverage: ScanCoverage(
            visitedPathCount: 10,
            indexedObjectCount: 9,
            unreadablePathCount: 0,
            transientErrorCount: 1
        ),
        largestGrowth: [
            RankedPathChange(
                path: RelativePath(validating: "Users/alice/cache"),
                allocatedDelta: 2_048,
                logicalDelta: 4_096
            )
        ],
        largestShrinkage: [],
        diagnostics: ["One transient file disappeared"]
    )
}

@Test("Report writer atomically emits JSON and human-readable Markdown")
func reportWriterEmitsArtifacts() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DailyDiskReportWriterTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let report = try reportingFixture()
    let artifacts = try await LocalReportWriter(directory: directory).write(report: report)

    let decoded = try JSONDecoder.configuredForReports.decode(
        DailyReport.self,
        from: Data(contentsOf: artifacts.jsonURL)
    )
    #expect(decoded == report)
    let markdown = try String(contentsOf: artifacts.markdownURL, encoding: .utf8)
    #expect(markdown.contains("Reconciliation correction"))
    #expect(markdown.contains("Physical unattributed"))
    #expect(markdown.contains("Users/alice/cache"))
    let permissions =
        try FileManager.default.attributesOfItem(atPath: artifacts.jsonURL.path)[.posixPermissions]
        as? NSNumber
    #expect((permissions?.intValue ?? 0) & 0o077 == 0)

    let retried = try await LocalReportWriter(directory: directory).write(report: report)
    #expect(retried == artifacts)
    #expect(FileManager.default.fileExists(atPath: retried.jsonURL.path))
    #expect(FileManager.default.fileExists(atPath: retried.markdownURL.path))
}

@Test("Structured logger redacts paths and rotates bounded files")
func structuredLoggerRedactsAndRotates() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DailyDiskLoggerTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let logger = try StructuredLogger(directory: directory, maximumBytes: 220, retainedFiles: 2)
    for index in 0..<8 {
        try await logger.log(
            level: .info,
            event: "scan-\(index)",
            publicMetadata: ["count": .integer(1)],
            sensitiveMetadata: ["path": "/Users/alice/private-\(index)"]
        )
    }

    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    #expect(files.count <= 2)
    let combined = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
    #expect(!combined.contains("/Users/alice"))
    #expect(combined.contains("sha256:"))
    await #expect(throws: StructuredLoggerError.invalidEventIdentifier) {
        try await logger.log(level: .error, event: "/Users/alice/private")
    }
}

@Test("Retention policy removes old files and preserves recent reports")
func retentionPolicyPrunesByAge() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DailyDiskRetentionTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("DailyDisk", isDirectory: true)
    let logs = root.appendingPathComponent("Logs", isDirectory: true)
    let reports = root.appendingPathComponent("Reports", isDirectory: true)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let old = logs.appendingPathComponent("operations.1.jsonl")
    let recentDirectory = reports.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: recentDirectory, withIntermediateDirectories: true)
    let recent = recentDirectory.appendingPathComponent("report.json")
    try Data().write(to: old)
    try Data().write(to: recent)
    let now = Date(timeIntervalSince1970: 10_000)
    try FileManager.default.setAttributes(
        [.modificationDate: now.addingTimeInterval(-1_000)],
        ofItemAtPath: old.path
    )
    try FileManager.default.setAttributes(
        [.modificationDate: now],
        ofItemAtPath: recent.path
    )
    let policy = try RetentionPolicy(logRetention: 100, reportRetention: 100)
    let removed = try policy.prune(managedRoot: root, now: now)

    #expect(removed.map(\.lastPathComponent) == [old.lastPathComponent])
    #expect(FileManager.default.fileExists(atPath: recent.path))
}

extension JSONDecoder {
    fileprivate static var configuredForReports: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
