import DailyDiskCore
import Darwin
import Foundation
import Testing

@testable import DailyDiskPlatform

private let internalContainerUUID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
private let dataVolumeUUID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
private let eventStoreUUID = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!

private func fixtureData(named name: String) throws -> Data {
    let testsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try Data(contentsOf: testsDirectory.appendingPathComponent("Fixtures/diskutil/\(name).plist"))
}

private func apfsFixtureData() throws -> Data {
    try fixtureData(named: "apfs-list")
}

private func volumeGroupFixtureData() throws -> Data {
    try fixtureData(named: "apfs-volume-groups")
}

private struct FixtureProcessRunner: ProcessRunning {
    let result: ProcessResult
    let volumeGroupResult: ProcessResult?

    init(result: ProcessResult, volumeGroupResult: ProcessResult? = nil) {
        self.result = result
        self.volumeGroupResult = volumeGroupResult
    }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        if request.arguments.contains("listVolumeGroups"), let volumeGroupResult {
            return volumeGroupResult
        }
        return result
    }
}

private struct FixtureDiskArbitration: DiskArbitrationProviding {
    let hardware: [String: DiskHardwareDescription]
    let mounts: [MountedVolumeDescription]

    func describeDisk(bsdName: String) async throws -> DiskHardwareDescription? {
        hardware[bsdName]
    }

    func mountedVolumes() async throws -> [MountedVolumeDescription] {
        mounts
    }
}

private struct FixtureEventStoreProvider: EventStoreUUIDIdentifying {
    let values: [UInt64: UUID]

    func eventStoreUUID(deviceID: UInt64) -> UUID? {
        values[deviceID]
    }
}

private struct FixtureCapacityHints: VolumeCapacityHintProviding {
    let hints: VolumeCapacityHints

    func capacityHints(mountPath: String) throws -> VolumeCapacityHints {
        hints
    }
}

private func fixtureDiskArbitration() -> FixtureDiskArbitration {
    FixtureDiskArbitration(
        hardware: [
            "disk0s2": DiskHardwareDescription(
                bsdName: "disk0s2",
                isInternal: true,
                isRemovable: false,
                isEjectable: false,
                isVirtual: false,
                protocolName: "Apple Fabric",
                model: "Internal SSD",
                devicePath: "IODeviceTree:/internal/ssd"
            ),
            "disk4s2": DiskHardwareDescription(
                bsdName: "disk4s2",
                isInternal: false,
                isRemovable: false,
                isEjectable: false,
                isVirtual: false,
                protocolName: "USB",
                model: "External SSD",
                devicePath: "IODeviceTree:/usb/external"
            ),
        ],
        mounts: [
            MountedVolumeDescription(
                bsdName: "disk3s1s1",
                mountPath: "/",
                filesystemKind: "apfs",
                volumeUUID: UUID(uuidString: "99999999-9999-9999-9999-999999999999"),
                deviceID: 100,
                isInternal: true,
                isRemovable: false,
                isReadOnly: true
            ),
            MountedVolumeDescription(
                bsdName: "disk3s5",
                mountPath: "/System/Volumes/Data",
                filesystemKind: "apfs",
                volumeUUID: dataVolumeUUID,
                deviceID: 100,
                isInternal: true,
                isRemovable: false,
                isReadOnly: false
            ),
            MountedVolumeDescription(
                bsdName: "disk3s6",
                mountPath: "/System/Volumes/VM",
                filesystemKind: "apfs",
                volumeUUID: UUID(uuidString: "33333333-3333-3333-3333-333333333333"),
                deviceID: 101,
                isInternal: true,
                isRemovable: false,
                isReadOnly: false
            ),
            MountedVolumeDescription(
                bsdName: "disk5s1",
                mountPath: "/Volumes/External Data",
                filesystemKind: "apfs",
                volumeUUID: UUID(uuidString: "44444444-4444-4444-4444-444444444444"),
                deviceID: 200,
                isInternal: false,
                isRemovable: false,
                isReadOnly: false
            ),
        ]
    )
}

@Test("diskutil APFS parser preserves containers, roles, and shared capacity")
func diskutilParser() throws {
    let result = try DiskutilAPFSParser.parse(apfsFixtureData())

    #expect(result.containers.count == 2)
    let internalContainer = try #require(result.containers.first { $0.uuid == internalContainerUUID })
    #expect(internalContainer.capacityBytes == 1_000)
    #expect(internalContainer.freeBytes == 400)
    #expect(internalContainer.physicalStores == ["disk0s2"])
    #expect(internalContainer.volumes.map(\.roles) == [["System"], ["Data"], ["VM"]])

    let groups = try DiskutilVolumeGroupParser.parse(volumeGroupFixtureData())
    #expect(groups.count == 2)
    #expect(groups[dataVolumeUUID]?.groupUUID == UUID(uuidString: "55555555-5555-5555-5555-555555555555"))
    #expect(groups[dataVolumeUUID]?.role == .data)
}

