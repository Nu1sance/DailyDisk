import DailyDiskCore
import Foundation

/// Notifications use the enclosing app's identity in a short-lived, windowless
/// process. A notification framework abort cannot terminate the scan writer.
public struct AppProcessNotificationSender: NotificationSending {
    private let runner: any ProcessRunning
    private let helperURL: URL?

    public init(
        runner: any ProcessRunning = SystemProcessRunner(),
        helperURL: URL? = Bundle.main.executableURL
    ) {
        self.runner = runner
        self.helperURL = helperURL
    }

    public func send(_ message: NotificationMessage) async throws {
        guard let helperURL,
            helperURL.lastPathComponent == "DailyDiskAgent",
            helperURL.deletingLastPathComponent().lastPathComponent == "Helpers"
        else { throw NotificationDeliveryError.invalidBundle }
        let contents = helperURL.deletingLastPathComponent().deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents",
            contents.deletingLastPathComponent().pathExtension == "app"
        else { throw NotificationDeliveryError.invalidBundle }
        let executable = contents.appendingPathComponent("MacOS/DailyDisk")
        let payload = try NotificationDelivery.encode(message)
        let result = try await runner.run(
            ProcessRequest(
                executableURL: executable,
                arguments: [NotificationDelivery.command, payload],
                timeoutSeconds: 15
            )
        )
        guard result.terminationStatus == 0 else {
            throw NotificationDeliveryError.deliveryFailed(result.terminationStatus)
        }
    }
}

public enum NotificationDeliveryError: Error, Equatable, Sendable {
    case invalidBundle
    case invalidPayload
    case deliveryFailed(Int32)
}

public enum NotificationDelivery {
    public static let command = "--deliver-notification"
    public static let statusCommand = "--notification-status"
    private static let maximumPayloadBytes = 16_384

    public static func encode(_ message: NotificationMessage) throws -> String {
        let data = try JSONEncoder().encode(message)
        guard data.count <= maximumPayloadBytes else { throw NotificationDeliveryError.invalidPayload }
        return data.base64EncodedString()
    }

    public static func decode(arguments: [String]) throws -> NotificationMessage {
        guard arguments.count == 2, arguments[0] == command,
            arguments[1].utf8.count <= maximumPayloadBytes * 2,
            let data = Data(base64Encoded: arguments[1]), data.count <= maximumPayloadBytes
        else { throw NotificationDeliveryError.invalidPayload }
        let message = try JSONDecoder().decode(NotificationMessage.self, from: data)
        guard message.badgeCount.map({ (0...CompletionNotificationState.capacity).contains($0) }) ?? true else {
            throw NotificationDeliveryError.invalidPayload
        }
        return message
    }

    /// Never requests permission or opens a window. Permission belongs to GUI setup.
    public static func run(arguments: [String]) async -> Int32 {
        if arguments == [statusCommand] {
            print(await NotificationManager().authorizationState().rawValue)
            return 0
        }
        do {
            var message = try decode(arguments: arguments)
            if message.reportRunID != nil {
                // Read the badge as late as possible, after any concurrent GUI acknowledgement.
                let state = try await RunControlStore().notificationState()
                message = NotificationMessage(
                    identifier: message.identifier, title: message.title,
                    body: message.body, severity: message.severity, playsSound: state.sound,
                    badgeCount: state.badgeCount, reportRunID: message.reportRunID, badgeOnly: !state.enabled)
            }
            let manager = NotificationManager()
            try await manager.send(message)
            if message.reportRunID != nil {
                let state = try await RunControlStore().notificationState()
                try await manager.setBadgeCount(state.badgeCount)
            }
            return 0
        } catch NotificationManagerError.notAuthorized {
            return 77
        } catch {
            return 1
        }
    }
}
