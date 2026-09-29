import AppKit
import DailyDiskCore
import Darwin
import Foundation
import ServiceManagement

public enum LaunchAgentStatus: String, Codable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown
}

public struct LaunchAgentRuntimeStatus: Codable, Equatable, Sendable {
    public let isRunning: Bool
    public let processID: Int32?
    public let lastExitCode: Int32?
    public let state: String?

    public init(
        isRunning: Bool,
        processID: Int32?,
        lastExitCode: Int32?,
        state: String?
    ) {
        self.isRunning = isRunning
        self.processID = processID
        self.lastExitCode = lastExitCode
        self.state = state
    }
}

public protocol ProcessSignaling: Sendable {
    func terminate(processID: Int32) throws
}

public struct SystemProcessSignaler: ProcessSignaling {
    public init() {}

    public func terminate(processID: Int32) throws {
        guard processID > 0 else {
            throw LaunchAgentManagerError.signalFailed(EINVAL)
        }
        guard kill(processID, SIGTERM) == 0 else {
            throw LaunchAgentManagerError.signalFailed(errno)
        }
    }
}

public enum LaunchAgentStartResult: Equatable, Sendable {
    case started
    case alreadyRunning(LaunchAgentRuntimeStatus)
}

public protocol LaunchAgentRegistrationServicing: Sendable {
    func status() -> LaunchAgentStatus
    func register() throws
    func unregister() throws
}

private final class SystemLaunchAgentRegistrationService: LaunchAgentRegistrationServicing,
    @unchecked Sendable
{
    private let service: SMAppService

    init(plistName: String) {
        service = SMAppService.agent(plistName: plistName)
    }

    func status() -> LaunchAgentStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unknown
        }
    }

    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
}

