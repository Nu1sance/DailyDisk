import DailyDiskCore
import DailyDiskStore
import Foundation

public protocol LatestReportReading: Sendable {
    func latestSuccessfulReportDate(
        for storageDomainID: StorageDomain.ID
    ) async throws -> Date?
}

private struct DomainRunResult: Sendable {
    let report: ReportGenerationResult?
    let runID: ScanRun.ID
    let shouldNotify: Bool
    let usedProgressTracker: Bool
}

extension SQLiteReportStore: LatestReportReading {
    public func latestSuccessfulReportDate(
        for storageDomainID: StorageDomain.ID
    ) async throws -> Date? {
        try await latestReport(for: storageDomainID)?.generatedAt
    }
}

public enum DailyDiskCoordinatorMode: Sendable {
    case scheduled
    case manual(
        requestID: UUID,
        requestedMode: DailyDiskRequestedScanMode,
        resumeCommittedRunID: ScanRun.ID? = nil
    )

    var trigger: DailyDiskRunTrigger {
        switch self {
        case .scheduled: .scheduled
        case .manual: .manual
        }
    }

    var requestID: UUID {
        switch self {
        case .scheduled: UUID()
        case .manual(let requestID, _, _): requestID
        }
    }
}

public struct DailyDiskRunCoordinator: Sendable {
    public typealias ProgressFactory =
        @Sendable (
            _ requestID: UUID,
            _ trigger: DailyDiskRunTrigger,
            _ startedAt: Date,
            _ domainCount: Int
        ) async throws -> any ScanProgressTracking
    public typealias ReportHandler = @Sendable (ReportGenerationResult) async -> Void
    public typealias RetentionHandler = @Sendable () async throws -> Void
    public typealias ErrorHandler = @Sendable (_ event: String, _ error: any Error) async -> Void

    private let store: any InventoryStoring
    private let reportReader: any LatestReportReading
    private let discovery: any VolumeDiscovering
    private let eventReader: any EventHistoryReading
    private let metadataReader: any FileMetadataReading
    private let fileScanner: any FileInventoryScanning
    private let diskUsageSampler: any DiskUsageSampling
    private let overheadSampler: (any DailyDiskOverheadSampling)?
    private let reportCoordinator: DailyReportCoordinator
    private let clock: any Clock
    private let dueTimeGate: DueTimeGate
    private let scanPolicy: ScanPolicy
    private let progressFactory: ProgressFactory
    private let scheduledReportHandler: ReportHandler?
    private let retentionHandler: RetentionHandler?
    private let errorHandler: ErrorHandler?

    public init(
        store: any InventoryStoring,
        reportReader: any LatestReportReading,
        discovery: any VolumeDiscovering,
        eventReader: any EventHistoryReading,
        metadataReader: any FileMetadataReading,
        fileScanner: any FileInventoryScanning,
        diskUsageSampler: any DiskUsageSampling,
        overheadSampler: (any DailyDiskOverheadSampling)? = nil,
        reportCoordinator: DailyReportCoordinator,
        clock: any Clock = SystemClock(),
        dueTimeGate: DueTimeGate = .default,
        scanPolicy: ScanPolicy = .default,
        progressFactory: @escaping ProgressFactory = { _, _, _, _ in
            NoopScanProgressTracker()
        },
        scheduledReportHandler: ReportHandler? = nil,
        retentionHandler: RetentionHandler? = nil,
        errorHandler: ErrorHandler? = nil
    ) {
        self.store = store
        self.reportReader = reportReader
        self.discovery = discovery
        self.eventReader = eventReader
        self.metadataReader = metadataReader
        self.fileScanner = fileScanner
        self.diskUsageSampler = diskUsageSampler
        self.overheadSampler = overheadSampler
        self.reportCoordinator = reportCoordinator
        self.clock = clock
        self.dueTimeGate = dueTimeGate
        self.scanPolicy = scanPolicy
        self.progressFactory = progressFactory
        self.scheduledReportHandler = scheduledReportHandler
        self.retentionHandler = retentionHandler
        self.errorHandler = errorHandler
    }

