import DailyDiskCore
import Foundation

public struct LocalReportWriter: ReportWriting {
    public static var defaultReportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DailyDisk/Reports", isDirectory: true)
    }

    private let directory: URL

    public init(directory: URL = LocalReportWriter.defaultReportDirectory) {
        self.directory = directory
    }

    public func existingReport(runID: ScanRun.ID) async throws -> DailyReport? {
        let file =
            directory
            .appendingPathComponent(runID.rawValue.uuidString, isDirectory: true)
            .appendingPathComponent("report.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DailyReport.self, from: Data(contentsOf: file))
    }

    public func write(report: DailyReport) async throws -> ReportArtifacts {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let runName = report.runID.rawValue.uuidString
        let targetDirectory = directory.appendingPathComponent(runName, isDirectory: true)
        let existingJSON = targetDirectory.appendingPathComponent("report.json")
        let existingMarkdown = targetDirectory.appendingPathComponent("report.md")
        if FileManager.default.fileExists(atPath: targetDirectory.path) {
            guard FileManager.default.fileExists(atPath: existingJSON.path),
                FileManager.default.fileExists(atPath: existingMarkdown.path)
            else {
                throw ReportWriterError.incompleteExistingArtifact(runName)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard try decoder.decode(DailyReport.self, from: Data(contentsOf: existingJSON)) == report else {
                throw ReportWriterError.conflictingExistingArtifact(runName)
            }
            return ReportArtifacts(jsonURL: existingJSON, markdownURL: existingMarkdown)
        }
        let stagingDirectory = directory.appendingPathComponent(
            ".\(runName).staging.\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            let stagedJSON = stagingDirectory.appendingPathComponent("report.json")
            let stagedMarkdown = stagingDirectory.appendingPathComponent("report.md")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(report).write(to: stagedJSON)
            try Data(markdown(report).utf8).write(to: stagedMarkdown)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedJSON.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedMarkdown.path)

            try FileManager.default.moveItem(at: stagingDirectory, to: targetDirectory)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: targetDirectory.path
            )
        } catch {
            try? FileManager.default.removeItem(at: stagingDirectory)
            throw error
        }
        return ReportArtifacts(
            jsonURL: targetDirectory.appendingPathComponent("report.json"),
            markdownURL: targetDirectory.appendingPathComponent("report.md")
        )
    }

    private func markdown(_ report: DailyReport) -> String {
        let accounting = report.accounting
        var lines = [
            "# DailyDisk report",
            "",
            "- Run: `\(report.runID.rawValue.uuidString)`",
            "- Generated: \(report.generatedAt.formatted(.iso8601))",
            "- Storage domain: `\(report.storageDomainID.rawValue)`",
            "",
            "## Accounting",
            "",
            "| Metric | Signed change |",
            "| --- | ---: |",
            "| Snapshot comparison | \(bytes(accounting.snapshotComparedDelta)) |",
            "| Event-attributed | \(bytes(accounting.eventAttributedDelta)) |",
            "| Reconciliation correction | \(bytes(accounting.reconciliationCorrection)) |",
            "| Reconciled indexed | \(bytes(accounting.reconciledIndexedDelta)) |",
            "| DailyDisk overhead | \(bytes(accounting.dailyDiskOverheadDelta)) |",
            "| Physical used | \(optionalBytes(accounting.physicalUsedDelta)) |",
            "| Physical unattributed | \(optionalBytes(accounting.physicalUnattributedDelta)) |",
            "",
            "## Coverage",
            "",
            "- Visited paths: \(report.coverage.visitedPathCount)",
            "- Indexed objects: \(report.coverage.indexedObjectCount)",
            "- Unreadable paths: \(report.coverage.unreadablePathCount)",
            "- Transient errors: \(report.coverage.transientErrorCount)",
            "",
        ]
        appendChanges(title: "Largest growth", values: report.largestGrowth, to: &lines)
        appendChanges(title: "Largest shrinkage", values: report.largestShrinkage, to: &lines)
        if let ranking = report.pathRanking {
            lines.append(
                "Direct-path counts: growth \(ranking.growthPathCount), release \(ranking.releasePathCount), logical-only \(ranking.logicalOnlyPathCount). Rankings are limited to ten entries each; inspect the ledger in the app for all records."
            )
            appendChanges(
                title: "Directory descendant growth (overlapping)", values: ranking.directoryGrowth, to: &lines)
            appendChanges(
                title: "Directory descendant release (overlapping)", values: ranking.directoryRelease, to: &lines)
        }

        if let diagnosis = report.physicalDiagnosis {
            lines += [
                "## Physical diagnostics",
                "",
                "- Snapshot count delta: \(signed(diagnosis.snapshotCountDelta))",
                "- Unique deleted-open logical bytes: \(bytes(diagnosis.uniqueDeletedOpenLogicalBytes))",
                "- Likely causes: \(diagnosis.likelyCauses.map(\.rawValue).joined(separator: ", "))",
                "",
            ]
            lines += diagnosis.notes.map { "- \(markdownText($0))" }
            lines.append("")
        }
        if !report.diagnostics.isEmpty {
            lines += ["## Diagnostics", ""]
            lines += report.diagnostics.map { "- \(markdownText($0))" }
            lines.append("")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func appendChanges(
        title: String,
        values: [RankedPathChange],
        to lines: inout [String]
    ) {
        lines += ["## \(title)", ""]
        guard !values.isEmpty else {
            lines += ["No entries.", ""]
            return
        }
        lines += ["| Path | Allocated | Logical |", "| --- | ---: | ---: |"]
        for value in values {
            lines.append(
                "| <code>\(html(displayPath(value.path)))</code> | "
                    + "\(bytes(value.allocatedDelta)) | \(bytes(value.logicalDelta)) |"
            )
        }
        lines.append("")
    }

    private func html(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "|", with: "&#124;")
            .replacingOccurrences(of: "`", with: "&#96;")
            .replacingOccurrences(of: "\r", with: "&#13;")
            .replacingOccurrences(of: "\n", with: "&#10;")
    }

    private func markdownText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
            .replacingOccurrences(of: "!", with: "\\!")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func displayPath(_ path: RelativePath) -> String {
        if let value = String(data: path.bytes, encoding: .utf8) {
            return value.isEmpty ? "." : value
        }
        return path.displayString + " [raw:" + path.bytes.map { String(format: "%02x", $0) }.joined() + "]"
    }

    private func bytes(_ value: Int64) -> String {
        let sign = value > 0 ? "+" : ""
        return sign + ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func optionalBytes(_ value: Int64?) -> String {
        value.map(bytes) ?? "unknown"
    }

    private func signed(_ value: Int) -> String {
        value > 0 ? "+\(value)" : String(value)
    }
}

public enum ReportWriterError: Error, Equatable, Sendable {
    case incompleteExistingArtifact(String)
    case conflictingExistingArtifact(String)
}
