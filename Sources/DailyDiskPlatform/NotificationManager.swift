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
    func setBadgeCount(_ count: Int) async throws
    func removeReportNotification(_ id: UUID) async throws
    func sendTestNotification(sound: Bool) async throws
}

extension NotificationAuthorizationManaging {
    public func setBadgeCount(_ count: Int) async throws {}
    public func removeReportNotification(_ id: UUID) async throws {}
    public func sendTestNotification(sound: Bool) async throws { throw NotificationManagerError.unsupportedProcess }
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
        try await availableCenter().requestAuthorization(options: [.alert, .sound, .badge])
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

    public func sendTestNotification(sound: Bool) async throws {
        try await send(
            NotificationMessage(
                identifier: "dailydisk.notification-test", title: "DailyDisk 测试通知",
                body: "通知已就绪。检查完成后，将在这里显示磁盘变化摘要。", severity: .information, playsSound: sound))
    }

    public func setBadgeCount(_ count: Int) async throws {
        guard (0...CompletionNotificationState.capacity).contains(count) else {
            throw NotificationDeliveryError.invalidPayload
        }
        try await availableCenter().setBadgeCount(count)
    }

    public func removeReportNotification(_ id: UUID) throws {
        let identifier = CompletionNotification.identifier(runID: id)
        try availableCenter().removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    public func send(_ message: NotificationMessage) async throws {
        let center = try availableCenter()
        let state = await authorizationState()
        guard state == .authorized || state == .provisional else {
            throw NotificationManagerError.notAuthorized(state)
        }
        if message.badgeOnly == true {
            if let badge = message.badgeCount { try await setBadgeCount(badge) }
            return
        }
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        content.sound = (message.playsSound ?? true) ? .default : nil
        if let badge = message.badgeCount { content.badge = NSNumber(value: badge) }
        content.userInfo = [
            "severity": message.severity.rawValue,
            "source": "DailyDisk",
        ]
        if let id = message.reportRunID { content.userInfo["reportRunID"] = id.uuidString }
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
