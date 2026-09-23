import Foundation
import Testing

@testable import DailyDiskCore

@Test("Progress phases follow the user-visible execution sequence")
func progressPhaseOrdering() {
    let phases: [ScanProgressPhase] = [
        .queued,
        .preparing,
        .recoveringInterruptedRun,
        .discoveringStorage,
        .replayingEvents,
        .scanningFiles,
        .catchingUpEvents,
        .sealingInventory,
        .reconciling,
        .collectingDiagnostics,
        .committing,
        .publishingReport,
        .notifying,
        .applyingRetention,
        .completed,
    ]
    for pair in zip(phases, phases.dropFirst()) {
        #expect(ScanProgressTransitionValidator.canTransition(from: pair.0, to: pair.1))
    }
    #expect(!ScanProgressTransitionValidator.canTransition(from: .completed, to: .preparing))
    #expect(!ScanProgressTransitionValidator.canTransition(from: .queued, to: .notifying))
    #expect(!ScanProgressTransitionValidator.canTransition(from: .waitingForWriter, to: .sealingInventory))
    #expect(ScanProgressTransitionValidator.canTransition(from: .scanningFiles, to: .cancelling))
    #expect(!ScanProgressTransitionValidator.canTransition(from: .committing, to: .cancelling))
    #expect(!ScanProgressTransitionValidator.canTransition(from: .cancelling, to: .completed))
    #expect(ScanProgressTransitionValidator.canTransition(from: .catchingUpEvents, to: .preparing))
    #expect(ScanProgressTransitionValidator.canTransition(from: .recoveringInterruptedRun, to: .discoveringStorage))
    #expect(!ScanProgressPhase.committing.allowsCancellation)
    #expect(ScanProgressPhase.scanningFiles.allowsCancellation)
    #expect(ScanProgressTransitionValidator.canTransition(from: .scanningFiles, to: .cleaningUpFailedRun))
    #expect(ScanProgressTransitionValidator.canTransition(from: .cleaningUpFailedRun, to: .failed))
    #expect(ScanProgressTransitionValidator.canTransition(from: .cleaningUpFailedRun, to: .preparing))
    #expect(!ScanProgressPhase.cleaningUpFailedRun.allowsCancellation)
    // Rollback/restart cleanup is not cancellation of a live atomic commit.
    #expect(ScanProgressTransitionValidator.canTransition(from: .committing, to: .cleaningUpFailedRun))
}

@Test("Progress counters apply checked deltas")
func progressCountersApplyDeltas() throws {
    let counters = ScanProgressCounters(processedEvents: 2, visitedPaths: 10)
    let updated = try counters.applying(
        ScanProgressDelta(
            processedEvents: 3,
            affectedPaths: 2,
            visitedPaths: 5,
            indexedObjects: 4,
            unreadablePaths: 1,
            transientErrors: 1
        )
    )
    #expect(updated.processedEvents == 5)
    #expect(updated.affectedPaths == 2)
    #expect(updated.visitedPaths == 15)
    #expect(updated.indexedObjects == 4)
    #expect(throws: ScanProgressError.counterOverflow) {
        _ = try ScanProgressCounters(processedEvents: .max).applying(
            ScanProgressDelta(processedEvents: 1)
        )
    }
}

@Test("Progress and control JSON cannot carry paths or arbitrary commands")
func progressPayloadIsPathFree() throws {
    let requestID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let snapshot = try ScanProgressSnapshot(
        requestID: requestID,
        trigger: .manual,
        mode: .initialFull,
        phase: .scanningFiles,
        startedAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 101),
        domainOrdinal: 1,
        domainCount: 1,
        counters: ScanProgressCounters(visitedPaths: 42, indexedObjects: 40)
    )
    let request = try DailyDiskRunRequest(
        requestID: requestID,
        action: .scanNow,
        requestedMode: .automatic,
        createdAt: Date(timeIntervalSince1970: 99)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let text =
        String(decoding: try encoder.encode(snapshot), as: UTF8.self)
        + String(decoding: try encoder.encode(request), as: UTF8.self)

    #expect(!text.contains("/Users/alice"))
    #expect(!text.lowercased().contains("filepath"))
    #expect(!text.lowercased().contains("command"))
    #expect(text.contains("scanningFiles"))
    #expect(text.contains("scanNow"))
}

@Test("Unknown protocol versions and malformed progress are rejected")
func progressValidationRejectsMalformedValues() throws {
    #expect(throws: ScanProgressError.unsupportedProtocolVersion) {
        _ = try DailyDiskRunRequest(version: 99)
    }
    #expect(throws: ScanProgressError.invalidSnapshot) {
        _ = try ScanProgressSnapshot(
            requestID: UUID(),
            trigger: .manual,
            mode: nil,
            phase: .failed,
            startedAt: Date(timeIntervalSince1970: 2),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }
}

@Test("Run summary validates terminal accounting without paths")
func runSummaryValidation() throws {
    let summary = try DailyDiskRunSummary(
        requestID: UUID(),
        trigger: .manual,
        terminalState: .succeeded,
        startedAt: Date(timeIntervalSince1970: 1),
        finishedAt: Date(timeIntervalSince1970: 2),
        completedDomainCount: 1,
        failedDomainCount: 0,
        reportRunIDs: [UUID()]
    )
    #expect(summary.terminalState == .succeeded)
    #expect(summary.errorCategory == nil)
    #expect(summary.version == DailyDiskRunSummary.protocolVersion)

    #expect(throws: ScanProgressError.invalidSummary) {
        _ = try DailyDiskRunSummary(
            requestID: UUID(),
            trigger: .manual,
            terminalState: .failed,
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2),
            completedDomainCount: 0,
            failedDomainCount: 0,
            reportRunIDs: [],
            errorCategory: nil
        )
    }

    let encoded = try JSONEncoder().encode(summary)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["completedDomainCount"] = -1
    let invalid = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(DailyDiskRunSummary.self, from: invalid)
    }
}
