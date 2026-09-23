import DailyDiskCore
import DailyDiskStore
import Darwin
import Foundation

public struct FileInventoryScannerConfiguration: Sendable {
    public let batchSize: Int
    public let managedAbsolutePaths: [String]
    public let maximumRecordedErrors: Int
    public let maximumUnreadablePaths: UInt64
    public let maximumUnreadableFraction: Double
    public let validateMountIdentity: Bool

    public init(
        batchSize: Int = 512,
        managedAbsolutePaths: [String] = FileInventoryScannerConfiguration.defaultManagedPaths,
        maximumRecordedErrors: Int = 10_000,
        maximumUnreadablePaths: UInt64 = 10_000,
        maximumUnreadableFraction: Double = 0.01,
        validateMountIdentity: Bool = true
    ) throws {
        guard batchSize > 0,
            batchSize <= InventoryRecordBatch.maximumRecordCount,
            maximumRecordedErrors > 0,
            maximumUnreadableFraction.isFinite,
            maximumUnreadableFraction >= 0,
            maximumUnreadableFraction <= 1
        else {
            throw FileInventoryScannerError.invalidConfiguration
        }
        self.batchSize = batchSize
        self.managedAbsolutePaths = managedAbsolutePaths
        self.maximumRecordedErrors = maximumRecordedErrors
        self.maximumUnreadablePaths = maximumUnreadablePaths
        self.maximumUnreadableFraction = maximumUnreadableFraction
        self.validateMountIdentity = validateMountIdentity
    }

    public static let `default` = try! FileInventoryScannerConfiguration()

    public static var defaultManagedPaths: [String] {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DailyDisk", isDirectory: true)
        return [root.path]
    }
}

public struct FileInventoryScanner: FileInventoryScanning {
    private let configuration: FileInventoryScannerConfiguration
    private let diskArbitration: any DiskArbitrationProviding

    public init(
        configuration: FileInventoryScannerConfiguration = .default,
        diskArbitration: any DiskArbitrationProviding = SystemDiskArbitrationAdapter()
    ) {
        self.configuration = configuration
        self.diskArbitration = diskArbitration
    }

    public func scan(
        volume: MonitoredVolume,
        runID: ScanRun.ID,
        consume: @escaping @Sendable (InventoryRecordBatch) async throws -> Void
    ) async throws -> InventoryScanResult {
        try await scan(
            volume: volume,
            runID: runID,
            observer: TaskOnlyScanWorkObserver(),
            consume: consume
        )
    }

    public func scan(
        volume: MonitoredVolume,
        runID: ScanRun.ID,
        observer: any ScanWorkObserving,
        consume: @escaping @Sendable (InventoryRecordBatch) async throws -> Void
    ) async throws -> InventoryScanResult {
        try await scanInternal(
            volume: volume,
            root: .root,
            runID: runID,
            observer: observer,
            consume: consume
        )
    }

    public func scanSubtree(
        volume: MonitoredVolume,
        root: RelativePath,
        runID: ScanRun.ID,
        consume: @escaping @Sendable (InventoryRecordBatch) async throws -> Void
    ) async throws -> InventoryScanResult {
        try await scanSubtree(
            volume: volume,
            root: root,
            runID: runID,
            observer: TaskOnlyScanWorkObserver(),
            consume: consume
        )
    }

    public func scanSubtree(
        volume: MonitoredVolume,
        root: RelativePath,
        runID: ScanRun.ID,
        observer: any ScanWorkObserving,
        consume: @escaping @Sendable (InventoryRecordBatch) async throws -> Void
    ) async throws -> InventoryScanResult {
        try await scanInternal(
            volume: volume,
            root: root,
            runID: runID,
            observer: observer,
            consume: consume
        )
    }

