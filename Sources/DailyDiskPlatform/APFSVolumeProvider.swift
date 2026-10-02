import CryptoKit
import DailyDiskCore
import Foundation

struct APFSContainerRecord: Equatable, Sendable {
    let uuid: UUID
    let reference: String
    let capacityBytes: Int64
    let freeBytes: Int64
    let physicalStores: [String]
    let volumes: [APFSVolumeRecord]
}

struct APFSVolumeRecord: Equatable, Sendable {
    let uuid: UUID
    let deviceIdentifier: String
    let name: String
    let roles: [String]
    let capacityInUse: Int64?
}

struct APFSVolumeGroupMembership: Equatable, Sendable {
    let containerUUID: UUID
    let groupUUID: UUID
    let volumeDeviceIdentifier: String
    let role: VolumeRole
}

struct APFSParseResult: Sendable {
    let containers: [APFSContainerRecord]
    let diagnostics: [String]
}

enum DiskutilAPFSParser {
    static func parse(_ data: Data) throws -> APFSParseResult {
        let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let root = propertyList as? [String: Any],
            let rawContainers = root["Containers"] as? [[String: Any]],
            !rawContainers.isEmpty
        else {
            throw APFSDiscoveryError.invalidPropertyList("Missing or empty Containers array")
        }

        var containers: [APFSContainerRecord] = []
        let diagnostics: [String] = []
        var containerUUIDs: Set<UUID> = []
        var containerReferences: Set<String> = []
        var volumeUUIDs: Set<UUID> = []
        var volumeDeviceIdentifiers: Set<String> = []
        var physicalStoreOwners: [String: UUID] = [:]

        for raw in rawContainers {
            guard let uuidString = raw["APFSContainerUUID"] as? String,
                let uuid = UUID(uuidString: uuidString),
                let reference = raw["ContainerReference"] as? String,
                let capacity = exactInt64(raw["CapacityCeiling"]),
                let free = exactInt64(raw["CapacityFree"]),
                capacity >= 0,
                free >= 0,
                free <= capacity,
                containerUUIDs.insert(uuid).inserted,
                containerReferences.insert(reference).inserted
            else {
                throw APFSDiscoveryError.invalidPropertyList("Malformed or duplicate APFS container")
            }

            guard let rawStores = raw["PhysicalStores"] as? [[String: Any]], !rawStores.isEmpty else {
                throw APFSDiscoveryError.invalidPropertyList("Container \(reference) has no physical stores")
            }
            let stores = try rawStores.map { rawStore -> String in
                guard let identifier = rawStore["DeviceIdentifier"] as? String, !identifier.isEmpty else {
                    throw APFSDiscoveryError.invalidPropertyList("Malformed physical store in \(reference)")
                }
                if let owner = physicalStoreOwners[identifier], owner != uuid {
                    throw APFSDiscoveryError.duplicatePhysicalStore(identifier)
                }
                physicalStoreOwners[identifier] = uuid
                return identifier
            }
            guard Set(stores).count == stores.count else {
                throw APFSDiscoveryError.duplicatePhysicalStore(stores.joined(separator: ","))
            }

            guard let rawVolumes = raw["Volumes"] as? [[String: Any]] else {
                throw APFSDiscoveryError.invalidPropertyList("Container \(reference) is missing Volumes")
            }
            var volumes: [APFSVolumeRecord] = []
            for rawVolume in rawVolumes {
                guard let volumeUUIDString = rawVolume["APFSVolumeUUID"] as? String,
                    let volumeUUID = UUID(uuidString: volumeUUIDString),
                    volumeUUIDs.insert(volumeUUID).inserted,
                    let device = rawVolume["DeviceIdentifier"] as? String,
                    !device.isEmpty,
                    volumeDeviceIdentifiers.insert(device).inserted,
                    let name = rawVolume["Name"] as? String,
                    let roles = rawVolume["Roles"] as? [String]
                else {
                    throw APFSDiscoveryError.invalidPropertyList(
                        "Malformed or duplicate volume in container \(reference)"
                    )
                }
                let used = rawVolume["CapacityInUse"].map { exactInt64($0) } ?? nil
                if rawVolume["CapacityInUse"] != nil, used == nil {
                    throw APFSDiscoveryError.invalidPropertyList("Invalid CapacityInUse for \(device)")
                }
                volumes.append(
                    APFSVolumeRecord(
                        uuid: volumeUUID,
                        deviceIdentifier: device,
                        name: name,
                        roles: roles,
                        capacityInUse: used
                    )
                )
            }
            containers.append(
                APFSContainerRecord(
                    uuid: uuid,
                    reference: reference,
                    capacityBytes: capacity,
                    freeBytes: free,
                    physicalStores: stores,
                    volumes: volumes
                )
            )
        }
        return APFSParseResult(containers: containers, diagnostics: diagnostics)
    }

