import Darwin
import Foundation

public struct RetentionPolicy: Sendable {
    public let logRetention: TimeInterval
    public let reportRetention: TimeInterval

    public init(
        logRetention: TimeInterval = 30 * 24 * 60 * 60,
        reportRetention: TimeInterval = 400 * 24 * 60 * 60
    ) throws {
        guard logRetention.isFinite, logRetention >= 0,
            reportRetention.isFinite, reportRetention >= 0
        else {
            throw RetentionPolicyError.invalidInterval
        }
        self.logRetention = logRetention
        self.reportRetention = reportRetention
    }

    public static let `default` = try! RetentionPolicy()

    @discardableResult
    public func prune(
        managedRoot: URL,
        now: Date = Date()
    ) throws -> [URL] {
        guard managedRoot.lastPathComponent == "DailyDisk" else {
            throw RetentionPolicyError.unmanagedRoot
        }
        let root = managedRoot.standardizedFileURL
        try validateDirectoryIfPresent(root)
        let logs = root.appendingPathComponent("Logs", isDirectory: true)
        let reports = root.appendingPathComponent("Reports", isDirectory: true)
        try validateDirectoryIfPresent(logs)
        try validateDirectoryIfPresent(reports)

        var removed = try pruneLogs(
            directory: logs,
            cutoff: now.addingTimeInterval(-logRetention)
        )
        removed += try pruneReportDirectories(
            directory: reports,
            cutoff: now.addingTimeInterval(-reportRetention)
        )
        return removed
    }

    private func pruneLogs(directory: URL, cutoff: Date) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        var removed: [URL] = []
        for file in files {
            let name = file.lastPathComponent
            guard
                name == "operations.jsonl"
                    || (name.hasPrefix("operations.") && name.hasSuffix(".jsonl"))
            else { continue }
            let values = try file.resourceValues(forKeys: [
                .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true,
                values.isSymbolicLink != true,
                let modified = values.contentModificationDate,
                modified < cutoff
            else { continue }
            guard unlink(file.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            removed.append(file)
        }
        return removed
    }

    private func pruneReportDirectories(directory: URL, cutoff: Date) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var removed: [URL] = []
        for entry in entries {
            guard UUID(uuidString: entry.lastPathComponent) != nil else { continue }
            let values = try entry.resourceValues(forKeys: [
                .contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey,
            ])
            guard values.isDirectory == true,
                values.isSymbolicLink != true,
                let modified = values.contentModificationDate,
                modified < cutoff
            else { continue }
            let children = try FileManager.default.contentsOfDirectory(
                at: entry,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            guard
                children.allSatisfy({
                    ["report.json", "report.md"].contains($0.lastPathComponent)
                })
            else { continue }
            for child in children {
                let childValues = try child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard childValues.isRegularFile == true, childValues.isSymbolicLink != true else {
                    throw RetentionPolicyError.unsafeOwnedEntry
                }
                guard unlink(child.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            guard rmdir(entry.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            removed.append(entry)
        }
        return removed
    }

    private func validateDirectoryIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw RetentionPolicyError.unsafeOwnedEntry
        }
    }
}

public enum RetentionPolicyError: Error, Equatable, Sendable {
    case invalidInterval
    case unmanagedRoot
    case unsafeOwnedEntry
}
