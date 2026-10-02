import CoreServices
import DailyDiskCore
import Darwin
import DiskArbitration
import Foundation

public struct DiskHardwareDescription: Equatable, Sendable {
    public let bsdName: String
    public let isInternal: Bool
    public let isRemovable: Bool
    public let isEjectable: Bool
    public let isVirtual: Bool
    public let protocolName: String?
    public let model: String?
    public let devicePath: String?

    public init(
        bsdName: String,
        isInternal: Bool,
        isRemovable: Bool,
        isEjectable: Bool,
        isVirtual: Bool,
        protocolName: String?,
        model: String?,
        devicePath: String? = nil
    ) {
        self.bsdName = bsdName
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isVirtual = isVirtual
        self.protocolName = protocolName
        self.model = model
        self.devicePath = devicePath
    }
}

public struct MountedVolumeDescription: Equatable, Sendable {
    public let bsdName: String
    public let mountPath: String
    public let filesystemKind: String?
    public let volumeUUID: UUID?
    public let deviceID: UInt64
    public let isInternal: Bool
    public let isRemovable: Bool
    public let isReadOnly: Bool

    public init(
        bsdName: String,
        mountPath: String,
        filesystemKind: String?,
        volumeUUID: UUID?,
        deviceID: UInt64,
        isInternal: Bool,
        isRemovable: Bool,
        isReadOnly: Bool
    ) {
        self.bsdName = bsdName
        self.mountPath = mountPath
        self.filesystemKind = filesystemKind
        self.volumeUUID = volumeUUID
        self.deviceID = deviceID
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isReadOnly = isReadOnly
    }
}

public protocol DiskArbitrationProviding: Sendable {
    func describeDisk(bsdName: String) async throws -> DiskHardwareDescription?
    func mountedVolumes() async throws -> [MountedVolumeDescription]
}

public protocol EventStoreUUIDIdentifying: Sendable {
    func eventStoreUUID(deviceID: UInt64) -> UUID?
    func latestEventID(deviceID: UInt64) -> UInt64?
}

extension EventStoreUUIDIdentifying {
    public func latestEventID(deviceID: UInt64) -> UInt64? { nil }
}

public struct SystemEventStoreUUIDProvider: EventStoreUUIDIdentifying {
    private let queryBeforeTime: @Sendable (dev_t, Double) -> UInt64
    public init() {
        queryBeforeTime = { FSEventsGetLastEventIdForDeviceBeforeTime($0, $1) }
    }
    init(queryBeforeTime: @escaping @Sendable (dev_t, Double) -> UInt64) {
        self.queryBeforeTime = queryBeforeTime
    }

    public func eventStoreUUID(deviceID: UInt64) -> UUID? {
        let native = nativeDeviceID(from: deviceID)
        let value = native.flatMap { FSEventsCopyUUIDForDevice($0) }
        let result = value.flatMap { UUID(uuidString: CFUUIDCreateString(kCFAllocatorDefault, $0) as String) }
        ScanProbe.emit(
            .journalRead,
            fields: [
                "device": String(deviceID),
                "nativeDevice": native.map { String($0) } ?? "nil", "journalUUID": result?.uuidString ?? "nil",
            ])
        return result
    }

    public func latestEventID(deviceID: UInt64) -> UInt64? {
        guard let native = nativeDeviceID(from: deviceID) else {
            ScanProbe.emit(.cursorQuery, fields: ["device": String(deviceID), "nativeDevice": "nil", "adopted": "nil"])
            return nil
        }
        let unixTime = Date().timeIntervalSince1970
        let value = queryBeforeTime(native, unixTime)
        var cfTime: Double?
        var fallback: UInt64?
        if value == 0 {
            cfTime = CFAbsoluteTimeGetCurrent()
            fallback = queryBeforeTime(native, cfTime!)
        }
        let selected = value != 0 ? value : (fallback ?? 0)
        ScanProbe.emit(
            .cursorQuery,
            fields: [
                "device": String(deviceID), "nativeDevice": String(native),
                "unixTime": String(unixTime), "unixResult": String(value),
                "fallbackExecuted": String(fallback != nil), "cfTime": cfTime.map { String($0) } ?? "nil",
                "cfResult": fallback.map { String($0) } ?? "nil", "adopted": selected == 0 ? "nil" : String(selected),
            ])
        return selected == 0 ? nil : selected
    }

}

public struct SystemDiskArbitrationAdapter: DiskArbitrationProviding {
    public init() {}

    public func describeDisk(bsdName: String) async throws -> DiskHardwareDescription? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
            let partition = bsdName.withCString({
                DADiskCreateFromBSDName(kCFAllocatorDefault, session, $0)
            })
        else {
            return nil
        }
        guard let disk = DADiskCopyWholeDisk(partition),
            let description = DADiskCopyDescription(disk) as NSDictionary?
        else {
            return nil
        }