    private func scanInternal(
        volume: MonitoredVolume,
        root: RelativePath,
        runID: ScanRun.ID,
        observer: any ScanWorkObserving,
        consume: @escaping @Sendable (InventoryRecordBatch) async throws -> Void
    ) async throws -> InventoryScanResult {
        try await observer.checkpoint()
        guard volume.inventoryMode == .full else {
            throw FileInventoryScannerError.volumeIsMetricsOnly(volume.id)
        }
        guard let mountPath = volume.mountPath, mountPath.hasPrefix("/") else {
            throw FileInventoryScannerError.missingMountPath(volume.id)
        }
        if configuration.validateMountIdentity {
            let mounted = try await diskArbitration.mountedVolumes()
            guard let filesystemUUID = volume.filesystemUUID,
                volume.deviceID != 0,
                let match = mounted.first(where: { $0.mountPath == mountPath }),
                match.filesystemKind?.lowercased() == "apfs",
                match.isInternal,
                !match.isRemovable,
                match.deviceID == volume.deviceID,
                match.volumeUUID == filesystemUUID
            else {
                throw FileInventoryScannerError.mountIdentityMismatch(volume.id)
            }
        }
        let boundaryRoots = try nestedMountRoots(beneath: mountPath)
        let excludedRoots = try managedRoots(for: volume, mountPath: mountPath).union(boundaryRoots)
        if excludedRoots.contains(where: { PathPolicy.isEqual(root, orDescendantOf: $0) }) {
            return InventoryScanResult(
                coverage: ScanCoverage(
                    visitedPathCount: 0,
                    indexedObjectCount: 0,
                    unreadablePathCount: 0,
                    transientErrorCount: 0
                ),
                errors: []
            )
        }

        let walker = try ScannerWalker(
            volume: volume,
            runID: runID,
            configuration: configuration,
            excludedRoots: excludedRoots,
            observer: observer,
            consume: consume
        )
        return try await walker.scan(mountPath: mountPath, startingAt: root)
    }

    private func managedRoots(
        for volume: MonitoredVolume,
        mountPath: String
    ) throws -> Set<RelativePath> {
        let mountBytes = fileSystemBytes(mountPath)
        var roots: Set<RelativePath> = []
        for absolutePath in configuration.managedAbsolutePaths {
            let absoluteBytes = fileSystemBytes(absolutePath)
            let relativeBytes: Data?
            if absoluteBytes == mountBytes {
                relativeBytes = Data()
            } else if let relative = descendantBytes(absoluteBytes, beneath: mountBytes) {
                relativeBytes = relative
            } else if volume.role == .data,
                mountPath == "/System/Volumes/Data",
                absoluteBytes.first == UInt8(ascii: "/")
            {
                relativeBytes = Data(absoluteBytes.dropFirst())
            } else {
                relativeBytes = nil
            }
            if let relativeBytes {
                do {
                    roots.insert(try RelativePath(validating: relativeBytes))
                } catch {
                    throw FileInventoryScannerError.invalidManagedPath(absolutePath)
                }
            }
        }
        return roots
    }

    private func nestedMountRoots(beneath mountPath: String) throws -> Set<RelativePath> {
        let mountBytes = fileSystemBytes(mountPath)
        let fileSystems = try mountedFileSystems()
        var result: Set<RelativePath> = []
        for entry in fileSystems {
            let candidate = fileSystemBytes(entry.mountPath)
            guard candidate != mountBytes,
                let relative = descendantBytes(candidate, beneath: mountBytes)
            else { continue }
            do {
                result.insert(try RelativePath(validating: relative))
            } catch {
                throw FileInventoryScannerError.invalidMountBoundary(entry.mountPath)
            }
        }
        return result
    }
}

public enum FileInventoryScannerError: Error, Sendable {
    case invalidConfiguration
    case volumeIsMetricsOnly(MonitoredVolume.ID)
    case missingMountPath(MonitoredVolume.ID)
    case mountIdentityMismatch(MonitoredVolume.ID)
    case invalidManagedPath(String)
    case invalidMountBoundary(String)
    case rootOpenFailed(path: String, code: Int32)
    case rootMetadataFailed(path: String, code: Int32)
    case rootDeviceMismatch(expected: UInt64, actual: UInt64)
    case subtreeOpenFailed(path: RelativePath, code: Int32)
    case subtreeIdentityChanged(RelativePath)
    case incomplete(InventoryScanResult)
}

