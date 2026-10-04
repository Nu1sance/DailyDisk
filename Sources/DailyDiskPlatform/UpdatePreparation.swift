import Darwin
import Foundation

public struct UpdatePreparation: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case preparing, ready, restoring }
    public let version: Int
    public let id: UUID
    public let restoreDailyTask: Bool
    public var phase: Phase

    init(restoreDailyTask: Bool) {
        version = 1
        id = UUID()
        self.restoreDailyTask = restoreDailyTask
        phase = .preparing
    }
}

public enum UpdatePreparationError: Error, Equatable {
    case busy
    case installationInProgress
    case unsupportedRegistration
    case invalidState
}

/// Separate open file descriptions make flock effective across actors and processes.
/// The helper holds a shared lease for its entire invocation, including pre-writer work.
public final class UpdateWorkLease: @unchecked Sendable {
    private let descriptor: Int32
    init(url: URL, exclusive: Bool) throws {
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RunControlStoreError.posix(code: errno) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
            info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0
        else {
            close(fd)
            throw RunControlStoreError.unsafeControlFile
        }
        guard flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { throw UpdatePreparationError.busy }
            throw RunControlStoreError.posix(code: code)
        }
        descriptor = fd
    }
    deinit { close(descriptor) }
}

/// Shares the installer's atomic directory lock. A crashed installer leaves the
/// lock for explicit inspection; never expire it on a timer while replacement may run.
final class AppInstallationLease {
    private let url: URL
    init(directory: URL) throws {
        let candidate = directory.appendingPathComponent(".DailyDisk-install.lock")
        guard mkdir(candidate.path, 0o700) == 0 else {
            if errno == EEXIST { throw UpdatePreparationError.installationInProgress }
            throw RunControlStoreError.posix(code: errno)
        }
        url = candidate
    }
    deinit { rmdir(url.path) }
}