        let protocolName = description.string(for: kDADiskDescriptionDeviceProtocolKey)
        let model = description.string(for: kDADiskDescriptionDeviceModelKey)
        let devicePath = description.string(for: kDADiskDescriptionDevicePathKey)
        let virtualDescription = "\(protocolName ?? "") \(model ?? "") \(devicePath ?? "")".lowercased()
        let positivelyPhysical =
            devicePath?.isEmpty == false
            && protocolName?.isEmpty == false
            && description.bool(for: kDADiskDescriptionMediaWholeKey) == true
        return DiskHardwareDescription(
            bsdName: description.string(for: kDADiskDescriptionMediaBSDNameKey) ?? bsdName,
            isInternal: description.bool(for: kDADiskDescriptionDeviceInternalKey) ?? false,
            isRemovable: description.bool(for: kDADiskDescriptionMediaRemovableKey) ?? true,
            isEjectable: description.bool(for: kDADiskDescriptionMediaEjectableKey) ?? true,
            isVirtual: !positivelyPhysical
                || virtualDescription.contains("virtual")
                || virtualDescription.contains("disk image")
                || virtualDescription.contains("hdix"),
            protocolName: protocolName,
            model: model,
            devicePath: devicePath
        )
    }

    public func mountedVolumes() async throws -> [MountedVolumeDescription] {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return [] }
        let entries = try mountedFileSystems()
        var result: [MountedVolumeDescription] = []
        var seenMountPaths: Set<String> = []

        for entry in entries {
            guard entry.source.hasPrefix("/dev/"),
                seenMountPaths.insert(entry.mountPath).inserted
            else { continue }
            let bsdName = String(entry.source.dropFirst("/dev/".count))
            guard
                let disk = bsdName.withCString({
                    DADiskCreateFromBSDName(kCFAllocatorDefault, session, $0)
                }), let description = DADiskCopyDescription(disk) as NSDictionary?
            else { continue }

            let uuid: UUID?
            if let rawValue = description.object(forKey: kDADiskDescriptionVolumeUUIDKey),
                CFGetTypeID(rawValue as CFTypeRef) == CFUUIDGetTypeID()
            {
                let value = rawValue as! CFUUID
                uuid = UUID(uuidString: CFUUIDCreateString(kCFAllocatorDefault, value) as String)
            } else {
                uuid = nil
            }
            result.append(
                MountedVolumeDescription(
                    bsdName: bsdName,
                    mountPath: entry.mountPath,
                    filesystemKind: entry.filesystemKind,
                    volumeUUID: uuid,
                    deviceID: entry.deviceID,
                    isInternal: description.bool(for: kDADiskDescriptionDeviceInternalKey) ?? false,
                    isRemovable: description.bool(for: kDADiskDescriptionMediaRemovableKey) ?? true,
                    isReadOnly: entry.isReadOnly
                )
            )
        }
        return result
    }
}

struct MountedFileSystem {
    let source: String
    let mountPath: String
    let filesystemKind: String
    let deviceID: UInt64
    let isReadOnly: Bool
}

func mountedFileSystems() throws -> [MountedFileSystem] {
    let count = getfsstat(nil, 0, MNT_NOWAIT)
    guard count >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var entries = Array(repeating: statfs(), count: Int(count))
    let bufferSize = Int32(entries.count * MemoryLayout<statfs>.stride)
    let actual = entries.withUnsafeMutableBufferPointer {
        getfsstat($0.baseAddress, bufferSize, MNT_NOWAIT)
    }
    guard actual >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    return entries.prefix(Int(actual)).compactMap { rawEntry in
        var entry = rawEntry
        let source = tupleString(&entry.f_mntfromname)
        let mountPath = tupleString(&entry.f_mntonname)
        let filesystemKind = tupleString(&entry.f_fstypename)
        guard !source.isEmpty, !mountPath.isEmpty else { return nil }
        var status = Darwin.stat()
        guard lstat(mountPath, &status) == 0 else { return nil }
        return MountedFileSystem(
            source: source,
            mountPath: mountPath,
            filesystemKind: filesystemKind,
            deviceID: UInt64(UInt32(bitPattern: status.st_dev)),
            isReadOnly: (entry.f_flags & UInt32(MNT_RDONLY)) != 0
        )
    }
}

private func tupleString<T>(_ tuple: inout T) -> String {
    withUnsafePointer(to: &tuple) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
            String(cString: $0)
        }
    }
}

extension NSDictionary {
    fileprivate func string(for key: CFString) -> String? {
        object(forKey: key) as? String
    }

    fileprivate func bool(for key: CFString) -> Bool? {
        (object(forKey: key) as? NSNumber)?.boolValue
    }
}
