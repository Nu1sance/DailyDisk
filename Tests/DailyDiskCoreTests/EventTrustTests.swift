import Foundation
import Testing

@testable import DailyDiskCore

@Test(
    "FSEvents loss flags always require a full scan",
    arguments: [
        FileSystemEventFlags.userDropped,
        .kernelDropped,
        .eventIDsWrapped,
        .rootChanged,
        .mounted,
        .unmounted,
    ])
func eventLossRequiresFullScan(_ flag: FileSystemEventFlags) {
    let assessment = EventTrustEvaluator.assess(flags: flag)
    #expect(assessment.trust == .fullScanRequired)
    #expect(!assessment.reasons.isEmpty)
}

@Test("MustScanSubDirs requires a subtree scan unless a stronger flag exists")
func subtreeTrustEscalation() {
    let subtree = EventTrustEvaluator.assess(flags: .mustScanSubdirectories)
    #expect(subtree.trust == .subtreeRescanRequired)

    let dropped = EventTrustEvaluator.assess(flags: [.mustScanSubdirectories, .kernelDropped])
    #expect(dropped.trust == .fullScanRequired)
    #expect(subtree.merging(dropped).trust == .fullScanRequired)
}

@Test("Journal identity and cursor regression invalidate history")
func journalTrust() {
    let expected = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let replacement = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    #expect(
        EventTrustEvaluator.assessJournal(
            expectedUUID: expected,
            observedUUID: expected,
            previousEventID: 100,
            observedEventID: 101
        ).trust == .trusted
    )
    #expect(
        EventTrustEvaluator.assessJournal(
            expectedUUID: expected,
            observedUUID: replacement,
            previousEventID: 100,
            observedEventID: 101
        ).trust == .fullScanRequired
    )
    #expect(
        EventTrustEvaluator.assessJournal(
            expectedUUID: expected,
            observedUUID: expected,
            previousEventID: 100,
            observedEventID: 99
        ).trust == .fullScanRequired
    )
    #expect(
        EventTrustEvaluator.assessJournal(
            expectedUUID: expected,
            observedUUID: nil,
            previousEventID: 100,
            observedEventID: nil
        ).trust == .fullScanRequired
    )
}
