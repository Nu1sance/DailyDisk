import AppKit
import Combine
import DailyDiskCore
import Foundation
import SwiftUI
@preconcurrency import UserNotifications

@MainActor
final class NotificationNavigation: ObservableObject {
    static let shared = NotificationNavigation()
    @Published var reportID: UUID?
    var openMainWindow: (() -> Void)?
    weak var mainWindow: NSWindow?

    func showReport(_ id: UUID) {
        reportID = id
        if let mainWindow, mainWindow.isVisible {
            if mainWindow.isMiniaturized { mainWindow.deminiaturize(nil) }
            mainWindow.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    nonisolated static func reportID(identifier: String, source: String?, value: String?) -> UUID? {
        guard source == "DailyDisk", let value, let id = UUID(uuidString: value),
            identifier == CompletionNotification.identifier(runID: id)
        else { return nil }
        return id
    }
}

/// Installed only in the interactive GUI, never in the headless delivery/Cask modes.
@MainActor
final class DailyDiskNotificationDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound, .badge])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
            let id = NotificationNavigation.reportID(
                identifier: response.notification.request.identifier,
                source: response.notification.request.content.userInfo["source"] as? String,
                value: response.notification.request.content.userInfo["reportRunID"] as? String)
        else {
            completionHandler()
            return
        }
        Task { @MainActor in
            NotificationNavigation.shared.showReport(id)
        }
        completionHandler()
    }
}

struct NotificationWindowCapture: NSViewRepresentable {
    func makeNSView(context: Context) -> CaptureView { CaptureView() }
    func updateNSView(_ view: CaptureView, context: Context) {}
    final class CaptureView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { NotificationNavigation.shared.mainWindow = window }
        }
    }
}
