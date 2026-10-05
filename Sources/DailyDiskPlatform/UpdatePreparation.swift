import Darwin
import Foundation

public struct UpdatePreparation: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case preparing, ready, restoring, sparkleInstalling
        case externalInstalling, externalRecoveryRequired
    }
    public internal(set) var version: Int
    public let id: UUID
    public let restoreDailyTask: Bool
    public var phase: Phase
    public var sourceBuild: String?
    public var targetBuild: String?
    public internal(set) var externalOperation: ExternalInstallationOperation?

    public var requiresExternalInstallationResolution: Bool {
        phase == .externalInstalling || phase == .externalRecoveryRequired
    }

    func validate() throws {
        if requiresExternalInstallationResolution {
            guard version == 2, let externalOperation else { throw UpdatePreparationError.invalidState }
            _ = try ExternalInstallationIntent(
                operation: externalOperation, sourceBuild: sourceBuild, targetBuild: targetBuild)
        } else {
            guard version == 1, externalOperation == nil else { throw UpdatePreparationError.invalidState }
        }
    }

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
    case otherUserSession
    case externalInstallationUnresolved
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

/// The source installer uses the same private file lock. Never unlink a flock
/// file: another process may still hold its inode. The durable update marker
/// separately spans GUI termination and external Sparkle installation.
final class AppInstallationLease: @unchecked Sendable {
    private var lease: UpdateWorkLease?
    init(controlDirectory: URL, installationDirectory: URL) throws {
        var status = stat()
        let legacy = installationDirectory.appendingPathComponent(".DailyDisk-install.lock")
        if lstat(legacy.path, &status) == 0 {
            throw UpdatePreparationError.installationInProgress
        }
        guard errno == ENOENT else { throw RunControlStoreError.posix(code: errno) }
        do {
            lease = try UpdateWorkLease(
                url: controlDirectory.appendingPathComponent(".installation.lock"), exclusive: true)
        } catch UpdatePreparationError.busy {
            throw UpdatePreparationError.installationInProgress
        }
    }

    // Async call frames can retain this wrapper beyond the operation's return.
    // Release deterministically before allowing the next actor operation.
    func release() { lease = nil }
}

extension UpdatePreparationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .busy: "请等待扫描和报告保存完成后重试。"
        case .installationInProgress: "已有安装正在进行，或旧安装锁尚待检查。请完成该安装后重试。"
        case .unsupportedRegistration: "请先在系统设置中完成每日任务批准，再重试更新。"
        case .invalidState: "更新状态与目标版本不匹配，请完成已开始的更新。"
        case .externalInstallationUnresolved: "外部安装尚未确认结束，扫描与任务恢复保持暂停。请勿删除更新状态文件。"
        case .otherUserSession: "请先退出其他用户的登录会话，再更新 DailyDisk。"
        }
    }
}