    private static func exactInt64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
            String(cString: number.objCType) != "c"
        else { return nil }
        let converted = number.int64Value
        guard number.decimalValue == Decimal(converted) else { return nil }
        return converted
    }
}

enum DiskutilVolumeGroupParser {
    static func parse(_ data: Data) throws -> [UUID: APFSVolumeGroupMembership] {
        let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let root = propertyList as? [String: Any],
            let containers = root["Containers"] as? [[String: Any]]
        else {
            throw APFSDiscoveryError.invalidPropertyList("Missing volume-group Containers array")
        }

        var result: [UUID: APFSVolumeGroupMembership] = [:]
        var containerUUIDs: Set<UUID> = []
        var containerReferences: Set<String> = []
        var groupUUIDs: Set<UUID> = []
        var memberDevices: Set<String> = []
        for container in containers {
            guard let containerString = container["APFSContainerUUID"] as? String,
                let containerUUID = UUID(uuidString: containerString),
                containerUUIDs.insert(containerUUID).inserted,
                let containerReference = container["ContainerReference"] as? String,
                containerReferences.insert(containerReference).inserted,
                let groups = container["VolumeGroups"] as? [[String: Any]]
            else {
                throw APFSDiscoveryError.invalidPropertyList("Malformed volume-group container")
            }
            for group in groups {
                guard let groupString = group["APFSVolumeGroupUUID"] as? String,
                    let groupUUID = UUID(uuidString: groupString),
                    groupUUIDs.insert(groupUUID).inserted,
                    let volumes = group["Volumes"] as? [[String: Any]],
                    volumes.count == 2
                else {
                    throw APFSDiscoveryError.invalidPropertyList("Malformed APFS volume group")
                }
                var groupRoles: Set<String> = []
                for volume in volumes {
                    guard let volumeString = volume["DiskUUID"] as? String,
                        let volumeUUID = UUID(uuidString: volumeString),
                        let deviceIdentifier = volume["DeviceIdentifier"] as? String,
                        !deviceIdentifier.isEmpty,
                        memberDevices.insert(deviceIdentifier).inserted,
                        let roleString = volume["Role"] as? String,
                        groupRoles.insert(roleString.lowercased()).inserted
                    else {
                        throw APFSDiscoveryError.invalidPropertyList("Malformed grouped APFS volume")
                    }
                    let role = role(for: roleString)
                    guard role == .system || role == .data, result[volumeUUID] == nil else {
                        throw APFSDiscoveryError.invalidPropertyList("Duplicate or unsupported group member")
                    }
                    result[volumeUUID] = APFSVolumeGroupMembership(
                        containerUUID: containerUUID,
                        groupUUID: groupUUID,
                        volumeDeviceIdentifier: deviceIdentifier,
                        role: role
                    )
                }
                guard groupRoles == ["system", "data"] else {
                    throw APFSDiscoveryError.invalidPropertyList("Volume group must contain one System and one Data")
                }
            }
        }
        return result
    }

    private static func role(for value: String) -> VolumeRole {
        switch value.lowercased() {
        case "system": .system
        case "data": .data
        default: .unknown
        }
    }
}

public struct APFSVolumeProvider: VolumeDiscovering {
    private let processRunner: any ProcessRunning
    private let diskArbitration: any DiskArbitrationProviding
    private let eventStoreUUIDProvider: any EventStoreUUIDIdentifying
    private let diskutilURL: URL
    private let now: @Sendable () -> Date

    public init(
        processRunner: any ProcessRunning = SystemProcessRunner(),
        diskArbitration: any DiskArbitrationProviding = SystemDiskArbitrationAdapter(),
        eventStoreUUIDProvider: any EventStoreUUIDIdentifying = SystemEventStoreUUIDProvider(),
        diskutilURL: URL = URL(fileURLWithPath: "/usr/sbin/diskutil"),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.processRunner = processRunner
        self.diskArbitration = diskArbitration
        self.eventStoreUUIDProvider = eventStoreUUIDProvider
        self.diskutilURL = diskutilURL
        self.now = now
    }

