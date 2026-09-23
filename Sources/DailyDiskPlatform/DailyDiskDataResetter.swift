import DailyDiskStore
import Darwin
import Foundation

public struct DailyDiskDataResetter: Sendable {
    public static var defaultDataRootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DailyDisk", isDirectory: true)
            .standardizedFileURL
    }

    public let dataRootURL: URL
    private let permitsTestRoot: Bool

    public init() {
        dataRootURL = Self.defaultDataRootURL
        permitsTestRoot = false
    }

    init(testDataRootURL: URL) {
        dataRootURL = testDataRootURL.standardizedFileURL
        permitsTestRoot = true
    }

    public func reset(holding lease: DatabaseResetLease) throws {
        _ = lease
        let root = dataRootURL.standardizedFileURL
        guard root.lastPathComponent == "DailyDisk",
            permitsTestRoot || root == Self.defaultDataRootURL
        else {
            throw DailyDiskDataResetError.untrustedRoot
        }
        let parent = root.deletingLastPathComponent()
        try cleanupOldTombstones(in: parent)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try validateOwnedDirectory(root)

        let tombstone = parent.appendingPathComponent(
            ".DailyDisk.Reset.\(UUID().uuidString)",
            isDirectory: true
        )
        guard rename(root.path, tombstone.path) == 0 else {
            throw DailyDiskDataResetError.posix(errno)
        }
        var replacementCreated = false
        var controlMoved = false
        var deletionStarted = false
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            replacementCreated = true
            guard chmod(root.path, S_IRWXU) == 0 else {
                throw DailyDiskDataResetError.posix(errno)
            }
            let oldControl = tombstone.appendingPathComponent("Control", isDirectory: true)
            if FileManager.default.fileExists(atPath: oldControl.path) {
                try validateOwnedDirectory(oldControl)
                let newControl = root.appendingPathComponent("Control", isDirectory: true)
                guard rename(oldControl.path, newControl.path) == 0 else {
                    throw DailyDiskDataResetError.posix(errno)
                }
                controlMoved = true
            }
            deletionStarted = true
            try FileManager.default.removeItem(at: tombstone)
        } catch {
            // Before recursive deletion begins, restore the exact original tree
            // if replacement setup fails. Once deletion starts, never rename a
            // potentially partial tombstone back into service; it remains
            // private and is removed first on the next reset.
            if !deletionStarted, FileManager.default.fileExists(atPath: tombstone.path) {
                if controlMoved {
                    let newControl = root.appendingPathComponent("Control", isDirectory: true)
                    let oldControl = tombstone.appendingPathComponent("Control", isDirectory: true)
                    _ = rename(newControl.path, oldControl.path)
                }
                if replacementCreated { try? FileManager.default.removeItem(at: root) }
                _ = rename(tombstone.path, root.path)
            }
            throw error is DailyDiskDataResetError
                ? error : DailyDiskDataResetError.cleanupFailed
        }
    }

    private func cleanupOldTombstones(in parent: URL) throws {
        let values = try FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil,
            options: []
        )
        for value in values where value.lastPathComponent.hasPrefix(".DailyDisk.Reset.") {
            try validateOwnedDirectory(value)
            try FileManager.default.removeItem(at: value)
        }
    }

    private func validateOwnedDirectory(_ url: URL) throws {
        var status = Darwin.stat()
        guard lstat(url.path, &status) == 0,
            status.st_uid == getuid(),
            status.st_mode & S_IFMT == S_IFDIR,
            status.st_mode & 0o077 == 0
        else {
            throw DailyDiskDataResetError.unsafeRoot
        }
    }
}

public enum DailyDiskDataResetError: Error, Equatable, Sendable {
    case untrustedRoot
    case unsafeRoot
    case cleanupFailed
    case posix(Int32)
}
