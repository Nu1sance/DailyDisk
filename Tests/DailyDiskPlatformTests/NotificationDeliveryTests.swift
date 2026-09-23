import DailyDiskCore
import Foundation
import Testing

@testable import DailyDiskPlatform

private actor NotificationProcessProbe: ProcessRunning {
    private(set) var request: ProcessRequest?
    let status: Int32
    init(status: Int32 = 0) { self.status = status }
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        self.request = request
        return ProcessResult(terminationStatus: status, standardOutput: Data(), standardError: Data())
    }
}

private let deliveryMessage = NotificationMessage(
    identifier: "dailydisk.test", title: "磁盘变化", body: "空间增加 128 MB", severity: .information
)

@Test("Scheduled notifications use the app executable and a bounded child process")
func notificationUsesAppIdentity() async throws {
    let probe = NotificationProcessProbe()
    try await AppProcessNotificationSender(
        runner: probe, helperURL: URL(fileURLWithPath: "/Applications/DailyDisk.app/Contents/Helpers/DailyDiskAgent")
    ).send(deliveryMessage)
    let request = try #require(await probe.request)
    #expect(request.executableURL.path == "/Applications/DailyDisk.app/Contents/MacOS/DailyDisk")
    #expect(request.timeoutSeconds == 15)
    #expect(try NotificationDelivery.decode(arguments: request.arguments) == deliveryMessage)
}

@Test("A notification child crash becomes a recoverable delivery error")
func notificationChildCrashIsIsolated() async throws {
    let sender = AppProcessNotificationSender(
        runner: NotificationProcessProbe(status: 6),
        helperURL: URL(fileURLWithPath: "/Applications/DailyDisk.app/Contents/Helpers/DailyDiskAgent")
    )
    await #expect(throws: NotificationDeliveryError.deliveryFailed(6)) {
        try await sender.send(deliveryMessage)
    }
}

@Test("Notification delivery rejects invalid payloads and unbundled helpers")
func notificationInputValidation() async throws {
    #expect(throws: (any Error).self) {
        try NotificationDelivery.decode(arguments: [NotificationDelivery.command, "invalid"])
    }
    #expect(throws: (any Error).self) { try NotificationDelivery.decode(arguments: [NotificationDelivery.command]) }
    let tooLarge = NotificationMessage(
        identifier: "test", title: "test", body: String(repeating: "x", count: 20_000), severity: .information)
    #expect(throws: NotificationDeliveryError.invalidPayload) { try NotificationDelivery.encode(tooLarge) }
    await #expect(throws: NotificationDeliveryError.invalidBundle) {
        try await AppProcessNotificationSender(helperURL: URL(fileURLWithPath: "/tmp/DailyDiskAgent")).send(
            deliveryMessage)
    }
}

@Test("Unbundled notification access returns an error instead of a framework assertion")
func unbundledNotificationIsSafe() async throws {
    guard Bundle.main.bundleURL.pathExtension != "app" else { return }
    let manager = NotificationManager()
    #expect(await manager.authorizationState() == .unknown)
    await #expect(throws: NotificationManagerError.unsupportedProcess) { try await manager.send(deliveryMessage) }
}
