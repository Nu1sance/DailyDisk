import DailyDiskCore
import DailyDiskStore
import Foundation
import Testing

@testable import DailyDiskPlatform

@Test("Maintenance requests use persisted progress, seal cancellation, and resume without inventing a scan")
func maintenanceProgressAndCancellation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let control = try RunControlStore(rootURL: root.appendingPathComponent("Control"))
    let request = try DailyDiskRunRequest(action: .reclaimSpace, createdAt: Date(timeIntervalSince1970: 100.75))
    try await control.enqueue(request)
    let claimed = try #require(try await control.claimPendingRequest())
    #expect(claimed.action == .reclaimSpace)
    let tracker = try ScanProgressTracker(
        context: ScanProgressContext(requestID: claimed.requestID, trigger: .manual, startedAt: claimed.createdAt),
        reporter: control, cancellationChecker: control, commitBoundary: control)
    try await tracker.transition(to: .preparing, mode: nil)
    try await tracker.transition(to: .reclaimingSpace, mode: nil)
    #expect(try await control.latestProgress()?.phase == .reclaimingSpace)
    await #expect(throws: (any Error).self) {
        try await control.requestCancellation(DailyDiskCancelRequest(requestID: claimed.requestID))
    }
    let persisted = try #require(try await control.latestProgress())
    let restarted = try ScanProgressTracker(
        resuming: persisted, reporter: control, cancellationChecker: control, commitBoundary: control)
    try await restarted.transition(to: .preparing, mode: nil)
    try await restarted.transition(to: .verifyingMaintenance, mode: nil)
    #expect(try await control.latestProgress()?.counters.visitedPaths == 0)
    #expect(try await control.channelError() == nil)
}

@Test("Manual maintenance completes without launching inventory and reports insufficient space explicitly")
func maintenanceRunnerNoScan() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let control = try RunControlStore(rootURL: root.appendingPathComponent("DailyDisk/Control"))
    let url = root.appendingPathComponent("DailyDisk/DailyDisk.sqlite")
    let request = try DailyDiskRunRequest(action: .reclaimSpace)
    try await control.enqueue(request)
    let claimed = try #require(try await control.claimPendingRequest())
    let result = await SpaceMaintenanceRunner().run(
        request: claimed, resumedProgress: nil, control: control, databaseURL: url, availableBytes: { Int64.max })
    #expect(result == 0)
    #expect(try await control.latestProgress()?.phase == .completed)
    #expect(try await control.activeRequest() == nil)
    let reader = try SQLiteReportStore(databaseURL: url)
    #expect(try await reader.recentRuns().isEmpty)
    #expect(try await reader.spaceUsage().maintenanceStatus == "completed")

    try await control.enqueue(DailyDiskRunRequest(action: .reclaimSpace))
    let second = try #require(try await control.claimPendingRequest())
    let failure = await SpaceMaintenanceRunner().run(
        request: second, resumedProgress: nil, control: control, databaseURL: url, availableBytes: { 0 })
    #expect(failure == 1)
    #expect(try await control.latestSummary()?.errorCategory == .insufficientSpace)
    #expect(try await reader.verify().isHealthy)
}

@Test("A restarted manual maintenance verifies the database and requests an explicit retry")
func maintenanceRunnerRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let control = try RunControlStore(rootURL: root.appendingPathComponent("DailyDisk/Control"))
    let url = root.appendingPathComponent("DailyDisk/DailyDisk.sqlite")
    let request = try DailyDiskRunRequest(action: .reclaimSpace)
    try await control.enqueue(request)
    let claimed = try #require(try await control.claimPendingRequest())
    let tracker = try ScanProgressTracker(
        context: ScanProgressContext(requestID: claimed.requestID, trigger: .manual, startedAt: claimed.createdAt),
        reporter: control, cancellationChecker: control, commitBoundary: control)
    try await tracker.transition(to: .preparing, mode: nil)
    try await tracker.transition(to: .reclaimingSpace, mode: nil)
    let persisted = try #require(try await control.latestProgress())
    let result = await SpaceMaintenanceRunner().run(
        request: claimed, resumedProgress: persisted, control: control, databaseURL: url,
        availableBytes: { Int64.max })
    #expect(result == 1)
    #expect(try await control.latestSummary()?.errorCategory == .maintenanceInterrupted)
    let reader = try SQLiteReportStore(databaseURL: url)
    #expect(try await reader.spaceUsage().lastMaintenanceAt == nil)
    #expect(try await reader.recentRuns().isEmpty)
}
