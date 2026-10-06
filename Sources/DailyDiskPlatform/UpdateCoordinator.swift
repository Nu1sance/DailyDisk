import DailyDiskCore
import DailyDiskStore
import Foundation

public protocol UpdateTaskManaging: Sendable {
    func status() async -> LaunchAgentStatus
    func register() async throws
    func unregister() async throws
    func runtimeStatus() async throws -> LaunchAgentRuntimeStatus
}

extension LaunchAgentManager: UpdateTaskManaging {}

/// Preparation is explicit and fail-closed. A persisted marker is never cleared
/// merely because the GUI restarted or a timeout elapsed.
public actor UpdateCoordinator {
    private let control: RunControlStore
    private let manager: any UpdateTaskManaging
    private let installationDirectory: URL
    private let writerIsActive: @Sendable () -> Bool
    private let currentBuild: String
    private let checkSessions: @Sendable () throws -> Void
    private var operating = false

    public init(
        control: RunControlStore, manager: any UpdateTaskManaging,
        installationDirectory: URL = Bundle.main.bundleURL.deletingLastPathComponent(),
        currentBuild: String = DailyDiskProduct.installedBuildNumber,
        checkSessions: @escaping @Sendable () throws -> Void = { try UpdateSessionGuard.requireSingleUser() },
        writerIsActive: @escaping @Sendable () -> Bool = { SQLiteReportStore.writerIsActive() }
    ) {
        self.currentBuild = currentBuild
        self.checkSessions = checkSessions
        self.control = control
        self.manager = manager
        self.installationDirectory = installationDirectory
        self.writerIsActive = writerIsActive
    }

    public func prepare() async throws {
        guard !operating else { throw UpdatePreparationError.busy }
        operating = true
        defer { operating = false }
        try checkSessions()
        let installation = try await control.acquireInstallationLease(installationDirectory: installationDirectory)
        defer { installation.release() }
        guard !writerIsActive(), try await !manager.runtimeStatus().isRunning else {
            throw UpdatePreparationError.busy
        }
        let status = await manager.status()
        guard status == .enabled || status == .notRegistered else {
            throw UpdatePreparationError.unsupportedRegistration
        }
        let state = try await control.beginUpdatePreparation(restoreDailyTask: status == .enabled)
        // Marker is already durable before unregister. A failure remains recoverable
        // even if unregister took effect before throwing or the GUI died here.
        if status == .enabled { try await manager.unregister() }
        guard await manager.status() == .notRegistered,
            try await !manager.runtimeStatus().isRunning, !writerIsActive()
        else { throw UpdatePreparationError.busy }
        try await control.setUpdatePhase(id: state.id, phase: .ready)
    }

    public func hasPendingSparkleInstallation() async throws -> Bool {
        try await control.updatePreparation()?.phase == .sparkleInstalling
    }

    public func prepareSparkleInstallation(targetBuild: String) async throws -> UUID {
        try checkSessions()
        guard let source = Int(currentBuild), let target = Int(targetBuild),
            source > 0, target > source, target <= 999_999_999, String(target) == targetBuild
        else { throw UpdatePreparationError.invalidState }
        if try await control.updatePreparation()?.requiresExternalInstallationResolution == true {
            throw UpdatePreparationError.externalInstallationUnresolved
        }
        if let state = try await control.updatePreparation(), state.phase == .sparkleInstalling {
            guard state.sourceBuild == currentBuild, state.targetBuild == targetBuild else {
                throw UpdatePreparationError.invalidState
            }
            return state.id
        }
        if try await control.updatePreparation() == nil { try await prepare() }
        guard !operating else { throw UpdatePreparationError.busy }
        operating = true
        defer { operating = false }
        try checkSessions()
        let installation = try await control.acquireInstallationLease(installationDirectory: installationDirectory)
        defer { installation.release() }
        guard let state = try await control.updatePreparation(), state.phase == .ready,
            await manager.status() == .notRegistered, try await !manager.runtimeStatus().isRunning,
            !writerIsActive()
        else { throw UpdatePreparationError.busy }
        try await control.armSparkleInstallation(id: state.id, sourceBuild: currentBuild, targetBuild: targetBuild)
        return state.id
    }

    /// Admission-only test seam. The native installer instead retains its leases
    /// across mutation and resolution through ExternalAppTransaction.
    func beginExternalInstallation(intent: ExternalInstallationIntent) async throws -> UUID {
        guard !operating else { throw UpdatePreparationError.busy }
        operating = true
        defer { operating = false }
        try checkSessions()
        let installation = try await control.acquireInstallationLease(installationDirectory: installationDirectory)
        defer { installation.release() }
        guard !writerIsActive(), try await !manager.runtimeStatus().isRunning else {
            throw UpdatePreparationError.busy
        }
        guard await manager.status() == .notRegistered else {
            throw UpdatePreparationError.unsupportedRegistration
        }
        guard let state = try await control.updatePreparation(), state.phase == .ready else {
            throw UpdatePreparationError.invalidState
        }
        try await control.armExternalInstallation(id: state.id, intent: intent)
        return state.id
    }

    public func cancelSparkleDownload(id: UUID) async throws {
        guard !operating else { throw UpdatePreparationError.busy }
        try await control.cancelSparkleDownload(id: id)
        try await restore()
    }

    /// Sparkle restoration requires the expected new build. The shell installer shares
    /// the private installation lock, so restoration cannot race package replacement.
    public func restore() async throws {
        guard !operating else { throw UpdatePreparationError.busy }
        operating = true
        defer { operating = false }
        try checkSessions()
        let installation = try await control.acquireInstallationLease(installationDirectory: installationDirectory)
        defer { installation.release() }
        guard let state = try await control.updatePreparation() else { return }
        guard !state.requiresExternalInstallationResolution else {
            throw UpdatePreparationError.externalInstallationUnresolved
        }
        if state.phase == .sparkleInstalling {
            guard state.targetBuild == currentBuild, state.sourceBuild != currentBuild else {
                throw UpdatePreparationError.installationInProgress
            }
        }
        guard !writerIsActive(), try await !manager.runtimeStatus().isRunning else {
            throw UpdatePreparationError.busy
        }
        try await control.setUpdatePhase(id: state.id, phase: .restoring)
        if state.restoreDailyTask {
            let status = await manager.status()
            if status == .notRegistered { try await manager.register() }
            let restored = await manager.status()
            guard restored == .enabled || restored == .requiresApproval else {
                throw UpdatePreparationError.unsupportedRegistration
            }
        }
        try await control.finishUpdateRestoration(id: state.id)
    }
}