    public func run(
        mode: DailyDiskCoordinatorMode,
        startedAt resumedStart: Date? = nil,
        requestID suppliedRequestID: UUID? = nil
    ) async -> DailyDiskRunSummary {
        let startedAt: Date
        if let resumedStart {
            startedAt = resumedStart
        } else {
            startedAt = await clock.now()
        }
        let requestID = suppliedRequestID ?? mode.requestID
        do {
            let tracker = try await progressFactory(requestID, mode.trigger, startedAt, 0)
            let initialProgress = try await tracker.currentSnapshot()
            let resumingPublication = [.committing, .publishingReport, .notifying, .applyingRetention]
                .contains(initialProgress.phase)
            if !resumingPublication {
                try await tracker.transition(to: .preparing, mode: nil)
            }
            try await store.prepare()
            let hasInterruptedRuns = try await !store.activeRuns().isEmpty
            let recoveringCommit = resumingPublication && hasInterruptedRuns
            if recoveringCommit {
                // The persisted phase can precede the SQLite COMMIT. A new
                // writer lease plus a still-running database run means that
                // transaction was rolled back, not that a report is pending.
                // Show cleanup before restarting inventory work for this request.
                try await tracker.transition(to: .cleaningUpFailedRun, mode: nil)
            } else if !resumingPublication, hasInterruptedRuns {
                try await tracker.transition(to: .recoveringInterruptedRun, mode: nil)
            }
            try await store.recoverInterruptedRuns(at: startedAt)
            if recoveringCommit {
                try await tracker.transition(to: .preparing, mode: nil)
            }
            if !resumingPublication || recoveringCommit {
                try await tracker.transition(to: .discoveringStorage, mode: nil)
            }
            let topology = try await discovery.discoverInternalAPFSVolumes()
            // Metrics-only containers have no inventory work. Do not move the
            // progress tracker to another domain after a successful commit.
            let inventoryDomainIDs = Set(topology.volumes.filter { $0.inventoryMode == .full }.map(\.storageDomainID))
            let domains = topology.domains.filter { inventoryDomainIDs.contains($0.id) }
            var completedDomains = 0
            var failedDomains = 0
            var reportRunIDs: [UUID] = []

            for (index, domain) in domains.enumerated() {
                do {
                    try await tracker.beginDomain(ordinal: index + 1, count: domains.count)
                    if let domainResult = try await runDomain(
                        domain: domain,
                        topology: topology,
                        mode: mode,
                        progressTracker: tracker
                    ) {
                        if domainResult.shouldNotify, let report = domainResult.report,
                            let scheduledReportHandler
                        {
                            if domainResult.usedProgressTracker {
                                try? await tracker.transition(to: .notifying, mode: nil)
                            }
                            await scheduledReportHandler(report)
                        }
                        completedDomains += 1
                        reportRunIDs.append(domainResult.runID.rawValue)
                    }
                } catch {
                    if isScanCancellation(error) {
                        return try DailyDiskRunSummary(
                            requestID: requestID,
                            trigger: mode.trigger,
                            terminalState: .cancelled,
                            startedAt: startedAt,
                            finishedAt: await clock.now(),
                            completedDomainCount: completedDomains,
                            failedDomainCount: 0,
                            reportRunIDs: reportRunIDs
                        )
                    }
                    failedDomains += 1
                    await errorHandler?("domain-run-failed", error)
                }
            }

            if let retentionHandler {
                if completedDomains > 0 {
                    try? await tracker.transition(to: .applyingRetention, mode: nil)
                }
                do {
                    try await retentionHandler()
                } catch {
                    failedDomains += 1
                    await errorHandler?("retention-failed", error)
                }
            }
            let finishedAt = await clock.now()
            if failedDomains > 0 {
                return try DailyDiskRunSummary(
                    requestID: requestID,
                    trigger: mode.trigger,
                    terminalState: .failed,
                    startedAt: startedAt,
                    finishedAt: finishedAt,
                    completedDomainCount: completedDomains,
                    failedDomainCount: failedDomains,
                    reportRunIDs: reportRunIDs,
                    errorCategory: .unknown
                )
            }
            if completedDomains == 0 {
                if case .manual = mode {
                    return try DailyDiskRunSummary(
                        requestID: requestID,
                        trigger: mode.trigger,
                        terminalState: .failed,
                        startedAt: startedAt,
                        finishedAt: finishedAt,
                        completedDomainCount: 0,
                        failedDomainCount: 1,
                        reportRunIDs: [],
                        errorCategory: .storageTopology
                    )
                }
                return try DailyDiskRunSummary(
                    requestID: requestID,
                    trigger: mode.trigger,
                    terminalState: .skippedNotDue,
                    startedAt: startedAt,
                    finishedAt: finishedAt,
                    completedDomainCount: 0,
                    failedDomainCount: 0,
                    reportRunIDs: []
                )
            }
            try? await tracker.transition(to: .completed, mode: nil)
            let completedAt = max(finishedAt, await clock.now())
            return try DailyDiskRunSummary(
                requestID: requestID,
                trigger: mode.trigger,
                terminalState: .succeeded,
                startedAt: startedAt,
                finishedAt: completedAt,
                completedDomainCount: completedDomains,
                failedDomainCount: 0,
                reportRunIDs: reportRunIDs
            )
        } catch {
            await errorHandler?("run-failed", error)
            return try! DailyDiskRunSummary(
                requestID: requestID,
                trigger: mode.trigger,
                terminalState: isScanCancellation(error) ? .cancelled : .failed,
                startedAt: startedAt,
                finishedAt: max(startedAt, await clock.now()),
                completedDomainCount: 0,
                failedDomainCount: isScanCancellation(error) ? 0 : 1,
                reportRunIDs: [],
                errorCategory: isScanCancellation(error) ? nil : error is WriterLeaseError ? .writerBusy : .unknown
            )
        }
    }

