/// Trust loss is distinct from cancellation and never supplies a commit cursor.
public struct EventReplayInvalidated: Error, Sendable {
    public let reasons: [String]
    public init(reasons: [String]) { self.reasons = reasons }
}

/// Captured by mutation observers so a slow subtree scan also stops cooperatively.
public enum EventReplayGuard {
    @TaskLocal public static var check: @Sendable () throws -> Void = {}

    public static func observing(_ base: any ScanWorkObserving) -> any ScanWorkObserving {
        ReplayObserver(base: base, check: check)
    }

    private struct ReplayObserver: ScanWorkObserving {
        let base: any ScanWorkObserving
        let check: @Sendable () throws -> Void
        func checkpoint(_ delta: ScanProgressDelta) async throws {
            try await base.checkpoint(delta)
            try check()
        }
    }
}