    public func discoverInternalAPFSVolumes() async throws -> VolumeTopology {
        async let listResult = processRunner.run(
            ProcessRequest(executableURL: diskutilURL, arguments: ["apfs", "list", "-plist"])
        )
        async let groupResult = processRunner.run(
            ProcessRequest(executableURL: diskutilURL, arguments: ["apfs", "listVolumeGroups", "-plist"])
        )
        let (listOutput, groupOutput) = try await (listResult, groupResult)
        let parsed = try DiskutilAPFSParser.parse(
            listOutput.requireSuccess(executable: diskutilURL.path)
        )
        let groupMembership = try DiskutilVolumeGroupParser.parse(
            groupOutput.requireSuccess(executable: diskutilURL.path)
        )
        let containersByUUID = Dictionary(uniqueKeysWithValues: parsed.containers.map { ($0.uuid, $0) })
        for (volumeUUID, membership) in groupMembership {
            guard let container = containersByUUID[membership.containerUUID],
                let volume = container.volumes.first(where: { $0.uuid == volumeUUID }),
                volume.deviceIdentifier == membership.volumeDeviceIdentifier,
                volumeRole(volume.roles) == membership.role
            else {
                throw APFSDiscoveryError.invalidPropertyList(
                    "Volume-group membership does not match APFS volume inventory"
                )
            }
        }
        for container in parsed.containers {
            for volume in container.volumes where volumeRole(volume.roles) == .system {
                guard groupMembership[volume.uuid] != nil else {
                    throw APFSDiscoveryError.invalidPropertyList("System volume is missing a Data volume group")
                }
            }
        }
        let mounted = try await diskArbitration.mountedVolumes()
        var diagnostics = parsed.diagnostics
        var domains: [StorageDomain] = []
        var volumes: [MonitoredVolume] = []

        for container in parsed.containers {
            var hardware: [DiskHardwareDescription] = []
            for store in container.physicalStores {
                guard let description = try await diskArbitration.describeDisk(bsdName: store) else {
                    diagnostics.append("Excluded \(container.reference): cannot identify physical store \(store)")
                    hardware.removeAll()
                    break
                }
                hardware.append(description)
            }
            guard hardware.count == container.physicalStores.count else { continue }
            guard
                hardware.allSatisfy({
                    $0.isInternal && !$0.isRemovable && !$0.isEjectable && !$0.isVirtual
                        && $0.devicePath != nil
                })
            else {
                diagnostics.append("Excluded non-internal APFS container \(container.reference)")
                continue
            }

            let domainID = StorageDomain.ID(container.uuid.uuidString)
            domains.append(
                StorageDomain(
                    id: domainID,
                    containerIdentifier: container.reference,
                    displayName: "APFS \(container.reference)",
                    isInternal: true
                )
            )

            let mountedDataVolumes = container.volumes.compactMap {
                candidate -> (APFSVolumeRecord, MountedVolumeDescription)? in
                let candidateRole = groupMembership[candidate.uuid]?.role ?? volumeRole(candidate.roles)
                guard candidateRole == .data,
                    let mount = matchMountedVolume(candidate, role: candidateRole, candidates: mounted),
                    !mount.isReadOnly
                else { return nil }
                return (candidate, mount)
            }
            let selectedFullVolumeUUID =
                mountedDataVolumes.first(where: {
                    $0.1.mountPath == "/System/Volumes/Data"
                })?.0.uuid

            for rawVolume in container.volumes {
                let membership = groupMembership[rawVolume.uuid]
                if let membership, membership.containerUUID != container.uuid {
                    throw APFSDiscoveryError.invalidPropertyList("Volume group crosses APFS containers")
                }
                let role = membership?.role ?? volumeRole(rawVolume.roles)
                let mount = matchMountedVolume(rawVolume, role: role, candidates: mounted)
                let readOnly = role == .system || mount?.isReadOnly == true
                let inventoryMode: VolumeInventoryMode =
                    rawVolume.uuid == selectedFullVolumeUUID
                    ? .full : .metricsOnly
                let observedEventStore = mount.flatMap {
                    eventStoreUUIDProvider.eventStoreUUID(deviceID: $0.deviceID)
                }
                let persistentEvents = inventoryMode == .full && observedEventStore != nil
                let eventStoreUUID = persistentEvents ? observedEventStore : nil
                volumes.append(
                    MonitoredVolume(
                        id: MonitoredVolume.ID(rawVolume.uuid.uuidString),
                        storageDomainID: domainID,
                        filesystemUUID: rawVolume.uuid,
                        volumeGroupUUID: membership?.groupUUID,
                        eventStoreUUID: eventStoreUUID,
                        deviceID: mount?.deviceID ?? 0,
                        mountPath: mount?.mountPath,
                        displayName: rawVolume.name,
                        role: role,
                        isInternal: true,
                        isRemovable: false,
                        isReadOnly: readOnly,
                        supportsPersistentEvents: persistentEvents,
                        topologyFingerprint: topologyFingerprint(
                            containerUUID: container.uuid,
                            volumeUUID: rawVolume.uuid,
                            volumeGroupUUID: membership?.groupUUID,
                            role: role
                        ),
                        inventoryMode: inventoryMode
                    )
                )
            }
        }

        guard !domains.isEmpty, !volumes.isEmpty else {
            throw APFSDiscoveryError.noTrustedInternalContainers(diagnostics)
        }
        domains.sort { $0.id.rawValue < $1.id.rawValue }
        volumes.sort { lhs, rhs in
            if lhs.storageDomainID != rhs.storageDomainID {
                return lhs.storageDomainID.rawValue < rhs.storageDomainID.rawValue
            }
            return lhs.id.rawValue < rhs.id.rawValue
        }
        for volume in volumes {
            ScanProbe.emit(
                .volumeDiscovered,
                fields: [
                    "volume": volume.id.rawValue, "domain": volume.storageDomainID.rawValue,
                    "volumeRole": volume.role.rawValue, "groupUUID": volume.volumeGroupUUID?.uuidString ?? "nil",
                    "filesystemUUID": volume.filesystemUUID?.uuidString ?? "nil",
                    "device": String(volume.deviceID),
                    "nativeDevice": nativeDeviceID(from: volume.deviceID).map { String($0) } ?? "nil",
                    "journalUUID": volume.eventStoreUUID?.uuidString ?? "nil",
                    "topology": volume.topologyFingerprint, "inventoryMode": volume.inventoryMode.rawValue,
                ])
        }
        return VolumeTopology(
            domains: domains,
            volumes: volumes,
            discoveredAt: now(),
            diagnostics: diagnostics.sorted()
        )
    }

