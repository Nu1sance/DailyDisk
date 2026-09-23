extension FileSystemEvent {
    public var requiresFullScan: Bool {
        EventTrustEvaluator.assess(flags: flags).trust == .fullScanRequired
    }

    public var requiresSubtreeScan: Bool {
        EventTrustEvaluator.assess(flags: flags).trust == .subtreeRescanRequired
    }

    public var isItemEvent: Bool {
        let streamFlags: FileSystemEventFlags = [
            .historyDone,
            .rootChanged,
            .mounted,
            .unmounted,
            .userDropped,
            .kernelDropped,
            .eventIDsWrapped,
        ]
        return flags.intersection(streamFlags).isEmpty
    }
}
