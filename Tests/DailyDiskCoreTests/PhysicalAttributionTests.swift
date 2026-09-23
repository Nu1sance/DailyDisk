import Foundation
import Testing

@testable import DailyDiskCore

@Test("Physical attribution keeps evidence separate from inventory correction")
func physicalAttributionEvidence() throws {
    let volumeID = MonitoredVolume.ID("data")
    let accounting = try AccountingSummary(
        eventAttributedDelta: 1_000,
        reconciliationCorrection: 200,
        reconciledIndexedDelta: 1_200,
        dailyDiskOverheadDelta: 100,
        physicalUsedDelta: 5_000,
        physicalUnattributedDelta: 3_700
    )
    let previous = [
        try SnapshotSample(
            volumeID: volumeID,
            sampledAt: Date(timeIntervalSince1970: 1),
            snapshotUUID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"),
            name: "old",
            createdAt: nil,
            isPurgeable: nil,
            allocatedBytesEstimate: nil
        )
    ]
    let current = [
        try SnapshotSample(
            volumeID: volumeID,
            sampledAt: Date(timeIntervalSince1970: 2),
            snapshotUUID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"),
            name: "new",
            createdAt: nil,
            isPurgeable: false,
            allocatedBytesEstimate: nil
        )
    ]
    let files = [
        try DeletedOpenFile(
            processID: 1,
            command: "one",
            fileDescriptor: "4u",
            device: "0x1",
            inode: "99",
            logicalBytes: 8_192,
            path: "/deleted"
        ),
        try DeletedOpenFile(
            processID: 2,
            command: "two",
            fileDescriptor: "5u",
            device: "0x1",
            inode: "99",
            logicalBytes: 8_192,
            path: "/deleted"
        ),
        try DeletedOpenFile(
            processID: 3,
            command: "external",
            fileDescriptor: "6u",
            device: "0x2",
            inode: "100",
            logicalBytes: 99_999,
            path: "/external/deleted"
        ),
    ]

    let diagnosis = try PhysicalAttribution.analyze(
        accounting: accounting,
        previousSnapshots: previous,
        currentSnapshots: current,
        deletedOpenFiles: files,
        monitoredDeviceIDs: [1],
        unreadablePathCount: 2
    )

    #expect(diagnosis.physicalUnattributedDelta == 3_700)
    #expect(diagnosis.snapshotCountDelta == 0)
    #expect(diagnosis.uniqueDeletedOpenLogicalBytes == 8_192)
    #expect(diagnosis.likelyCauses.contains(.snapshotSetChanged))
    #expect(diagnosis.likelyCauses.contains(.deletedOpenFiles))
    #expect(diagnosis.likelyCauses.contains(.inaccessiblePaths))
    #expect(accounting.reconciliationCorrection == 200)
}

private struct FixedDeletedOpenProbe: DeletedOpenFileProbing {
    let values: [DeletedOpenFile]
    func deletedOpenFiles() async throws -> [DeletedOpenFile] { values }
}

@Test("Diagnostics coordinator scopes deleted files to the APFS domain")
func diagnosticsCoordinatorScopesDeletedFiles() async throws {
    let volume = MonitoredVolume(
        id: MonitoredVolume.ID("data"),
        storageDomainID: StorageDomain.ID("domain"),
        filesystemUUID: UUID(),
        eventStoreUUID: UUID(),
        deviceID: 0x10,
        mountPath: "/System/Volumes/Data",
        displayName: "Data",
        role: .data,
        isInternal: true,
        isRemovable: false,
        isReadOnly: false,
        supportsPersistentEvents: true,
        topologyFingerprint: "topology"
    )
    let domain = StorageDomain(
        id: volume.storageDomainID,
        containerIdentifier: "disk3",
        displayName: "Internal",
        isInternal: true
    )
    let scope = try StorageDomainScope(domain: domain, volumes: [volume])
    let matching = try DeletedOpenFile(
        processID: 1,
        command: "matching",
        fileDescriptor: "4u",
        device: "0x10",
        inode: "1",
        logicalBytes: 100,
        path: "/matching"
    )
    let external = try DeletedOpenFile(
        processID: 2,
        command: "external",
        fileDescriptor: "5u",
        device: "0x20",
        inode: "2",
        logicalBytes: 999,
        path: "/external"
    )
    let accounting = try AccountingSummary(
        eventAttributedDelta: 0,
        reconciliationCorrection: 0,
        reconciledIndexedDelta: 0,
        dailyDiskOverheadDelta: 0,
        physicalUsedDelta: 100,
        physicalUnattributedDelta: 100
    )
    let diagnosis = try await PhysicalDiagnosticsCoordinator(
        deletedOpenFileProbe: FixedDeletedOpenProbe(values: [matching, external])
    ).diagnose(
        accounting: accounting,
        scope: scope,
        previousSnapshots: [],
        currentSnapshots: [],
        unreadablePathCount: 0
    )

    #expect(diagnosis.uniqueDeletedOpenLogicalBytes == 100)
}

@Test("No physical baseline remains unknown")
func missingPhysicalAttributionBaseline() throws {
    let accounting = try AccountingSummary(
        eventAttributedDelta: 0,
        reconciliationCorrection: 0,
        reconciledIndexedDelta: 0,
        dailyDiskOverheadDelta: 0,
        physicalUsedDelta: nil,
        physicalUnattributedDelta: nil
    )
    let diagnosis = try PhysicalAttribution.analyze(
        accounting: accounting,
        previousSnapshots: [],
        currentSnapshots: [],
        deletedOpenFiles: [],
        monitoredDeviceIDs: [],
        unreadablePathCount: 0
    )

    #expect(diagnosis.physicalUnattributedDelta == nil)
    #expect(diagnosis.likelyCauses.isEmpty)
}
