public enum ScanExecutionOutcome: Sendable {
    case incremental(IncrementalScanOutcome)
    case recoveryRequired(reasons: [String])
}

/// Entry point shared by manual and scheduled execution. Full/recovery policy
/// is added by FullScanCoordinator; this layer converts incremental trust loss
/// into an explicit orchestration decision rather than advancing a checkpoint.
public struct ScanCoordinator: Sendable {
    private let incrementalScanner: IncrementalScanner

    public init(incrementalScanner: IncrementalScanner) {
        self.incrementalScanner = incrementalScanner
    }

    public func runIncremental(
        volume: MonitoredVolume,
        scope: StorageDomainScope
    ) async throws -> ScanExecutionOutcome {
        try await runIncremental(
            volume: volume,
            scope: scope,
            trigger: .scheduled,
            progressTracker: NoopScanProgressTracker()
        )
    }

    public func runIncremental(
        volume: MonitoredVolume,
        scope: StorageDomainScope,
        trigger: DailyDiskRunTrigger,
        progressTracker: any ScanProgressTracking
    ) async throws -> ScanExecutionOutcome {
        do {
            return .incremental(
                try await incrementalScanner.run(
                    volume: volume,
                    scope: scope,
                    trigger: trigger,
                    progressTracker: progressTracker
                )
            )
        } catch IncrementalScanError.recoveryRequired(let reasons) {
            return .recoveryRequired(reasons: reasons)
        }
    }
}