private final class ScannerWalker: @unchecked Sendable {
    private let volume: MonitoredVolume
    private let runID: ScanRun.ID
    private let configuration: FileInventoryScannerConfiguration
    private let excludedRoots: Set<RelativePath>
    private let observer: any ScanWorkObserving
    private let consume: @Sendable (InventoryRecordBatch) async throws -> Void

    private var pendingRecords: [InventoryRecord] = []
    private var errors: [ScanErrorRecord] = []
    private let objectCounter: TemporaryIdentityCounter
    private var visitedPathCount: UInt64 = 0
    private var unreadablePathCount: UInt64 = 0
    private var transientErrorCount: UInt64 = 0
    private var hardFailureCount: UInt64 = 0
    private var omittedErrorCount: UInt64 = 0
    private var rootDeviceID: UInt64 = 0
    private var reportedVisitedPathCount: UInt64 = 0
    private var reportedIndexedObjectCount: UInt64 = 0
    private var reportedUnreadablePathCount: UInt64 = 0
    private var reportedTransientErrorCount: UInt64 = 0

    init(
        volume: MonitoredVolume,
        runID: ScanRun.ID,
        configuration: FileInventoryScannerConfiguration,
        excludedRoots: Set<RelativePath>,
        observer: any ScanWorkObserving,
        consume: @escaping @Sendable (InventoryRecordBatch) async throws -> Void
    ) throws {
        objectCounter = try TemporaryIdentityCounter()
        self.volume = volume
        self.runID = runID
        self.configuration = configuration
        self.excludedRoots = excludedRoots
        self.observer = observer
        self.consume = consume
        pendingRecords.reserveCapacity(configuration.batchSize)
    }

