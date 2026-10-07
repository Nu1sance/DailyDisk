import DailyDiskCore
import Foundation
import Testing

@testable import DailyDiskApp

@Test("Only valid report notification identities navigate; paths and test messages cannot")
func notificationNavigationIdentity() {
    let id = UUID()
    #expect(
        NotificationNavigation.reportID(
            identifier: CompletionNotification.identifier(runID: id),
            source: "DailyDisk", value: id.uuidString) == id)
    #expect(
        NotificationNavigation.reportID(
            identifier: "dailydisk.notification-test",
            source: "DailyDisk", value: id.uuidString) == nil)
    #expect(
        NotificationNavigation.reportID(
            identifier: CompletionNotification.identifier(runID: id),
            source: "other", value: id.uuidString) == nil)
    #expect(
        NotificationNavigation.reportID(
            identifier: "dailydisk.report.bad",
            source: "DailyDisk", value: "/private/path") == nil)
}