public actor LaunchAgentManager {
    public static let plistName = "io.github.xiuyuwu.DailyDisk.agent.plist"
    public static let label = "io.github.xiuyuwu.DailyDisk.agent"

    private let service: any LaunchAgentRegistrationServicing
    private let bundleURL: URL
    private let processRunner: any ProcessRunning
    private let processSignaler: any ProcessSignaling
    private let userID: uid_t
    private let label: String

    public init(
        plistName: String = LaunchAgentManager.plistName,
        bundleURL: URL = Bundle.main.bundleURL,
        processRunner: any ProcessRunning = SystemProcessRunner(),
        processSignaler: any ProcessSignaling = SystemProcessSignaler(),
        userID: uid_t = getuid(),
        label: String = LaunchAgentManager.label
    ) {
        service = SystemLaunchAgentRegistrationService(plistName: plistName)
        self.bundleURL = bundleURL
        self.processRunner = processRunner
        self.processSignaler = processSignaler
        self.userID = userID
        self.label = label
    }

    public init(
        service: any LaunchAgentRegistrationServicing,
        bundleURL: URL,
        processRunner: any ProcessRunning,
        processSignaler: any ProcessSignaling = SystemProcessSignaler(),
        userID: uid_t,
        label: String = LaunchAgentManager.label
    ) {
        self.service = service
        self.bundleURL = bundleURL
        self.processRunner = processRunner
        self.processSignaler = processSignaler
        self.userID = userID
        self.label = label
    }

    public func status() -> LaunchAgentStatus { service.status() }

    public func register() throws {
        guard Self.isStableInstallationPath(bundleURL) else {
            throw LaunchAgentManagerError.unstableApplicationPath(bundleURL.path)
        }
        try service.register()
    }

    public func unregister() throws { try service.unregister() }

    public func runtimeStatus() async throws -> LaunchAgentRuntimeStatus {
        try await loadedRuntimeStatus()
            ?? LaunchAgentRuntimeStatus(
                isRunning: false, processID: nil, lastExitCode: nil, state: nil
            )
    }

    // A missing job is different from a loaded, idle job. SMAppService may
    // retain enabled registration metadata after the app has been replaced.
    private func loadedRuntimeStatus() async throws -> LaunchAgentRuntimeStatus? {
        let result = try await processRunner.run(
            ProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/launchctl"),
                arguments: ["print", target],
                timeoutSeconds: 5
            )
        )
        if result.terminationStatus != 0 {
            let diagnostic = String(decoding: result.standardError, as: UTF8.self).lowercased()
            guard
                diagnostic.contains("could not find service")
                    || diagnostic.contains("service not found")
            else {
                throw LaunchAgentManagerError.runtimeStatusUnavailable
            }
            return nil
        }
        return Self.parseRuntimeStatus(String(decoding: result.standardOutput, as: UTF8.self))
    }

    public func startIfNeeded(
        controlStore: RunControlStore? = nil
    ) async throws -> LaunchAgentStartResult {
        let registrationStatus = service.status()
        guard registrationStatus == .enabled else {
            throw LaunchAgentManagerError.serviceUnavailable(registrationStatus)
        }
        var loaded = try await loadedRuntimeStatus()
        if loaded == nil {
            // Repair this proven registration/runtime mismatch once per start.
            // Never unregister a merely idle or running job, or loop on failure.
            guard Self.isStableInstallationPath(bundleURL) else {
                throw LaunchAgentManagerError.unstableApplicationPath(bundleURL.path)
            }
            try service.unregister()
            try register()
            let repairedStatus = service.status()
            guard repairedStatus == .enabled else {
                throw LaunchAgentManagerError.serviceUnavailable(repairedStatus)
            }
            loaded = try await loadedRuntimeStatus()
        }
        guard var current = loaded else {
            throw LaunchAgentManagerError.runtimeStatusUnavailable
        }
        if current.isRunning, let currentProcessID = current.processID,
            let controlStore,
            try await controlStore.pendingRequest() != nil,
            try await controlStore.helperIsIdle(processID: currentProcessID)
        {
            // The running helper atomically declared that it found no pending
            // request and is exiting. Wait for that exact shutdown before
            // asking launchd to start the queued request.
            while current.isRunning, current.processID == currentProcessID {
                try await Task.sleep(for: .milliseconds(100))
                current = try await runtimeStatus()
            }
        }
        if current.isRunning { return .alreadyRunning(current) }
        let result = try await processRunner.run(
            ProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/launchctl"),
                arguments: ["kickstart", target],
                timeoutSeconds: 5
            )
        )
        guard result.terminationStatus == 0 else {
            throw LaunchAgentManagerError.launchctlFailed(result.terminationStatus)
        }
        return .started
    }

    public func terminateHelper() async throws {
        let result = try await processRunner.run(
            ProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/launchctl"),
                arguments: ["kill", "SIGTERM", target],
                timeoutSeconds: 5
            )
        )
        guard result.terminationStatus == 0 else {
            throw LaunchAgentManagerError.launchctlFailed(result.terminationStatus)
        }
    }

    public func requestStop(
        requestID: UUID,
        controlStore: RunControlStore,
        fallbackDelay: Duration = .seconds(2)
    ) async throws {
        try await controlStore.requestCancellation(
            DailyDiskCancelRequest(requestID: requestID)
        )
        try await Task.sleep(for: fallbackDelay)
        let runtime = try await runtimeStatus()
        guard runtime.isRunning, let processID = runtime.processID else { return }
        _ = try await controlStore.signalIfRequestIsCancellable(
            requestID: requestID,
            processID: processID,
            signaler: processSignaler
        )
    }

    @MainActor
    public static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    public static func isStableInstallationPath(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.hasPrefix("/Applications/")
            || path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/Applications/")
    }

    public static func parseRuntimeStatus(_ output: String) -> LaunchAgentRuntimeStatus {
        var processID: Int32?
        var lastExitCode: Int32?
        var state: String?
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "pid":
                if let parsed = Int32(parts[1]), parsed > 0 { processID = parsed }
            case "last exit code": lastExitCode = Int32(parts[1])
            case "state": state = parts[1]
            default: break
            }
        }
        return LaunchAgentRuntimeStatus(
            isRunning: processID != nil || state == "running",
            processID: processID,
            lastExitCode: lastExitCode,
            state: state
        )
    }

    private var target: String { "gui/\(userID)/\(label)" }
}

public enum LaunchAgentManagerError: Error, Equatable, Sendable {
    case unstableApplicationPath(String)
    case serviceUnavailable(LaunchAgentStatus)
    case launchctlFailed(Int32)
    case runtimeStatusUnavailable
    case signalFailed(Int32)
}