    func scan(mountPath: String, startingAt startingPath: RelativePath) async throws -> InventoryScanResult {
        try await observer.checkpoint()
        let path = FileManager.default.fileSystemRepresentation(withPath: mountPath)
        let rootFD = retryInterruptedPOSIX { open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
        guard rootFD >= 0 else {
            throw FileInventoryScannerError.rootOpenFailed(path: mountPath, code: errno)
        }
        defer { close(rootFD) }

        var rootStatus = Darwin.stat()
        guard retryInterruptedPOSIX({ fstat(rootFD, &rootStatus) }) == 0 else {
            throw FileInventoryScannerError.rootMetadataFailed(path: mountPath, code: errno)
        }
        rootDeviceID = UInt64(rootStatus.st_dev)
        guard volume.deviceID != 0, volume.deviceID == rootDeviceID else {
            throw FileInventoryScannerError.rootDeviceMismatch(expected: volume.deviceID, actual: rootDeviceID)
        }

        if startingPath == .root {
            try increment(&visitedPathCount)
            try await appendRecord(path: .root, status: rootStatus)
            try await walkDirectory(fileDescriptor: rootFD, relativePath: .root)
        } else {
            let opened = try openSubtree(rootFileDescriptor: rootFD, path: startingPath)
            defer { close(opened.fileDescriptor) }
            try increment(&visitedPathCount)
            try await appendRecord(path: startingPath, status: opened.status)
            try await walkDirectory(fileDescriptor: opened.fileDescriptor, relativePath: startingPath)
        }
        try await flush()
        try await reportProgress()

        if omittedErrorCount > 0 {
            if errors.count == configuration.maximumRecordedErrors {
                errors.removeLast()
            }
            errors.append(
                ScanErrorRecord(
                    runID: runID,
                    volumeID: volume.id,
                    kind: .other,
                    path: nil,
                    errorCode: nil,
                    message: "\(omittedErrorCount + 1) scan errors were omitted"
                )
            )
        }

        let result = InventoryScanResult(
            coverage: ScanCoverage(
                visitedPathCount: visitedPathCount,
                indexedObjectCount: objectCounter.count,
                unreadablePathCount: unreadablePathCount,
                transientErrorCount: transientErrorCount
            ),
            errors: errors
        )
        let unreadableFraction =
            visitedPathCount == 0
            ? 0
            : Double(unreadablePathCount) / Double(visitedPathCount)
        if hardFailureCount > 0
            || unreadablePathCount > configuration.maximumUnreadablePaths
            || unreadableFraction > configuration.maximumUnreadableFraction
        {
            throw FileInventoryScannerError.incomplete(result)
        }
        return result
    }

    private func openSubtree(
        rootFileDescriptor: Int32,
        path: RelativePath
    ) throws -> (fileDescriptor: Int32, status: Darwin.stat) {
        var currentFD = retryInterruptedPOSIX { dup(rootFileDescriptor) }
        guard currentFD >= 0 else {
            throw FileInventoryScannerError.subtreeOpenFailed(path: path, code: errno)
        }
        do {
            for component in path.bytes.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false) {
                let nextFD = withNullTerminatedBytes(Data(component)) { pointer in
                    retryInterruptedPOSIX {
                        openat(currentFD, pointer, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                    }
                }
                guard nextFD >= 0 else {
                    throw FileInventoryScannerError.subtreeOpenFailed(path: path, code: errno)
                }
                var openedStatus = Darwin.stat()
                var currentStatus = Darwin.stat()
                let openedResult = retryInterruptedPOSIX { fstat(nextFD, &openedStatus) }
                let currentResult = withNullTerminatedBytes(Data(component)) { pointer in
                    retryInterruptedPOSIX { fstatat(currentFD, pointer, &currentStatus, AT_SYMLINK_NOFOLLOW) }
                }
                guard openedResult == 0, currentResult == 0,
                    fileKind(openedStatus.st_mode) == .directory,
                    fileKind(currentStatus.st_mode) == .directory,
                    openedStatus.st_dev == currentStatus.st_dev,
                    openedStatus.st_ino == currentStatus.st_ino
                else {
                    close(nextFD)
                    throw FileInventoryScannerError.subtreeIdentityChanged(path)
                }
                close(currentFD)
                currentFD = nextFD
            }
            var status = Darwin.stat()
            guard retryInterruptedPOSIX({ fstat(currentFD, &status) }) == 0, UInt64(status.st_dev) == rootDeviceID
            else {
                throw FileInventoryScannerError.subtreeIdentityChanged(path)
            }
            return (currentFD, status)
        } catch {
            close(currentFD)
            throw error
        }
    }

    private func walkDirectory(fileDescriptor: Int32, relativePath: RelativePath) async throws {
        let duplicate = retryInterruptedPOSIX { dup(fileDescriptor) }
        guard duplicate >= 0 else {
            try recordError(code: errno, path: relativePath)
            return
        }
        guard let directory = fdopendir(duplicate) else {
            let code = errno
            close(duplicate)
            try recordError(code: code, path: relativePath)
            return
        }
        defer { closedir(directory) }

        while true {
            try await reportProgress()
            let chunk: DirectoryEntryChunk
            do {
                chunk = try readDirectoryChunk(directory: directory, limit: 1_024)
            } catch let error as DirectoryReadError {
                try recordError(code: error.code, path: relativePath)
                return
            }
            for name in chunk.entries {
                try await processEntry(
                    name: name,
                    parentFileDescriptor: fileDescriptor,
                    parentPath: relativePath
                )
            }
            try await reportProgress()
            if chunk.reachedEnd { return }
        }
    }

    private func processEntry(
        name: Data,
        parentFileDescriptor: Int32,
        parentPath: RelativePath
    ) async throws {
        let childPath = try PathPolicy.appending(componentBytes: name, to: parentPath)
        try increment(&visitedPathCount)
        if visitedPathCount.isMultiple(of: 128) {
            try await reportProgress()
        }
        if excludedRoots.contains(where: { PathPolicy.isEqual(childPath, orDescendantOf: $0) }) {
            return
        }

        var observedStatus = Darwin.stat()
        let metadataResult = withNullTerminatedBytes(name) { pointer in
            retryInterruptedPOSIX { fstatat(parentFileDescriptor, pointer, &observedStatus, AT_SYMLINK_NOFOLLOW) }
        }
        guard metadataResult == 0 else {
            try recordError(code: errno, path: childPath)
            return
        }

        if fileKind(observedStatus.st_mode) != .directory {
            guard try validateDevice(observedStatus, path: childPath) else { return }
            try await appendRecord(path: childPath, status: observedStatus)
            return
        }

        // A disk inventory must not download cloud directory contents just to measure them.
        if observedStatus.st_flags & UInt32(SF_DATALESS) != 0 {
            if try validateDevice(observedStatus, path: childPath) {
                try await appendRecord(path: childPath, status: observedStatus)
            }
            try recordError(code: EDEADLK, path: childPath)
            return
        }
        let childFD = withNullTerminatedBytes(name) { pointer in
            retryInterruptedPOSIX {
                openat(parentFileDescriptor, pointer, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
        }
        guard childFD >= 0 else {
            let openError = errno
            if try validateDevice(observedStatus, path: childPath) {
                try await appendRecord(path: childPath, status: observedStatus)
            }
            try recordError(code: openError, path: childPath)
            return
        }
        defer { close(childFD) }

        var openedStatus = Darwin.stat()
        var currentStatus = Darwin.stat()
        let openedResult = retryInterruptedPOSIX { fstat(childFD, &openedStatus) }
        let currentResult = withNullTerminatedBytes(name) { pointer in
            retryInterruptedPOSIX { fstatat(parentFileDescriptor, pointer, &currentStatus, AT_SYMLINK_NOFOLLOW) }
        }
        guard openedResult == 0, currentResult == 0 else {
            try recordError(code: errno, path: childPath)
            return
        }
        guard fileKind(openedStatus.st_mode) == .directory,
            fileKind(currentStatus.st_mode) == .directory,
            openedStatus.st_dev == currentStatus.st_dev,
            openedStatus.st_ino == currentStatus.st_ino
        else {
            try increment(&transientErrorCount)
            try appendError(
                kind: .disappearedDuringScan,
                code: nil,
                path: childPath,
                message: "Directory identity changed while opening it"
            )
            return
        }
        guard try validateDevice(openedStatus, path: childPath) else { return }
        try await appendRecord(path: childPath, status: openedStatus)
        try await walkDirectory(fileDescriptor: childFD, relativePath: childPath)
    }

    private func validateDevice(_ status: Darwin.stat, path: RelativePath) throws -> Bool {
        let deviceID = UInt64(status.st_dev)
        guard deviceID == rootDeviceID else {
            try appendError(
                kind: .crossedVolumeBoundary,
                code: nil,
                path: path,
                message: "Skipped nested filesystem device \(deviceID)"
            )
            return false
        }
        return true
    }

    private func appendRecord(path: RelativePath, status: Darwin.stat) async throws {
        guard status.st_size >= 0, status.st_blocks >= 0 else {
            try increment(&unreadablePathCount)
            try increment(&hardFailureCount)
            try appendError(
                kind: .invalidMetadata,
                code: nil,
                path: path,
                message: "Negative size or block count"
            )
            return
        }
        let metadata = try InventoryMetadata(
            deviceID: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            kind: fileKind(status.st_mode),
            logicalBytes: status.st_size,
            allocatedBytes: AccountingMath.allocatedBytes(blockCount: status.st_blocks),
            linkCount: UInt64(status.st_nlink),
            modifiedAt: date(status.st_mtimespec),
            metadataChangedAt: date(status.st_ctimespec)
        )
        let record = try InventoryBuilder.makeRecord(
            volumeID: volume.id,
            path: path,
            metadata: metadata,
            classification: .ordinary
        )
        try objectCounter.register(record.object.identity)
        pendingRecords.append(record)
        if pendingRecords.count >= configuration.batchSize {
            try await flush()
        }
    }

    private func flush() async throws {
        guard !pendingRecords.isEmpty else { return }
        let batch = try InventoryRecordBatch(records: pendingRecords)
        pendingRecords.removeAll(keepingCapacity: true)
        try await consume(batch)
        try await reportProgress()
    }

    private func reportProgress() async throws {
        let delta = ScanProgressDelta(
            visitedPaths: visitedPathCount - reportedVisitedPathCount,
            indexedObjects: objectCounter.count - reportedIndexedObjectCount,
            unreadablePaths: unreadablePathCount - reportedUnreadablePathCount,
            transientErrors: transientErrorCount - reportedTransientErrorCount
        )
        try await observer.checkpoint(delta)
        reportedVisitedPathCount = visitedPathCount
        reportedIndexedObjectCount = objectCounter.count
        reportedUnreadablePathCount = unreadablePathCount
        reportedTransientErrorCount = transientErrorCount
    }

    private func recordError(code: Int32, path: RelativePath) throws {
        let kind: ScanErrorRecord.Kind
        switch code {
        case EDEADLK:
            kind = .contentUnavailable
            try increment(&unreadablePathCount)
        case EACCES, EPERM:
            kind = .permissionDenied
            try increment(&unreadablePathCount)
        case ENOENT, ESTALE:
            kind = .disappearedDuringScan
            try increment(&transientErrorCount)
        default:
            kind = .other
            try increment(&unreadablePathCount)
            try increment(&hardFailureCount)
        }
        try appendError(
            kind: kind,
            code: code,
            path: path,
            message: String(cString: strerror(code))
        )
    }

    private func appendError(
        kind: ScanErrorRecord.Kind,
        code: Int32?,
        path: RelativePath?,
        message: String
    ) throws {
        if errors.count < configuration.maximumRecordedErrors {
            errors.append(
                ScanErrorRecord(
                    runID: runID,
                    volumeID: volume.id,
                    kind: kind,
                    path: path,
                    errorCode: code,
                    message: message
                )
            )
        } else {
            try increment(&omittedErrorCount)
        }
    }

    private func increment(_ value: inout UInt64) throws {
        let (next, overflow) = value.addingReportingOverflow(1)
        guard !overflow else {
            throw AccountingError.overflow(operation: "scan counter + 1")
        }
        value = next
    }
}

private struct DirectoryReadError: Error {
    let code: Int32
}

private struct DirectoryEntryChunk {
    let entries: [Data]
    let reachedEnd: Bool
}

private func readDirectoryChunk(
    directory: UnsafeMutablePointer<DIR>,
    limit: Int
) throws -> DirectoryEntryChunk {
    var result: [Data] = []
    result.reserveCapacity(limit)
    var interruptedRetries = 0
    while result.count < limit {
        errno = 0
        guard let entry = readdir(directory) else {
            if errno == EINTR, interruptedRetries < 8 {
                interruptedRetries += 1
                continue
            }
            if errno != 0 { throw DirectoryReadError(code: errno) }
            result.sort { $0.lexicographicallyPrecedes($1) }
            return DirectoryEntryChunk(entries: result, reachedEnd: true)
        }
        interruptedRetries = 0
        let length = Int(entry.pointee.d_namlen)
        var nameTuple = entry.pointee.d_name
        let name = withUnsafePointer(to: &nameTuple) { pointer in
            Data(bytes: pointer, count: length)
        }
        if name != Data(".".utf8), name != Data("..".utf8) {
            result.append(name)
        }
    }
    result.sort { $0.lexicographicallyPrecedes($1) }
    return DirectoryEntryChunk(entries: result, reachedEnd: false)
}

private func withNullTerminatedBytes<T>(
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

private func fileSystemBytes(_ path: String) -> Data {
    let pointer = FileManager.default.fileSystemRepresentation(withPath: path)
    return Data(bytes: pointer, count: strlen(pointer))
}

private func descendantBytes(_ candidate: Data, beneath root: Data) -> Data? {
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

private func fileKind(_ mode: mode_t) -> FileKind {
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

private func date(_ value: timespec) -> Date {
    Date(
        timeIntervalSince1970: Double(value.tv_sec)
            + Double(value.tv_nsec) / 1_000_000_000
    )
}

extension FileInventoryScannerError: InventoryScanFailure {
    public var scanFailureRecords: [ScanErrorRecord] {
        if case .incomplete(let result) = self { return result.errors }
        return []
    }
}
