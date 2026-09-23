import AppKit
import DailyDiskCore
import Foundation
@preconcurrency import UserNotifications

public enum NotificationAuthorizationState: String, Codable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
    case unknown
}

public protocol NotificationAuthorizationManaging: Sendable {
    func authorizationState() async -> NotificationAuthorizationState
    func requestAuthorization() async throws -> Bool
}

public actor NotificationManager: NotificationSending, NotificationAuthorizationManaging {
    private var center: UNUserNotificationCenter?

    public init(center: UNUserNotificationCenter? = nil) {
        self.center = center
    }

    public func authorizationState() async -> NotificationAuthorizationState {
        guard let center = try? availableCenter() else { return .unknown }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .ephemeral: return .ephemeral
        @unknown default: return .unknown
        }
    }

    public func requestAuthorization() async throws -> Bool {
        try await availableCenter().requestAuthorization(options: [.alert, .sound])
    }

    private func availableCenter() throws -> UNUserNotificationCenter {
        if let center { return center }
        // Bare helpers/test executables can trigger an Objective-C assertion in
        // current(), which Swift error handling cannot catch.
        guard Bundle.main.bundleURL.pathExtension == "app",
            Bundle.main.bundleIdentifier != nil
        else { throw NotificationManagerError.unsupportedProcess }
        let value = UNUserNotificationCenter.current()
        center = value
        return value
    }

    @MainActor
    public static func openSystemSettings() {
        let bundleID = Bundle.main.bundleIdentifier ?? "io.github.xiuyuwu.DailyDisk"
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for value in candidates {
            if let url = URL(string: value), NSWorkspace.shared.open(url) { return }
        }
    }

    public func send(_ message: NotificationMessage) async throws {
        let center = try availableCenter()
        let state = await authorizationState()
        guard state == .authorized || state == .provisional else {
            throw NotificationManagerError.notAuthorized(state)
        }
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        content.sound = .default
        content.userInfo = [
            "severity": message.severity.rawValue,
            "source": "DailyDisk",
        ]
        let request = UNNotificationRequest(
            identifier: message.identifier,
            content: content,
            trigger: nil
        )
        try await center.add(request)
    }
}

public enum NotificationManagerError: Error, Equatable, Sendable {
    case notAuthorized(NotificationAuthorizationState)
    case unsupportedProcess
}