@Test("parser rejects duplicate physical ownership and non-integer capacity")
func parserRejectsUntrustedStructure() throws {
    let original = try PropertyListSerialization.propertyList(
        from: apfsFixtureData(),
        options: [.mutableContainersAndLeaves],
        format: nil
    )
    let duplicateRoot = try #require(original as? NSMutableDictionary)
    let containers = try #require(duplicateRoot["Containers"] as? NSMutableArray)
    containers.add(containers[0])
    let duplicateData = try PropertyListSerialization.data(
        fromPropertyList: duplicateRoot,
        format: .xml,
        options: 0
    )
    #expect(throws: (any Error).self) {
        _ = try DiskutilAPFSParser.parse(duplicateData)
    }

    let booleanRoot = try #require(
        PropertyListSerialization.propertyList(
            from: apfsFixtureData(),
            options: [.mutableContainersAndLeaves],
            format: nil
        ) as? NSMutableDictionary
    )
    let booleanContainers = try #require(booleanRoot["Containers"] as? NSMutableArray)
    let first = try #require(booleanContainers[0] as? NSMutableDictionary)
    first["CapacityCeiling"] = true
    let booleanData = try PropertyListSerialization.data(
        fromPropertyList: booleanRoot,
        format: .xml,
        options: 0
    )
    #expect(throws: (any Error).self) {
        _ = try DiskutilAPFSParser.parse(booleanData)
    }
}

@Test("provider excludes external containers and maps the sealed system snapshot")
func providerFiltersAndMapsVolumes() async throws {
    let instant = Date(timeIntervalSince1970: 123)
    let provider = APFSVolumeProvider(
        processRunner: FixtureProcessRunner(
            result: ProcessResult(
                terminationStatus: 0,
                standardOutput: try apfsFixtureData(),
                standardError: Data()
            ),
            volumeGroupResult: ProcessResult(
                terminationStatus: 0,
                standardOutput: try volumeGroupFixtureData(),
                standardError: Data()
            )
        ),
        diskArbitration: fixtureDiskArbitration(),
        eventStoreUUIDProvider: FixtureEventStoreProvider(values: [100: eventStoreUUID, 101: eventStoreUUID]),
        now: { instant }
    )

    let topology = try await provider.discoverInternalAPFSVolumes()

    #expect(topology.discoveredAt == instant)
    #expect(topology.domains.count == 1)
    #expect(topology.domains[0].id == StorageDomain.ID(internalContainerUUID.uuidString))
    #expect(topology.volumes.count == 3)
    #expect(topology.volumes.allSatisfy { $0.isInternal })
    #expect(topology.volumes.allSatisfy { !$0.isRemovable })
    #expect(topology.diagnostics.contains { $0.contains("Excluded non-internal APFS container disk5") })

    let system = try #require(topology.volumes.first { $0.role == .system })
    #expect(system.mountPath == "/")
    #expect(system.isReadOnly)
    #expect(system.volumeGroupUUID == UUID(uuidString: "55555555-5555-5555-5555-555555555555"))
    #expect(system.inventoryMode == .metricsOnly)
    #expect(system.eventStoreUUID == nil)
    #expect(!system.supportsPersistentEvents)

    let data = try #require(topology.volumes.first { $0.role == .data })
    #expect(data.filesystemUUID == dataVolumeUUID)
    #expect(data.mountPath == "/System/Volumes/Data")
    #expect(data.deviceID == 100)
    #expect(data.volumeGroupUUID == system.volumeGroupUUID)
    #expect(data.inventoryMode == .full)
    #expect(data.eventStoreUUID == eventStoreUUID)
    #expect(data.supportsPersistentEvents)

    let vm = try #require(topology.volumes.first { $0.role == .vm })
    #expect(vm.mountPath == "/System/Volumes/VM")
    #expect(vm.deviceID == 101)
    #expect(Set(topology.volumes.map(\.topologyFingerprint)).count == 3)
}

