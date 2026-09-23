import CryptoKit
import Foundation

public enum DiagnosticFormatter {
    public static func reportSummary(_ report: DailyReport) -> String {
        let accounting = report.accounting
        return [
            "Run: \(report.runID.rawValue.uuidString)",
            "Generated: \(report.generatedAt.formatted(.iso8601))",
            "Domain: \(report.storageDomainID.rawValue)",
            "Event attributed: \(bytes(accounting.eventAttributedDelta))",
            "Reconciliation correction: \(bytes(accounting.reconciliationCorrection))",
            "Physical used: \(optionalBytes(accounting.physicalUsedDelta))",
            "Physical unattributed: \(optionalBytes(accounting.physicalUnattributedDelta))",
            "Indexed objects: \(report.coverage.indexedObjectCount)",
            "Unreadable paths: \(report.coverage.unreadablePathCount)",
        ].joined(separator: "\n")
    }

    public static func redactedPath(_ path: RelativePath) -> String {
        "sha256:" + SHA256.hash(data: path.bytes).map { String(format: "%02x", $0) }.joined()
    }

    public static func bytes(_ value: Int64) -> String {
        let sign = value > 0 ? "+" : ""
        return sign + ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    public static func optionalBytes(_ value: Int64?) -> String {
        value.map(bytes) ?? "unknown"
    }
}
