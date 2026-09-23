import DailyDiskCore
import Darwin
import Foundation

public actor RunControlStore: ScanProgressReporting, ScanCancellationChecking, ScanCommitBoundaryEntering,
    ScanRunBindingRecording
{
    public static var defaultRootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DailyDisk/Control", isDirectory: true)
    }

    private enum FileName: String, CaseIterable {
        case pending = "pending-request.json"
        case active = "active-request.json"
        case progress = "progress.json"
        case runBinding = "run-binding.json"
        case cancellation = "cancel-request.json"
        case summary = "summary.json"
        case helperIdle = "helper-idle.json"
        case lock = ".control.lock"
    }

    private let rootURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lockFileDescriptor: Int32
    private var lastPublishError: RunControlStoreError?

    public init(rootURL: URL = RunControlStore.defaultRootURL) throws {
        self.rootURL = rootURL.standardizedFileURL
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        try Self.prepareRoot(self.rootURL)
        let lockURL = self.rootURL.appendingPathComponent(FileName.lock.rawValue)
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw RunControlStoreError.posix(code: errno)
        }
        var lockStatus = Darwin.stat()
        guard fstat(descriptor, &lockStatus) == 0 else {
            let code = errno
            close(descriptor)
            throw RunControlStoreError.posix(code: code)
        }
        guard lockStatus.st_uid == getuid(),
            lockStatus.st_mode & S_IFMT == S_IFREG,
            lockStatus.st_nlink == 1
        else {
            close(descriptor)
            throw RunControlStoreError.unsafeControlFile
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            let code = errno
            close(descriptor)
            throw RunControlStoreError.posix(code: code)
        }
        guard fstat(descriptor, &lockStatus) == 0,
            lockStatus.st_mode & 0o077 == 0
        else {
            close(descriptor)
            throw RunControlStoreError.unsafeControlFile
        }
        lockFileDescriptor = descriptor
    }

    deinit {
        close(lockFileDescriptor)
    }

    public func clearHelperIdle() async throws {
        try withLock {
            try validateRoot()
            try removeIfPresent(.helperIdle)
            try syncDirectory()
        }
    }

    public func markHelperIdleIfNoPendingRequest(
        processID: Int32 = getpid()
    ) async throws -> Bool {
        try withLock {
            try validateRoot()
            guard !fileExists(.pending) else { return false }
            try write(
                HelperIdleState(processID: processID),
                to: .helperIdle,
                allowedKeys: Self.helperIdleKeys
            )
            return true
        }
    }

    public func helperIsIdle(processID: Int32? = nil) async throws -> Bool {
        try withLock {
            try validateRoot()
            guard
                let state = try readIfPresent(
                    HelperIdleState.self,
                    from: .helperIdle,
                    allowedKeys: Self.helperIdleKeys
                )
            else { return false }
            return processID == nil || state.processID == processID
        }
    }

    public func enqueue(_ request: DailyDiskRunRequest) async throws {
        try withLock {
            try validateRoot()
            if fileExists(.active) { throw RunControlStoreError.runAlreadyActive }
            if fileExists(.pending) { throw RunControlStoreError.requestAlreadyPending }
            try removeIfPresent(.cancellation)
            try removeIfPresent(.runBinding)
            try removeIfPresent(.summary)
            try write(request, to: .pending, allowedKeys: Self.requestKeys)
            let queued = try ScanProgressSnapshot(
                requestID: request.requestID,
                trigger: .manual,
                mode: nil,
                phase: .queued,
                startedAt: request.createdAt,
                updatedAt: request.createdAt
            )
            try write(queued, to: .progress, allowedKeys: Self.progressKeys)
        }
    }

    /// Called only by the scheduled worker after acquiring the database writer lease.
    /// Scheduled work uses the same private progress/cancellation channel as a manual run.
    public func beginScheduledRun(_ request: DailyDiskRunRequest) async throws {
        try withLock {
            try validateRoot()
            guard !fileExists(.active), !fileExists(.pending) else {
                throw RunControlStoreError.runAlreadyActive
            }
            try removeIfPresent(.summary)
            try removeIfPresent(.cancellation)
            try removeIfPresent(.runBinding)
            // Publish identity before the active marker. A later manual enqueue can
            // safely replace this snapshot if the process dies before claiming it.
            try write(
                ScanProgressSnapshot(
                    requestID: request.requestID, trigger: .scheduled, mode: nil,
                    phase: .queued, startedAt: request.createdAt, updatedAt: request.createdAt
                ),
                to: .progress, allowedKeys: Self.progressKeys
            )
            try write(request, to: .active, allowedKeys: Self.requestKeys)
        }
    }

    public func claimPendingRequest() async throws -> DailyDiskRunRequest? {
        try withLock {
            try validateRoot()
            if fileExists(.active) { throw RunControlStoreError.runAlreadyActive }
            guard fileExists(.pending) else { return nil }
            let request: DailyDiskRunRequest
            do {
                request = try read(
                    DailyDiskRunRequest.self,
                    from: .pending,
                    allowedKeys: Self.requestKeys
                )
            } catch {
                try? removeIfPresent(.pending)
                throw error
            }
            let pendingURL = url(for: .pending)
            let activeURL = url(for: .active)
            guard rename(pendingURL.path, activeURL.path) == 0 else {
                throw RunControlStoreError.posix(code: errno)
            }
            try syncDirectory()
            return request
        }
    }

    public func activeRequest() async throws -> DailyDiskRunRequest? {
        try withLock {
            try validateRoot()
            return try readIfPresent(
                DailyDiskRunRequest.self,
                from: .active,
                allowedKeys: Self.requestKeys
            )
        }
    }

    public func pendingRequest() async throws -> DailyDiskRunRequest? {
        try withLock {
            try validateRoot()
            return try readIfPresent(
                DailyDiskRunRequest.self,
                from: .pending,
                allowedKeys: Self.requestKeys
            )
        }
    }

    public func publish(_ snapshot: ScanProgressSnapshot) async {
        do {
            try withLock {
                try validateRoot()
                let request = try read(
                    DailyDiskRunRequest.self,
                    from: .active,
                    allowedKeys: Self.requestKeys
                )
                guard request.requestID == snapshot.requestID else {
                    throw RunControlStoreError.requestIDMismatch
                }
                if let previous = try readIfPresent(
                    ScanProgressSnapshot.self,
                    from: .progress,
                    allowedKeys: Self.progressKeys
                ) {
                    guard previous.requestID == snapshot.requestID,
                        Self.progressIdentityIsContinuous(previous, snapshot),
                        previous.updatedAt <= snapshot.updatedAt,
                        Self.countersAreMonotonic(previous.counters, snapshot.counters),
                        ScanProgressTransitionValidator.canTransition(
                            from: previous.phase,
                            to: snapshot.phase
                        )
                    else {
                        throw RunControlStoreError.invalidProgressTransition
                    }
                }
                try write(snapshot, to: .progress, allowedKeys: Self.progressKeys)
                lastPublishError = nil
            }
        } catch let error as RunControlStoreError {
            lastPublishError = error
        } catch {
            lastPublishError = .unexpectedJSONShape
        }
    }

    public func enterCommitBoundary(_ snapshot: ScanProgressSnapshot) async throws {
        guard snapshot.phase == .committing else {
            throw RunControlStoreError.invalidProgressTransition
        }
        try withLock {
            try validateRoot()
            let active = try read(
                DailyDiskRunRequest.self,
                from: .active,
                allowedKeys: Self.requestKeys
            )
            guard active.requestID == snapshot.requestID else {
                throw RunControlStoreError.requestIDMismatch
            }
            if let cancellation = try readIfPresent(
                DailyDiskCancelRequest.self,
                from: .cancellation,
                allowedKeys: Self.cancellationKeys
            ) {
                guard cancellation.requestID == active.requestID else {
                    throw RunControlStoreError.requestIDMismatch
                }
                throw ScanProgressError.cancelled
            }
            let previous = try read(
                ScanProgressSnapshot.self,
                from: .progress,
                allowedKeys: Self.progressKeys
            )
            guard previous.requestID == snapshot.requestID,
                Self.progressIdentityIsContinuous(previous, snapshot),
                previous.updatedAt <= snapshot.updatedAt,
                Self.countersAreMonotonic(previous.counters, snapshot.counters),
                ScanProgressTransitionValidator.canTransition(
                    from: previous.phase,
                    to: snapshot.phase
                )
            else {
                throw RunControlStoreError.invalidProgressTransition
            }
            try write(snapshot, to: .progress, allowedKeys: Self.progressKeys)
        }
    }

    public func channelError() -> RunControlStoreError? {
        lastPublishError
    }

    public func latestProgress() async throws -> ScanProgressSnapshot? {
        try withLock {
            try validateRoot()
            return try readIfPresent(
                ScanProgressSnapshot.self,
                from: .progress,
                allowedKeys: Self.progressKeys
            )
        }
    }

    public func recordRunBinding(_ binding: DailyDiskRunBinding) async throws {
        try withLock {
            try validateRoot()
            let active = try read(
                DailyDiskRunRequest.self,
                from: .active,
                allowedKeys: Self.requestKeys
            )
            guard active.requestID == binding.requestID else {
                throw RunControlStoreError.requestIDMismatch
            }
            try write(binding, to: .runBinding, allowedKeys: Self.runBindingKeys)
        }
    }

    public func runBinding() async throws -> DailyDiskRunBinding? {
        try withLock {
            try validateRoot()
            guard
                let binding = try readIfPresent(
                    DailyDiskRunBinding.self,
                    from: .runBinding,
                    allowedKeys: Self.runBindingKeys
                )
            else { return nil }
            let active = try read(
                DailyDiskRunRequest.self,
                from: .active,
                allowedKeys: Self.requestKeys
            )
            guard binding.requestID == active.requestID else {
                throw RunControlStoreError.requestIDMismatch
            }
            return binding
        }
    }

    public func cancelPendingRequest(
        requestID: UUID,
        at date: Date = Date()
    ) async throws -> DailyDiskRunSummary {
        try withLock {
            try validateRoot()
            let pending = try read(
                DailyDiskRunRequest.self,
                from: .pending,
                allowedKeys: Self.requestKeys
            )
            guard pending.requestID == requestID else {
                throw RunControlStoreError.requestIDMismatch
            }
            let summary = try DailyDiskRunSummary(
                requestID: requestID,
                trigger: .manual,
                terminalState: .cancelled,
                startedAt: pending.createdAt,
                finishedAt: max(pending.createdAt, date),
                completedDomainCount: 0,
                failedDomainCount: 0,
                reportRunIDs: []
            )
            let progress = try ScanProgressSnapshot(
                requestID: requestID,
                trigger: .manual,
                mode: nil,
                phase: .cancelled,
                startedAt: pending.createdAt,
                updatedAt: max(pending.createdAt, date)
            )
            try write(summary, to: .summary, allowedKeys: Self.summaryKeys)
            try write(progress, to: .progress, allowedKeys: Self.progressKeys)
            try removeIfPresent(.pending)
            try removeIfPresent(.cancellation)
            try syncDirectory()
            return summary
        }
    }

    public func requestCancellation(_ request: DailyDiskCancelRequest) async throws {
        try withLock {
            try validateRoot()
            let active = try read(
                DailyDiskRunRequest.self,
                from: .active,
                allowedKeys: Self.requestKeys
            )
            guard active.requestID == request.requestID else {
                throw RunControlStoreError.requestIDMismatch
            }
            if let progress = try readIfPresent(
                ScanProgressSnapshot.self,
                from: .progress,
                allowedKeys: Self.progressKeys
            ) {
                guard progress.requestID == active.requestID else {
                    throw RunControlStoreError.requestIDMismatch
                }
                guard progress.phase.allowsCancellation else {
                    throw RunControlStoreError.notCancellable(progress.phase)
                }
            }
            try write(request, to: .cancellation, allowedKeys: Self.cancellationKeys)
        }
    }

    public func signalIfRequestIsCancellable(
        requestID: UUID,
        processID: Int32,
        signaler: any ProcessSignaling
    ) async throws -> Bool {
        try withLock {
            try validateRoot()
            guard
                let active = try readIfPresent(
                    DailyDiskRunRequest.self,
                    from: .active,
                    allowedKeys: Self.requestKeys
                ), active.requestID == requestID,
                let progress = try readIfPresent(
                    ScanProgressSnapshot.self,
                    from: .progress,
                    allowedKeys: Self.progressKeys
                ), progress.requestID == requestID,
                progress.phase.allowsCancellation || progress.phase == .cancelling
            else { return false }
            // Completion and the next request claim use this same filesystem
            // lock. The fixed SIGTERM is dispatched before turnover can occur.
            try signaler.terminate(processID: processID)
            return true
        }
    }

    public func cancellationRequest() async throws -> DailyDiskCancelRequest? {
        try withLock {
            try validateRoot()
            return try readIfPresent(
                DailyDiskCancelRequest.self,
                from: .cancellation,
                allowedKeys: Self.cancellationKeys
            )
        }
    }

    public func checkCancellation(requestID: UUID) async throws {
        try withLock {
            try validateRoot()
            guard
                let cancellation = try readIfPresent(
                    DailyDiskCancelRequest.self,
                    from: .cancellation,
                    allowedKeys: Self.cancellationKeys
                )
            else { return }
            guard cancellation.requestID == requestID else {
                throw RunControlStoreError.requestIDMismatch
            }
            throw ScanProgressError.cancelled
        }
    }

    public func complete(_ summary: DailyDiskRunSummary) async throws {
        try withLock {
            try validateRoot()
            let persistedSummary = try readIfPresent(
                DailyDiskRunSummary.self,
                from: .summary,
                allowedKeys: Self.summaryKeys
            )
            if let persistedSummary, persistedSummary != summary {
                throw RunControlStoreError.terminalSummaryConflict
            }
            let active = try readIfPresent(
                DailyDiskRunRequest.self,
                from: .active,
                allowedKeys: Self.requestKeys
            )
            if let active {
                guard active.requestID == summary.requestID else {
                    throw RunControlStoreError.requestIDMismatch
                }
            } else if persistedSummary == nil {
                throw RunControlStoreError.noActiveRun
            }
            if persistedSummary == nil {
                try write(summary, to: .summary, allowedKeys: Self.summaryKeys)
            }
            try finalizePersistedSummary(summary)
        }
    }

    public func latestSummary() async throws -> DailyDiskRunSummary? {
        try withLock {
            try validateRoot()
            return try readIfPresent(
                DailyDiskRunSummary.self,
                from: .summary,
                allowedKeys: Self.summaryKeys
            )
        }
    }

    public func clearInactiveState() async throws {
        try withLock {
            try validateRoot()
            guard !fileExists(.active), !fileExists(.pending) else {
                throw RunControlStoreError.runAlreadyActive
            }
            try removeIfPresent(.progress)
            try removeIfPresent(.summary)
            try removeIfPresent(.runBinding)
            try removeIfPresent(.cancellation)
            try syncDirectory()
        }
    }

    public func clearExpiredState(
        now: Date = Date(),
        maximumAge: TimeInterval = 24 * 60 * 60,
        writerIsActive: Bool = true
    ) async throws {
        guard maximumAge.isFinite, maximumAge > 0 else {
            throw RunControlStoreError.invalidMaximumAge
        }
        try withLock {
            try validateRoot()
            let progress = try readIfPresent(
                ScanProgressSnapshot.self,
                from: .progress,
                allowedKeys: Self.progressKeys
            )
            let summary = try readIfPresent(
                DailyDiskRunSummary.self,
                from: .summary,
                allowedKeys: Self.summaryKeys
            )
            let active = try readIfPresent(
                DailyDiskRunRequest.self,
                from: .active,
                allowedKeys: Self.requestKeys
            )
            if let active {
                if let summary, summary.requestID == active.requestID {
                    if !writerIsActive {
                        try finalizePersistedSummary(summary)
                    }
                } else {
                    let heartbeat =
                        progress?.requestID == active.requestID
                        ? progress?.updatedAt ?? active.createdAt
                        : active.createdAt
                    if !writerIsActive, now.timeIntervalSince(heartbeat) > maximumAge {
                        try removeIfPresent(.active)
                        try removeIfPresent(.runBinding)
                        try removeIfPresent(.cancellation)
                        if progress?.requestID == active.requestID, progress?.phase.isTerminal == false {
                            try removeIfPresent(.progress)
                        }
                    }
                }
            } else if let summary, !writerIsActive {
                try finalizePersistedSummary(summary)
            }
            if let pending = try readIfPresent(
                DailyDiskRunRequest.self,
                from: .pending,
                allowedKeys: Self.requestKeys
            ), now.timeIntervalSince(pending.createdAt) > maximumAge {
                try removeIfPresent(.pending)
                if progress?.requestID == pending.requestID, progress?.phase == .queued {
                    try removeIfPresent(.progress)
                }
            }
            if !fileExists(.active), !fileExists(.pending), let progress,
                progress.phase.isTerminal,
                now.timeIntervalSince(progress.updatedAt) > maximumAge
            {
                try removeIfPresent(.progress)
                try removeIfPresent(.summary)
            }
            try syncDirectory()
        }
    }

    private func finalizePersistedSummary(_ summary: DailyDiskRunSummary) throws {
        let terminalPhase: ScanProgressPhase =
            switch summary.terminalState {
            case .succeeded, .skippedNotDue: .completed
            case .cancelled: .cancelled
            case .failed, .blockedByWriter: .failed
            }
        let existing = try readIfPresent(
            ScanProgressSnapshot.self,
            from: .progress,
            allowedKeys: Self.progressKeys
        )
        let terminal = try ScanProgressSnapshot(
            requestID: summary.requestID,
            trigger: summary.trigger,
            mode: existing?.mode,
            phase: terminalPhase,
            startedAt: summary.startedAt,
            updatedAt: summary.finishedAt,
            domainOrdinal: existing?.domainOrdinal,
            domainCount: existing?.domainCount,
            counters: existing?.counters ?? ScanProgressCounters(),
            errorCategory: terminalPhase == .failed
                ? summary.terminalState == .blockedByWriter
                    ? .writerBusy
                    : summary.errorCategory ?? .unknown
                : nil
        )
        if let existing {
            let isCompatibleTerminal = existing.phase == terminal.phase && existing.phase.isTerminal
            guard existing.requestID == summary.requestID,
                summary.finishedAt >= existing.updatedAt,
                Self.progressIdentityIsContinuous(existing, terminal),
                Self.countersAreMonotonic(existing.counters, terminal.counters),
                isCompatibleTerminal
                    || ScanProgressTransitionValidator.canTransition(
                        from: existing.phase,
                        to: terminal.phase
                    )
            else {
                throw RunControlStoreError.invalidProgressTransition
            }
        }
        try write(terminal, to: .progress, allowedKeys: Self.progressKeys)
        try removeIfPresent(.active)
        try removeIfPresent(.runBinding)
        try removeIfPresent(.cancellation)
        try syncDirectory()
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        while flock(lockFileDescriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw RunControlStoreError.posix(code: errno)
        }
        defer { flock(lockFileDescriptor, LOCK_UN) }
        return try body()
    }

    private func write<T: Encodable>(
        _ value: T,
        to file: FileName,
        allowedKeys: Set<String>
    ) throws {
        let data = try encoder.encode(value)
        try validateJSONKeys(data, allowedKeys: allowedKeys)
        let temporary = rootURL.appendingPathComponent(
            ".\(file.rawValue).\(UUID().uuidString).tmp"
        )
        let descriptor = open(
            temporary.path,
            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw RunControlStoreError.posix(code: errno) }
        var descriptorIsOpen = true
        do {
            try writeAll(data, to: descriptor)
            guard fsync(descriptor) == 0 else { throw RunControlStoreError.posix(code: errno) }
            try validateOwnedRegularFile(descriptor)
            descriptorIsOpen = false
            guard close(descriptor) == 0 else { throw RunControlStoreError.posix(code: errno) }
            let destination = url(for: file)
            guard rename(temporary.path, destination.path) == 0 else {
                throw RunControlStoreError.posix(code: errno)
            }
            do {
                try syncDirectory()
            } catch {
                throw RunControlStoreError.durabilityUncertain
            }
        } catch {
            if descriptorIsOpen { close(descriptor) }
            unlink(temporary.path)
            throw error
        }
    }

    private func readIfPresent<T: Decodable>(
        _ type: T.Type,
        from file: FileName,
        allowedKeys: Set<String>
    ) throws -> T? {
        guard fileExists(file) else { return nil }
        return try read(type, from: file, allowedKeys: allowedKeys)
    }

    private func read<T: Decodable>(
        _ type: T.Type,
        from file: FileName,
        allowedKeys: Set<String>
    ) throws -> T {
        let descriptor = open(
            url(for: file).path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw RunControlStoreError.posix(code: errno) }
        defer { close(descriptor) }
        try validateOwnedRegularFile(descriptor)
        var status = Darwin.stat()
        guard fstat(descriptor, &status) == 0 else {
            throw RunControlStoreError.posix(code: errno)
        }
        guard status.st_size >= 0, status.st_size <= 1_048_576 else {
            throw RunControlStoreError.fileTooLarge
        }
        let data = try readAll(from: descriptor, expectedSize: Int(status.st_size))
        try validateJSONKeys(data, allowedKeys: allowedKeys)
        return try decoder.decode(type, from: data)
    }

    private func validateJSONKeys(_ data: Data, allowedKeys: Set<String>) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys).isSubset(of: allowedKeys)
        else {
            throw RunControlStoreError.unexpectedJSONShape
        }
        for (key, value) in object {
            if key == "counters" {
                guard let counters = value as? [String: Any],
                    Set(counters.keys).isSubset(of: Self.counterKeys),
                    counters.values.allSatisfy({ !($0 is [String: Any]) })
                else {
                    throw RunControlStoreError.unexpectedJSONShape
                }
            } else if value is [String: Any] {
                throw RunControlStoreError.unexpectedJSONShape
            }
        }
    }

    private func readAll(from descriptor: Int32, expectedSize: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(expectedSize)
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw RunControlStoreError.posix(code: errno)
            }
            if count == 0 { break }
            guard data.count + count <= 1_048_576 else {
                throw RunControlStoreError.fileTooLarge
            }
            data.append(buffer, count: count)
        }
        return data
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard var pointer = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw RunControlStoreError.posix(code: errno)
                }
                remaining -= count
                pointer = pointer.advanced(by: count)
            }
        }
    }

    private func validateRoot() throws {
        try Self.validateOwnedDirectory(rootURL)
    }

    private static func prepareRoot(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try validateOwnedDirectory(url)
        } else {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard chmod(url.path, S_IRWXU) == 0 else {
                throw RunControlStoreError.posix(code: errno)
            }
            try validateOwnedDirectory(url)
        }
    }

    private static func validateOwnedDirectory(_ url: URL) throws {
        var status = Darwin.stat()
        guard lstat(url.path, &status) == 0 else {
            throw RunControlStoreError.posix(code: errno)
        }
        guard status.st_uid == getuid(),
            status.st_mode & S_IFMT == S_IFDIR,
            status.st_mode & 0o077 == 0
        else {
            throw RunControlStoreError.unsafeControlDirectory
        }
    }

    private func validateOwnedRegularFile(_ url: URL) throws {
        var status = Darwin.stat()
        guard lstat(url.path, &status) == 0 else {
            throw RunControlStoreError.posix(code: errno)
        }
        try validateOwnedRegularFile(status)
    }

    private func validateOwnedRegularFile(_ descriptor: Int32) throws {
        var status = Darwin.stat()
        guard fstat(descriptor, &status) == 0 else {
            throw RunControlStoreError.posix(code: errno)
        }
        try validateOwnedRegularFile(status)
    }

    private func validateOwnedRegularFile(_ status: Darwin.stat) throws {
        guard status.st_uid == getuid(),
            status.st_mode & S_IFMT == S_IFREG,
            status.st_mode & 0o077 == 0,
            status.st_nlink == 1
        else {
            throw RunControlStoreError.unsafeControlFile
        }
    }

    private func syncDirectory() throws {
        let descriptor = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw RunControlStoreError.posix(code: errno) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw RunControlStoreError.posix(code: errno) }
    }

    private func removeIfPresent(_ file: FileName) throws {
        let fileURL = url(for: file)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try validateOwnedRegularFile(fileURL)
        guard unlink(fileURL.path) == 0 else { throw RunControlStoreError.posix(code: errno) }
    }

    private func fileExists(_ file: FileName) -> Bool {
        FileManager.default.fileExists(atPath: url(for: file).path)
    }

    private func url(for file: FileName) -> URL {
        rootURL.appendingPathComponent(file.rawValue)
    }

    private static func progressIdentityIsContinuous(
        _ previous: ScanProgressSnapshot,
        _ current: ScanProgressSnapshot
    ) -> Bool {
        let startIsContinuous =
            previous.phase == .queued
            ? current.startedAt >= previous.startedAt
            // Control JSON uses ISO8601 whole seconds. Compare the wire identity,
            // not a decoded whole-second date with the worker's fractional Date().
            : previous.startedAt.timeIntervalSince1970.rounded(.down)
                == current.startedAt.timeIntervalSince1970.rounded(.down)
        let isNextDomain =
            current.phase == .preparing
            && current.domainOrdinal.map { $0 > (previous.domainOrdinal ?? 0) } == true
        let modeIsContinuous =
            previous.mode == nil || previous.mode == current.mode
            || (current.phase == .preparing && current.mode == .recoveryFull)
            || isNextDomain
        let domainCountIsContinuous =
            previous.domainCount == nil
            || previous.domainCount == current.domainCount
        let domainOrdinalIsContinuous: Bool
        if let previousOrdinal = previous.domainOrdinal,
            let currentOrdinal = current.domainOrdinal
        {
            domainOrdinalIsContinuous = currentOrdinal >= previousOrdinal
        } else {
            domainOrdinalIsContinuous = previous.domainOrdinal == nil
        }
        return previous.requestID == current.requestID
            && previous.trigger == current.trigger
            && startIsContinuous
            && modeIsContinuous
            && domainCountIsContinuous
            && domainOrdinalIsContinuous
    }

    private static func countersAreMonotonic(
        _ previous: ScanProgressCounters,
        _ current: ScanProgressCounters
    ) -> Bool {
        current.processedEvents >= previous.processedEvents
            && current.affectedPaths >= previous.affectedPaths
            && current.visitedPaths >= previous.visitedPaths
            && current.indexedObjects >= previous.indexedObjects
            && current.unreadablePaths >= previous.unreadablePaths
            && current.transientErrors >= previous.transientErrors
    }

    private struct HelperIdleState: Codable {
        let version: Int
        let idle: Bool
        let processID: Int32

        init(processID: Int32) {
            version = 1
            idle = true
            self.processID = processID
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let version = try container.decode(Int.self, forKey: .version)
            let idle = try container.decode(Bool.self, forKey: .idle)
            let processID = try container.decode(Int32.self, forKey: .processID)
            guard version == 1, idle, processID > 0 else {
                throw RunControlStoreError.unexpectedJSONShape
            }
            self.version = version
            self.idle = idle
            self.processID = processID
        }
    }

    private static let helperIdleKeys: Set<String> = ["version", "idle", "processID"]
    private static let counterKeys: Set<String> = [
        "processedEvents", "affectedPaths", "visitedPaths", "indexedObjects",
        "unreadablePaths", "transientErrors",
    ]
    private static let requestKeys: Set<String> = [
        "version", "requestID", "action", "requestedMode", "createdAt",
    ]
    private static let progressKeys: Set<String> = [
        "version", "requestID", "trigger", "mode", "phase", "startedAt",
        "updatedAt", "domainOrdinal", "domainCount", "counters", "errorCategory",
    ]
    private static let runBindingKeys: Set<String> = [
        "version", "requestID", "runID", "createdAt",
    ]
    private static let cancellationKeys: Set<String> = [
        "version", "requestID", "createdAt",
    ]
    private static let summaryKeys: Set<String> = [
        "version", "requestID", "trigger", "terminalState", "startedAt",
        "finishedAt", "completedDomainCount", "failedDomainCount",
        "reportRunIDs", "errorCategory",
    ]
}

public enum RunControlStoreError: Error, Equatable, Sendable {
    case requestAlreadyPending
    case runAlreadyActive
    case requestIDMismatch
    case invalidProgressTransition
    case noActiveRun
    case terminalSummaryConflict
    case notCancellable(ScanProgressPhase)
    case invalidMaximumAge
    case unsafeControlDirectory
    case unsafeControlFile
    case unexpectedJSONShape
    case fileTooLarge
    case durabilityUncertain
    case posix(code: Int32)
}
