import DailyDiskCore
import Darwin
import Foundation

/// Lock protects only bounded enqueue state; the serial utility queue owns disk I/O.
/// A single scheduled drain prevents an unbounded Dispatch/Task mailbox.
public final class ScanProbeLogger: ScanProbeRecording, @unchecked Sendable {
    private static let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-:"))
    private static let allowedFields: Set<String> = Set(
        [
            "present", "journalUUID", "cursor", "topology", "generation", "lastFullUnix", "volume", "domain",
            "volumeRole", "groupUUID", "filesystemUUID", "device", "nativeDevice", "inventoryMode", "expectedUUID",
            "since", "unixTime", "unixResult", "fallbackExecuted", "cfTime", "cfResult", "adopted", "trust",
            "callbacks", "received", "consumed", "buffered", "peak", "flags", "firstOverflowNanoseconds",
            "consumedBatches", "consumptionNanoseconds", "delivered", "boundary", "count", "failed",
            "elapsedNanoseconds",
            "oldLinks", "newLinks", "sameIdentity", "oldDevice", "newDevice", "oldInode", "newInode",
            "remainingAliases", "inode", "phase", "trigger", "publication", "interruptedRuns", "pendingReportRun",
            "selection", "intervalSeconds", "nowUnix", "lastPublishedFullUnix", "reasonCount", "firstReason",
            "cancelled", "failureType",
            "terminalState", "completedDomains", "failedDomains", "droppedDiagnostics", "writeFailures", "index",
        ] + (0..<24).map { "cause\($0)" })
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "DailyDisk.scan-probes", qos: .utility)
    private var pending: [(UInt64, ScanProbeEvent, UInt64?)] = []
    private var scheduled = false
    private var sequence: UInt64 = 0
    private var dropped: UInt64 = 0
    private var writeFailures: UInt64 = 0
    private var firstReasons: [UUID: UInt64] = [:]
    private let directory: URL
    private let capacity: Int
    private let fileLimit: Int
    private let fileCount: Int
    private let processID = UUID()
    private let started = DispatchTime.now().uptimeNanoseconds

    public init(
        directory: URL = StructuredLogger.defaultLogDirectory.appendingPathComponent("ScanProbes"),
        capacity: Int = 512, fileLimit: Int = 1_048_576, fileCount: Int = 20
    ) {
        precondition(capacity > 0 && fileLimit >= 1024 && fileCount > 0)
        self.directory = directory
        self.capacity = capacity
        self.fileLimit = fileLimit
        self.fileCount = fileCount
    }
    public func record(_ event: ScanProbeEvent) {
        lock.lock()
        defer { lock.unlock() }
        sequence &+= 1
        guard event.fields.count <= 32,
            event.fields.allSatisfy({ key, value in
                Self.allowedFields.contains(key) && value.count <= 160
                    && (key + value).unicodeScalars.allSatisfy {
                        Self.allowedCharacters.contains($0)
                    }
            })
        else {
            dropped &+= 1
            return
        }
        if pending.count == capacity {
            if event.critical, let index = pending.firstIndex(where: { !$0.1.critical }) {
                pending.remove(at: index)
            } else {
                dropped &+= 1
                return
            }
            dropped &+= 1
        }
        let measured: Bool = [.helperStarted, .helperFinished, .requestStarted, .requestFinished, .phaseChanged]
            .contains(event.name)
        pending.append((sequence, event, measured ? Self.processWriteBytes() : nil))
        if !scheduled {
            scheduled = true
            queue.async { self.drain() }
        }
    }
    public func flush() async {
        await barrier()
        let snapshot = statistics
        let observed = lock.withLock { sequence > 0 }
        if observed {
            ScanProbeContext(recorder: self).emit(
                .diagnosticSummary,
                fields: [
                    "droppedDiagnostics": String(snapshot.dropped), "writeFailures": String(snapshot.writeFailures),
                ])
            await barrier()
        }
    }
    private func barrier() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
    public var statistics: (dropped: UInt64, writeFailures: UInt64, queued: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (dropped, writeFailures, pending.count)
    }
    private struct Line: Encodable {
        let processID: UUID
        let sequence: UInt64
        let elapsedNanoseconds: UInt64
        let firstReasonSequence: UInt64?
        let droppedDiagnostics: UInt64
        let writeFailures: UInt64
        let event: ScanProbeEvent
        let processWriteBytes: UInt64?
    }
    private func drain() {
        while true {
            lock.lock()
            guard !pending.isEmpty else {
                scheduled = false
                lock.unlock()
                return
            }
            let (sequence, event, writes) = pending.removeFirst()
            let losses = dropped
            let failures = writeFailures
            lock.unlock()
            let key = event.attemptID ?? event.requestID
            if let key, event.reason != nil, firstReasons[key] == nil {
                if firstReasons.count >= 128 { firstReasons.removeAll(keepingCapacity: true) }
                firstReasons[key] = sequence
            }
            let line = Line(
                processID: processID, sequence: sequence,
                elapsedNanoseconds: event.monotonicNanoseconds >= started ? event.monotonicNanoseconds - started : 0,
                firstReasonSequence: key.flatMap { firstReasons[$0] },
                droppedDiagnostics: losses, writeFailures: failures, event: event, processWriteBytes: writes)
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(line) + Data([10])
                guard data.count <= fileLimit else { throw CocoaError(.fileWriteUnknown) }
                try write(data)
            } catch {
                lock.lock()
                writeFailures &+= 1
                lock.unlock()
            }
        }
    }
    private static func processWriteBytes() -> UInt64? {
        var info = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0)
            }
        }
        return status == 0 ? info.ri_diskio_byteswritten : nil
    }
    private func write(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
            info.st_uid == geteuid(), (info.st_mode & 0o077) == 0
        else { throw CocoaError(.fileWriteNoPermission) }
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(dir) }
        let active = "probe.0.jsonl"
        let fd = openat(dir, active, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        var closed = false
        defer { if !closed { close(fd) } }
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
            info.st_nlink == 1, info.st_uid == geteuid(), (info.st_mode & 0o077) == 0
        else { throw CocoaError(.fileWriteNoPermission) }
        if info.st_size + Int64(data.count) > fileLimit {
            close(fd)
            closed = true
            if fileCount > 1 {
                for index in stride(from: fileCount - 1, through: 1, by: -1) {
                    guard renameat(dir, "probe.\(index - 1).jsonl", dir, "probe.\(index).jsonl") == 0 || errno == ENOENT
                    else { throw CocoaError(.fileWriteUnknown) }
                }
            } else if unlinkat(dir, active, 0) != 0 {
                throw CocoaError(.fileWriteUnknown)
            }
            try write(data)
            return
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += count
            }
        }
    }
}
