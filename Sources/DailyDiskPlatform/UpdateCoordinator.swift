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
    private var operating = false

    public init(
        control: RunControlStore, manager: any UpdateTaskManaging,
        installationDirectory: URL = Bundle.main.bundleURL.deletingLastPathComponent(),
        writerIsActive: @escaping @Sendable () -> Bool = { SQLiteReportStore.writerIsActive() }
    ) {
        self.control = control
        self.manager = manager
        self.installationDirectory = installationDirectory
        self.writerIsActive = writerIsActive
    }

    public func prepare() async throws {
        guard !operating else { throw UpdatePreparationError.busy }
        operating = true
        defer { operating = false }
        let installation = try AppInstallationLease(directory: installationDirectory)
        defer { withExtendedLifetime(installation) {} }
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

    /// Explicit user action in this release. Sparkle will later call this only
    /// after its installation ownership has ended. The shell installer shares
    /// the directory lock, so restoration cannot race package replacement.
    public func restore() async throws {
        guard !operating else { throw UpdatePreparationError.busy }
        operating = true
        defer { operating = false }
        let installation = try AppInstallationLease(directory: installationDirectory)
        defer { withExtendedLifetime(installation) {} }
        guard let state = try await control.updatePreparation() else { return }
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