    private func matchMountedVolume(
        _ volume: APFSVolumeRecord,
        role: VolumeRole,
        candidates: [MountedVolumeDescription]
    ) -> MountedVolumeDescription? {
        let eligible = candidates.filter {
            $0.filesystemKind?.lowercased() == "apfs" && $0.isInternal && !$0.isRemovable
        }
        if let byUUID = eligible.first(where: { $0.volumeUUID == volume.uuid }) {
            return byUUID
        }
        if let byDevice = eligible.first(where: {
            $0.bsdName == volume.deviceIdentifier && ($0.volumeUUID == nil || $0.volumeUUID == volume.uuid)
        }) {
            return byDevice
        }
        if role == .system {
            return eligible.first(where: { candidate in
                candidate.mountPath == "/"
                    && candidate.bsdName.hasPrefix(volume.deviceIdentifier + "s")
            })
        }
        return nil
    }

    private func volumeRole(_ roles: [String]) -> VolumeRole {
        let normalized = Set(roles.map { $0.lowercased() })
        if normalized.contains("data") { return .data }
        if normalized.contains("system") { return .system }
        if normalized.contains("vm") { return .vm }
        if normalized.contains("preboot") { return .preboot }
        if normalized.contains("recovery") { return .recovery }
        if normalized.contains("update") { return .update }
        if normalized.contains("hardware") { return .hardware }
        return .unknown
    }

    private func topologyFingerprint(
        containerUUID: UUID,
        volumeUUID: UUID,
        volumeGroupUUID: UUID?,
        role: VolumeRole
    ) -> String {
        let source = [
            containerUUID.uuidString,
            volumeUUID.uuidString,
            volumeGroupUUID?.uuidString ?? "-",
            role.rawValue,
        ].joined(separator: "|")
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum APFSDiscoveryError: Error, Equatable, Sendable {
    case invalidPropertyList(String)
    case duplicatePhysicalStore(String)
    case noTrustedInternalContainers([String])
    case storageDomainNotFound(StorageDomain.ID)
}