    private func runDomain(
        domain: StorageDomain,
        topology: VolumeTopology,
        mode: DailyDiskCoordinatorMode,
        progressTracker: any ScanProgressTracking
    ) async throws -> DomainRunResult? {
        let volumes = topology.volumes.filter { $0.storageDomainID == domain.id }
        guard !volumes.isEmpty else { return nil }
        let scope = try StorageDomainScope(domain: domain, volumes: volumes)
        try await store.register(scope: scope)
        guard let volume = volumes.first(where: { $0.inventoryMode == .full }) else {
            return nil
        }

        if case .manual(_, _, let resumedRunID) = mode,
            let resumedRunID,
            try await store.report(
                runID: resumedRunID,
                storageDomainID: domain.id
            ) != nil
        {
            try await progressTracker.transition(to: .publishingReport, mode: nil)
            return DomainRunResult(
                report: nil,
                runID: resumedRunID,
                shouldNotify: false,
                usedProgressTracker: true
            )
        }

        var recoveredResult: DomainRunResult?
        if let basis = try await store.latestUnreportedBasis(storageDomainID: domain.id) {
            let originalRun = try await store.scanRun(id: basis.runID)
            let resumesCurrentManualRun: Bool
            if case .manual(_, _, let resumedRunID) = mode {
                resumesCurrentManualRun =
                    resumedRunID == basis.runID
                    && originalRun?.reason == .manual
            } else {
                resumesCurrentManualRun = false
            }
            if resumesCurrentManualRun || mode.trigger == .scheduled {
                // Persist the post-commit phase before artifact/report recovery,
                // so another crash can recognize the bound run without rescanning.
                try await progressTracker.transition(to: .publishingReport, mode: nil)
            }
            let recovered = try await reportCoordinator.generate(basis: basis, scope: scope)
            if case .scheduled = mode {
                let shouldNotifyRecovered = originalRun?.reason != .manual
                if shouldNotifyRecovered, let scheduledReportHandler {
                    await scheduledReportHandler(recovered)
                }
                recoveredResult = DomainRunResult(
                    report: recovered,
                    runID: recovered.report.runID,
                    shouldNotify: false,
                    usedProgressTracker: true
                )
            } else if resumesCurrentManualRun {
                return DomainRunResult(
                    report: recovered,
                    runID: recovered.report.runID,
                    shouldNotify: false,
                    usedProgressTracker: true
                )
            }
        }

        if case .scheduled = mode {
            let latestReportDate = try await reportReader.latestSuccessfulReportDate(
                for: domain.id
            )
            guard
                case .due = try dueTimeGate.decision(
                    now: await clock.now(),
                    lastSuccessfulAt: latestReportDate
                )
            else {
                return recoveredResult
            }
        }

        let state = try await store.state(for: volume.id)
        let fullCoordinator = FullScanCoordinator(
            store: store,
            eventReader: eventReader,
            metadataReader: metadataReader,
            fullScanner: fileScanner,
            diskUsageSampler: diskUsageSampler,
            overheadSampler: overheadSampler,
            volumeDiscovery: discovery,
            clock: clock
        )
        let incremental = IncrementalScanner(
            store: store,
            eventReader: eventReader,
            metadataReader: metadataReader,
            subtreeScanner: fileScanner,
            diskUsageSampler: diskUsageSampler,
            overheadSampler: overheadSampler,
            clock: clock
        )
        let trigger = mode.trigger

        let reportResult: ReportGenerationResult
        let policyDecision: ScanDecision
        if case .manual(_, .fullReconciliation, _) = mode {
            policyDecision = state == nil ? .initialFull : .scheduledFull
        } else {
            policyDecision = scanPolicy.decision(
                checkpoint: state?.checkpoint,
                now: await clock.now()
            )
        }
        switch policyDecision {
        case .initialFull:
            let outcome = try await fullCoordinator.run(
                volume: volume,
                scope: scope,
                mode: .initial,
                trigger: trigger,
                progressTracker: progressTracker
            )
            reportResult = try await reportCoordinator.generate(
                outcome: outcome,
                scope: scope,
                progressTracker: progressTracker
            )
        case .scheduledFull:
            let outcome = try await fullCoordinator.run(
                volume: volume,
                scope: scope,
                mode: .scheduled,
                trigger: trigger,
                progressTracker: progressTracker
            )
            reportResult = try await reportCoordinator.generate(
                outcome: outcome,
                scope: scope,
                progressTracker: progressTracker
            )
        case .incremental:
            switch try await ScanCoordinator(incrementalScanner: incremental).runIncremental(
                volume: volume,
                scope: scope,
                trigger: trigger,
                progressTracker: progressTracker
            ) {
            case .incremental(let outcome):
                reportResult = try await reportCoordinator.generate(
                    outcome: outcome,
                    scope: scope,
                    progressTracker: progressTracker
                )
            case .recoveryRequired:
                let outcome = try await fullCoordinator.run(
                    volume: volume,
                    scope: scope,
                    mode: .recovery(.eventHistoryLost),
                    trigger: trigger,
                    progressTracker: progressTracker
                )
                reportResult = try await reportCoordinator.generate(
                    outcome: outcome,
                    scope: scope,
                    progressTracker: progressTracker
                )
            }
        case .recovery(let recoveryTrigger):
            let outcome = try await fullCoordinator.run(
                volume: volume,
                scope: scope,
                mode: .recovery(recoveryTrigger),
                trigger: trigger,
                progressTracker: progressTracker
            )
            reportResult = try await reportCoordinator.generate(
                outcome: outcome,
                scope: scope,
                progressTracker: progressTracker
            )
        }
        return DomainRunResult(
            report: reportResult,
            runID: reportResult.report.runID,
            shouldNotify: mode.trigger == .scheduled,
            usedProgressTracker: true
        )
    }
}