@Test("physical sampling counts APFS container capacity exactly once")
func physicalCapacitySampling() async throws {
    let instant = Date(timeIntervalSince1970: 456)
    let runner = FixtureProcessRunner(
        result: ProcessResult(
            terminationStatus: 0,
            standardOutput: try apfsFixtureData(),
            standardError: Data()
        )
    )
    let sampler = APFSDiskUsageSampler(
        processRunner: runner,
        diskArbitration: fixtureDiskArbitration(),
        capacityHints: FixtureCapacityHints(
            hints: VolumeCapacityHints(
                importantUsageAvailableBytes: 450,
                opportunisticUsageAvailableBytes: 425
            )
        ),
        now: { instant }
    )
    let domain = StorageDomain(
        id: StorageDomain.ID(internalContainerUUID.uuidString),
        containerIdentifier: "disk3",
        displayName: "Internal",
        isInternal: true
    )

    let sample = try await sampler.sample(storageDomain: domain)

    #expect(sample.sampledAt == instant)
    #expect(sample.capacityBytes == 1_000)
    #expect(sample.usedBytes == 600)
    #expect(sample.availableBytes == 400)
    #expect(sample.importantUsageAvailableBytes == 450)
    #expect(sample.opportunisticUsageAvailableBytes == 425)
}

@Test("system Disk Arbitration adapter identifies startup System and Data mounts")
func systemDiskArbitrationAdapter() async throws {
    let adapter = SystemDiskArbitrationAdapter()
    let mounts = try await adapter.mountedVolumes()
    let root = try #require(mounts.first { $0.mountPath == "/" })
    let data = try #require(mounts.first { $0.mountPath == "/System/Volumes/Data" })

    #expect(!root.bsdName.isEmpty)
    #expect(root.deviceID != 0)
    #expect(root.filesystemKind?.lowercased() == "apfs")
    #expect(data.bsdName != root.bsdName)
    #expect(data.filesystemKind?.lowercased() == "apfs")
    let hardware = try await adapter.describeDisk(bsdName: root.bsdName)
    #expect(hardware != nil)
}

@Test("real discovery designates Data as the scan root and System as metrics-only")
func realStartupVolumeDiscovery() async throws {
    guard ProcessInfo.processInfo.environment["CI"] == nil else { return }
    let topology = try await APFSVolumeProvider().discoverInternalAPFSVolumes()
    let data = try #require(
        topology.volumes.first { $0.role == .data && $0.mountPath == "/System/Volumes/Data" }
    )
    let system = try #require(topology.volumes.first { $0.role == .system && $0.mountPath == "/" })

    #expect(data.inventoryMode == .full)
    #expect(system.inventoryMode == .metricsOnly)
    #expect(data.volumeGroupUUID == system.volumeGroupUUID)
    #expect(topology.domains.allSatisfy { $0.isInternal })
    #expect(Set(topology.domains.map(\.id)).count == topology.domains.count)
    #expect(!topology.volumes.contains { $0.mountPath?.hasPrefix("/Volumes/") == true })

    let domain = try #require(topology.domains.first { $0.id == data.storageDomainID })
    let sample = try await APFSDiskUsageSampler().sample(storageDomain: domain)
    #expect(sample.capacityBytes > 0)
    #expect(sample.usedBytes >= 0)
    #expect(sample.availableBytes >= 0)
    #expect(sample.usedBytes + sample.availableBytes == sample.capacityBytes)
}

@Test("system process runner enforces timeout and cancellation")
func systemProcessRunnerStopsWork() async throws {
    let runner = SystemProcessRunner()
    // A FIFO keeps the child alive until cancellation, independent of scheduler load.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let fifo = root.appendingPathComponent("wait").path
    let ready = root.appendingPathComponent("ready").path
    try #require(mkfifo(fifo, 0o600) == 0)
    let descriptor = open(fifo, O_RDWR | O_CLOEXEC)
    try #require(descriptor >= 0)
    defer { close(descriptor) }
    await #expect(throws: ProcessRunnerError.timedOut(executable: "/bin/sh", seconds: 0.05)) {
        _ = try await runner.run(
            ProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "read -r line < \"$1\"", "fixture", fifo],
                timeoutSeconds: 0.05
            )
        )
    }

    let task = Task {
        try await runner.run(
            ProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf ready > \"$1\"; read -r line < \"$2\"", "fixture", ready, fifo],
                timeoutSeconds: 60
            )
        )
    }
    defer { task.cancel() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while !FileManager.default.fileExists(atPath: ready), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    let started = FileManager.default.fileExists(atPath: ready)
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("Expected cancellation")
    } catch is CancellationError {
        // Expected.
    }
    #expect(started, "Child must signal readiness before cancellation")
}

@Test("event-store lookup rejects a device ID that cannot fit dev_t")
func eventStoreLookupChecksNativeRange() {
    #expect(SystemEventStoreUUIDProvider().eventStoreUUID(deviceID: .max) == nil)
}

@Test("system process runner captures output without invoking a shell")
func systemProcessRunner() async throws {
    let runner = SystemProcessRunner()
    let result = try await runner.run(
        ProcessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", "DailyDisk"]
        )
    )

    #expect(result.terminationStatus == 0)
    #expect(String(decoding: result.standardOutput, as: UTF8.self) == "DailyDisk")
    #expect(result.standardError.isEmpty)
}
