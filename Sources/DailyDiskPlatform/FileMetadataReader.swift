import DailyDiskCore
import Darwin
import Foundation

public actor POSIXFileMetadataReader: FileMetadataReading {
    private let diskArbitration: any DiskArbitrationProviding
    private let managedAbsolutePaths: [String]

    public init(
        diskArbitration: any DiskArbitrationProviding = SystemDiskArbitrationAdapter(),
        managedAbsolutePaths: [String] = FileInventoryScannerConfiguration.defaultManagedPaths
    ) {
        self.diskArbitration = diskArbitration
        self.managedAbsolutePaths = managedAbsolutePaths
    }

    public func read(volume: MonitoredVolume, path: RelativePath) async throws -> FileMetadataReadResult {
        guard volume.inventoryMode == .full,
            let mountPath = volume.mountPath,
            let filesystemUUID = volume.filesystemUUID,
            volume.deviceID != 0
        else {
            throw FileMetadataReaderError.invalidVolume(volume.id)
        }
        let mounts = try await diskArbitration.mountedVolumes()
        guard let mount = mounts.first(where: { $0.mountPath == mountPath }),
            mount.filesystemKind?.lowercased() == "apfs",
            mount.isInternal,
            !mount.isRemovable,
            mount.volumeUUID == filesystemUUID,
            mount.deviceID == volume.deviceID
        else {
            throw FileMetadataReaderError.mountIdentityMismatch(volume.id)
        }
        let excludedRoots = try makeExcludedRoots(volume: volume, mountPath: mountPath)
        if excludedRoots.contains(where: { PathPolicy.isEqual(path, orDescendantOf: $0) }) {
            return .excluded
        }

        let rootPath = FileManager.default.fileSystemRepresentation(withPath: mountPath)
        var currentFD = retryInterruptedPOSIX { open(rootPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
        guard currentFD >= 0 else {
            throw FileMetadataReaderError.posix(code: errno, path: path)
        }
        defer { close(currentFD) }

        var status = Darwin.stat()
        if path == .root {
            guard retryInterruptedPOSIX({ fstat(currentFD, &status) }) == 0 else {
                throw FileMetadataReaderError.posix(code: errno, path: path)
            }
        } else {
            let components = path.bytes.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
            for component in components.dropLast() {
                let nextFD = withMetadataCString(Data(component)) { pointer in
                    retryInterruptedPOSIX {
                        openat(currentFD, pointer, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                    }
                }
                guard nextFD >= 0 else {
                    return try handleMissingOrThrow(code: errno, path: path)
                }
                var openedStatus = Darwin.stat()
                var currentStatus = Darwin.stat()
                let openedResult = retryInterruptedPOSIX { fstat(nextFD, &openedStatus) }
                let currentResult = withMetadataCString(Data(component)) { pointer in
                    retryInterruptedPOSIX { fstatat(currentFD, pointer, &currentStatus, AT_SYMLINK_NOFOLLOW) }
                }
                guard openedResult == 0, currentResult == 0,
                    metadataFileKind(openedStatus.st_mode) == .directory,
                    metadataFileKind(currentStatus.st_mode) == .directory,
                    openedStatus.st_dev == currentStatus.st_dev,
                    openedStatus.st_ino == currentStatus.st_ino
                else {
                    close(nextFD)
                    throw FileMetadataReaderError.pathIdentityChanged(path)
                }
                close(currentFD)
                currentFD = nextFD
            }
            guard let final = components.last else { return .missing }
            let result = withMetadataCString(Data(final)) { pointer in
                retryInterruptedPOSIX { fstatat(currentFD, pointer, &status, AT_SYMLINK_NOFOLLOW) }
            }
            guard result == 0 else {
                return try handleMissingOrThrow(code: errno, path: path)
            }
        }

        guard UInt64(status.st_dev) == volume.deviceID else {
            throw FileMetadataReaderError.crossedVolumeBoundary(path)
        }
        guard status.st_size >= 0, status.st_blocks >= 0 else {
            throw FileMetadataReaderError.invalidMetadata(path)
        }
        let metadata = try InventoryMetadata(
            deviceID: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            kind: metadataFileKind(status.st_mode),
            logicalBytes: status.st_size,
            allocatedBytes: AccountingMath.allocatedBytes(blockCount: status.st_blocks),
            linkCount: UInt64(status.st_nlink),
            modifiedAt: metadataDate(status.st_mtimespec),
            metadataChangedAt: metadataDate(status.st_ctimespec)
        )
        return .record(
            try InventoryBuilder.makeRecord(
                volumeID: volume.id,
                path: path,
                metadata: metadata,
                classification: .ordinary
            )
        )
    }

    private func handleMissingOrThrow(
        code: Int32,
        path: RelativePath
    ) throws -> FileMetadataReadResult {
        switch code {
        case ENOENT, ESTALE, ENOTDIR:
            return .missing
        case EDEADLK:
            return .unavailable(code: code)
        case EACCES, EPERM:
            return .inaccessible(code: code)
        default:
            throw FileMetadataReaderError.posix(code: code, path: path)
        }
    }

    private func makeExcludedRoots(
        volume: MonitoredVolume,
        mountPath: String
    ) throws -> Set<RelativePath> {
        let mountBytes = metadataFileSystemBytes(mountPath)
        var roots: Set<RelativePath> = []
        for absolutePath in managedAbsolutePaths {
            let absolute = metadataFileSystemBytes(absolutePath)
            let relative: Data?
            if absolute == mountBytes {
                relative = Data()
            } else if let descendant = metadataDescendantBytes(absolute, beneath: mountBytes) {
                relative = descendant
            } else if volume.role == .data,
                mountPath == "/System/Volumes/Data",
                absolute.first == UInt8(ascii: "/")
            {
                relative = Data(absolute.dropFirst())
            } else {
                relative = nil
            }
            if let relative { roots.insert(try RelativePath(validating: relative)) }
        }
        for mounted in try mountedFileSystems() {
            let absolute = metadataFileSystemBytes(mounted.mountPath)
            if let descendant = metadataDescendantBytes(absolute, beneath: mountBytes) {
                roots.insert(try RelativePath(validating: descendant))
            }
        }
        return roots
    }
}

public enum FileMetadataReaderError: Error, Equatable, Sendable {
    case invalidVolume(MonitoredVolume.ID)
    case mountIdentityMismatch(MonitoredVolume.ID)
    case crossedVolumeBoundary(RelativePath)
    case invalidMetadata(RelativePath)
    case pathIdentityChanged(RelativePath)
    case posix(code: Int32, path: RelativePath)
}

private func withMetadataCString<T>(
    _ data: Data,
    _ body: (UnsafePointer<CChar>) throws -> T
) rethrows -> T {
    var bytes = [UInt8](data)
    bytes.append(0)
    return try bytes.withUnsafeBufferPointer { buffer in
        try buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
            try body($0)
        }
    }
}

private func metadataFileSystemBytes(_ path: String) -> Data {
    let pointer = FileManager.default.fileSystemRepresentation(withPath: path)
    return Data(bytes: pointer, count: strlen(pointer))
}

private func metadataDescendantBytes(_ candidate: Data, beneath root: Data) -> Data? {
    if root == Data([0x2F]) {
        guard candidate.count > 1, candidate.first == 0x2F else { return nil }
        return Data(candidate.dropFirst())
    }
    guard candidate.count > root.count,
        candidate.starts(with: root),
        candidate[candidate.index(candidate.startIndex, offsetBy: root.count)] == 0x2F
    else { return nil }
    return Data(candidate.dropFirst(root.count + 1))
}

private func metadataFileKind(_ mode: mode_t) -> FileKind {
    switch mode & S_IFMT {
    case S_IFREG: .regular
    case S_IFDIR: .directory
    case S_IFLNK: .symbolicLink
    case S_IFSOCK: .socket
    case S_IFIFO: .fifo
    case S_IFCHR: .characterDevice
    case S_IFBLK: .blockDevice
    default: .unknown
    }
}

private func metadataDate(_ value: timespec) -> Date {
    Date(timeIntervalSince1970: Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000)
}
