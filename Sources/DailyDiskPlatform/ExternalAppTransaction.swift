import Darwin
import Foundation

/// File replacement belongs entirely to this process. Homebrew manages only its
/// own receipt/staging files and must not declare an additional `app` artifact.
/// All filesystem mutations are synchronous Foundation/POSIX calls, never child
/// processes that could survive the lease holder.
struct ExternalAppTransaction: Sendable {
    enum Boundary: Sendable { case copied, oldMoved, installed }
    enum Outcome: Equatable { case installed, preservedNewer, removed }

    let control: RunControlStore
    let directory: URL
    let candidate: URL
    let validate: @Sendable (URL) throws -> Int
    let requireIdle: @Sendable () throws -> Void
    var boundary: @Sendable (Boundary) throws -> Void = { _ in }

    private var target: URL { directory.appendingPathComponent("DailyDisk.app") }

    func run(removing: Bool) async throws -> Outcome {
        let installation = try await control.acquireInstallationLease(installationDirectory: directory)
        defer { installation.release() }
        let candidateBuild = try validate(candidate)
        if let pending = try await control.updatePreparation(), pending.requiresExternalInstallationResolution {
            try requireIdle()
            let work = try await control.acquireExternalRecoveryLease(id: pending.id)
            defer { withExtendedLifetime(work) {} }
            try recoverFiles(pending)
            try await control.resolveExternalInstallation(
                id: pending.id, removed: pending.externalOperation == .uninstall)
        }
        let sourceBuild = try exists(target) ? validate(target) : nil
        if !removing, let sourceBuild, sourceBuild >= candidateBuild { return .preservedNewer }
        if removing, sourceBuild == nil {
            try requireIdle()
            if let state = try await control.updatePreparation() {
                guard state.phase == .ready else { throw UpdatePreparationError.invalidState }
                try await control.setUpdatePhase(id: state.id, phase: .restoring)
                try await control.finishUpdateRestoration(id: state.id)
            }
            return .removed
        }
        try requireIdle()
        var state = try await control.updatePreparation()
        if state == nil {
            // Existing installations must explicitly prepare and remember their
            // task preference in the installed GUI before it is closed.
            guard sourceBuild == nil else { throw UpdatePreparationError.invalidState }
            let fresh = try await control.beginUpdatePreparation(restoreDailyTask: false)
            try await control.setUpdatePhase(id: fresh.id, phase: .ready)
            state = try await control.updatePreparation()
        }
        guard let state, state.phase == .ready else { throw UpdatePreparationError.invalidState }
        let intent = try ExternalInstallationIntent(
            operation: removing ? .uninstall : (sourceBuild == nil ? .install : .upgrade),
            sourceBuild: sourceBuild.map(String.init), targetBuild: removing ? nil : String(candidateBuild))
        let work = try await control.armExternalInstallation(id: state.id, intent: intent)
        defer { withExtendedLifetime(work) {} }
        guard let armed = try await control.updatePreparation() else { throw UpdatePreparationError.invalidState }
        do {
            try replaceFiles(armed)
            try await control.resolveExternalInstallation(id: state.id, removed: removing)
        } catch {
            // Do not guess that failed copying, cleanup or a killed transaction
            // succeeded. Preserve the durable gate; a retry checks the signed
            // filesystem under both leases before finishing or rolling back.
            try? await control.markExternalInstallationInterrupted(id: state.id)
            throw error
        }
        return removing ? .removed : .installed
    }

    private func workspace(_ state: UpdatePreparation) -> URL {
        directory.appendingPathComponent(".DailyDisk-homebrew-\(state.id.uuidString)", isDirectory: true)
    }

    private func replaceFiles(_ state: UpdatePreparation) throws {
        let files = FileManager.default
        let root = workspace(state)
        guard try !exists(root) else { throw UpdatePreparationError.invalidState }
        try files.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let staged = root.appendingPathComponent("new.app")
        let previous = root.appendingPathComponent("previous.app")
        if state.externalOperation != .uninstall {
            try files.copyItem(at: candidate, to: staged)
            guard try validate(staged) == Int(state.targetBuild ?? "") else {
                throw UpdatePreparationError.invalidState
            }
            try boundary(.copied)
        }
        try requireIdle()
        if try exists(target) {
            guard try validate(target) == Int(state.sourceBuild ?? "") else {
                throw UpdatePreparationError.invalidState
            }
            try files.moveItem(at: target, to: previous)
            try syncDirectory()
            try boundary(.oldMoved)
        }
        if state.externalOperation != .uninstall {
            try files.moveItem(at: staged, to: target)
            try syncDirectory()
            guard try validate(target) == Int(state.targetBuild ?? "") else {
                throw UpdatePreparationError.invalidState
            }
            try boundary(.installed)
        }
        try files.removeItem(at: root)
        try syncDirectory()
    }

    private func recoverFiles(_ state: UpdatePreparation) throws {
        let files = FileManager.default
        let root = workspace(state)
        let hasWorkspace = try exists(root)
        if hasWorkspace {
            var info = stat()
            guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                info.st_uid == getuid(), info.st_mode & 0o077 == 0
            else { throw RunControlStoreError.unsafeControlFile }
        }
        let previous = root.appendingPathComponent("previous.app")
        if state.externalOperation == .uninstall {
            // An interrupted uninstall is completed only on explicit brew retry.
            if try exists(target) {
                guard try validate(target) == Int(state.sourceBuild ?? "") else {
                    throw UpdatePreparationError.invalidState
                }
                guard try !exists(previous) else { throw UpdatePreparationError.invalidState }
                if !hasWorkspace {
                    try files.createDirectory(
                        at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                }
                try files.moveItem(at: target, to: previous)
                try syncDirectory()
            }
        } else if try exists(target) {
            let build = try validate(target)
            guard build == Int(state.sourceBuild ?? "") || build == Int(state.targetBuild ?? "") else {
                throw UpdatePreparationError.invalidState
            }
        } else if try exists(previous) {
            guard try validate(previous) == Int(state.sourceBuild ?? "") else {
                throw UpdatePreparationError.invalidState
            }
            try files.moveItem(at: previous, to: target)
            try syncDirectory()
        } else {
            // First installation may have died before the atomic rename. An
            // upgrade with neither signed copy is not automatically recoverable.
            guard state.externalOperation == .install else { throw UpdatePreparationError.invalidState }
        }
        if try exists(root) { try files.removeItem(at: root) }
        try syncDirectory()
    }

    private func exists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT != S_IFLNK else { throw RunControlStoreError.unsafeControlFile }
            return true
        }
        guard errno == ENOENT else { throw RunControlStoreError.posix(code: errno) }
        return false
    }

    private func syncDirectory() throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RunControlStoreError.posix(code: errno) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw RunControlStoreError.posix(code: errno) }
    }
}
