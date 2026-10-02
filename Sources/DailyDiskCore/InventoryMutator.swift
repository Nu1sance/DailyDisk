import Foundation

public struct InventoryMutationResult: Sendable {
    public let assessment: EventTrustAssessment
    public let affectedPathCount: Int
    public let repairedSubtreeRequirementCount: Int
    public let scanErrors: [ScanErrorRecord]

    public init(
        assessment: EventTrustAssessment,
        affectedPathCount: Int,
        repairedSubtreeRequirementCount: Int,
        scanErrors: [ScanErrorRecord]
    ) {
        self.assessment = assessment
        self.affectedPathCount = affectedPathCount
        self.repairedSubtreeRequirementCount = repairedSubtreeRequirementCount
        self.scanErrors = scanErrors
    }
}

public actor IncrementalInventoryMutator {
    private let store: any InventoryStoring
    private let metadataReader: any FileMetadataReading
    private let subtreeScanner: any FileInventoryScanning
    private var removedIdentities: [FileIdentity: Bool] = [:]

    public init(
        store: any InventoryStoring,
        metadataReader: any FileMetadataReading,
        subtreeScanner: any FileInventoryScanning
    ) {
        self.store = store
        self.metadataReader = metadataReader
        self.subtreeScanner = subtreeScanner
    }

    public func apply(
        batch: EventBatch,
        volume: MonitoredVolume,
        target: InventoryMutationTarget,
        runID: ScanRun.ID
    ) async throws -> InventoryMutationResult {
        try await apply(
            batch: batch,
            volume: volume,
            target: target,
            runID: runID,
            observer: TaskOnlyScanWorkObserver()
        )
    }

    public func apply(
        batch: EventBatch,
        volume: MonitoredVolume,
        target: InventoryMutationTarget,
        runID: ScanRun.ID,
        observer: any ScanWorkObserving
    ) async throws -> InventoryMutationResult {
        let observer = EventReplayGuard.observing(observer)
        var assessment = EventTrustAssessment(trust: .trusted)
        var affected = 0
        var affectedEventPaths: Set<RelativePath> = []
        var repairedSubtreeRequirements = 0
        var scanErrors: [ScanErrorRecord] = []

        for event in batch.events {
            try await observer.checkpoint()
            guard event.volumeID == volume.id else {
                throw IncrementalMutationError.volumeMismatch
            }
            let eventAssessment = EventTrustEvaluator.assess(flags: event.flags)
            if eventAssessment.trust == .fullScanRequired {
                assessment = assessment.merging(eventAssessment)
                continue
            }
            guard event.isItemEvent else { continue }

            let previous = try await store.records(
                target: target,
                runID: runID,
                paths: [event.path]
            ).first
            let readResult = try await metadataReader.read(volume: volume, path: event.path)
            if case .excluded = readResult { continue }
            let inaccessible: (ScanErrorRecord.Kind, Int32)?
            switch readResult {
            case .inaccessible(let code): inaccessible = (.permissionDenied, code)
            case .unavailable(let code): inaccessible = (.contentUnavailable, code)
            default: inaccessible = nil
            }
            if let (kind, code) = inaccessible {
                scanErrors.append(
                    ScanErrorRecord(
                        runID: runID,
                        volumeID: volume.id,
                        kind: kind,
                        path: event.path,
                        errorCode: code,
                        message: "Content could not be read; preserved previous opaque inventory state"
                    )
                )
                continue
            }
            let current: InventoryRecord? = if case .record(let record) = readResult { record } else { nil }

            // Coalesced flags describe a path's history, not a single operation.
            // Missing endpoints and single-link replacements can be reconciled
            // from current metadata; shared inode aliases still require recovery.
            if event.flags.contains(.removed),
                event.flags.contains(.created),
                !event.flags.contains(.renamed),
                let previous, let current,
                previous.object.identity == current.object.identity,
                previous.object.kind == .regular,
                previous.object.linkCount > 1 || current.object.linkCount > 1
            {
                ScanProbe.emit(
                    .identityAmbiguity, reason: .hardLinkRecreated,
                    fields: [
                        "flags": String(event.flags.rawValue), "oldLinks": String(previous.object.linkCount),
                        "newLinks": String(current.object.linkCount), "sameIdentity": "true",
                        "oldDevice": String(previous.object.identity.deviceID),
                        "oldInode": String(previous.object.identity.inode),
                        "newDevice": String(current.object.identity.deviceID),
                        "newInode": String(current.object.identity.inode),
                    ])
                assessment = assessment.merging(
                    EventTrustAssessment(
                        trust: .fullScanRequired,
                        reasons: [
                            "A hard-linked path was removed and recreated before identity could be disambiguated"
                        ], probeReason: .hardLinkRecreated
                    )
                )
                continue
            }
            if let previous, current == nil {
                removedIdentities[previous.object.identity] = event.flags.contains(.renamed)
            }
            if previous == nil, let current,
                let removalWasRename = removedIdentities[current.object.identity],
                !(removalWasRename && event.flags.contains(.renamed))
            {
                let survivingAliases = try await store.paths(
                    target: target, runID: runID, objectIdentity: current.object.identity)
                if !survivingAliases.isEmpty {
                    ScanProbe.emit(
                        .identityAmbiguity, reason: .inodeReuse,
                        fields: [
                            "flags": String(event.flags.rawValue), "remainingAliases": String(survivingAliases.count),
                            "device": String(current.object.identity.deviceID),
                            "inode": String(current.object.identity.inode),
                            "newLinks": String(current.object.linkCount),
                        ])
                    assessment = assessment.merging(
                        EventTrustAssessment(
                            trust: .fullScanRequired,
                            reasons: ["Possible inode reuse with surviving indexed aliases"], probeReason: .inodeReuse
                        )
                    )
                    continue
                }
                // All old references have been removed from this overlay. The
                // inode may safely represent the newly observed object now.
                removedIdentities.removeValue(forKey: current.object.identity)
            }

            let previousWasDirectory = previous?.object.kind == .directory
            let directoryIdentityChanged =
                previousWasDirectory
                && (current == nil
                    || current?.object.kind != .directory
                    || current?.object.identity != previous?.object.identity)
            if directoryIdentityChanged {
                try await store.stageRemovalSubtree(
                    root: event.path,
                    target: target,
                    for: runID,
                    observer: observer
                )
                if affectedEventPaths.insert(event.path).inserted {
                    affected += 1
                    try await observer.checkpoint(ScanProgressDelta(affectedPaths: 1))
                }
            }

            if current == nil {
                if !previousWasDirectory, previous != nil {
                    try await store.stage(
                        mutations: [.remove(volumeID: volume.id, path: event.path)],
                        target: target,
                        for: runID
                    )
                    if affectedEventPaths.insert(event.path).inserted {
                        affected += 1
                        try await observer.checkpoint(ScanProgressDelta(affectedPaths: 1))
                    }
                }
                if let previous,
                    previous.object.linkCount > 1,
                    !event.flags.contains(.isLastHardLink)
                {
                    try await refreshSurvivingHardLink(
                        identity: previous.object.identity,
                        removedPath: event.path,
                        volume: volume,
                        target: target,
                        runID: runID,
                        observer: observer
                    )
                }
                continue
            }

            guard let current else { continue }
            let needsSubtree =
                current.object.kind == .directory
                && (event.flags.contains(.mustScanSubdirectories)
                    || event.flags.contains(.created)
                    || event.flags.contains(.renamed)
                    || directoryIdentityChanged)
            if needsSubtree {
                try await store.stageRemovalSubtree(
                    root: event.path,
                    target: target,
                    for: runID,
                    observer: observer
                )
                let result = try await subtreeScanner.scanSubtree(
                    volume: volume,
                    root: event.path,
                    runID: runID,
                    observer: observer
                ) { records in
                    try await self.store.stage(
                        mutations: records.records.map(InventoryMutation.upsert),
                        target: target,
                        for: runID
                    )
                }
                if affectedEventPaths.insert(event.path).inserted {
                    affected += 1
                    try await observer.checkpoint(ScanProgressDelta(affectedPaths: 1))
                }
                scanErrors.append(contentsOf: result.errors)
                if result.coverage.unreadablePathCount > 0 {
                    throw IncrementalMutationError.incompleteSubtree
                }
                if event.flags.contains(.mustScanSubdirectories) {
                    repairedSubtreeRequirements += 1
                }
                continue
            }

            if previous != current {
                try await store.stage(mutations: [.upsert(current)], target: target, for: runID)
                if affectedEventPaths.insert(event.path).inserted {
                    affected += 1
                    try await observer.checkpoint(ScanProgressDelta(affectedPaths: 1))
                }
            }
        }

        return InventoryMutationResult(
            assessment: assessment,
            affectedPathCount: affected,
            repairedSubtreeRequirementCount: repairedSubtreeRequirements,
            scanErrors: scanErrors
        )
    }

    private func refreshSurvivingHardLink(
        identity: FileIdentity,
        removedPath: RelativePath,
        volume: MonitoredVolume,
        target: InventoryMutationTarget,
        runID: ScanRun.ID,
        observer: any ScanWorkObserving
    ) async throws {
        let candidates = try await store.paths(
            target: target,
            runID: runID,
            objectIdentity: identity
        )
        for path in candidates where path != removedPath {
            try await observer.checkpoint()
            switch try await metadataReader.read(volume: volume, path: path) {
            case .record(let record):
                try await store.stage(mutations: [.upsert(record)], target: target, for: runID)
                return
            case .missing, .excluded, .inaccessible, .unavailable:
                continue
            }
        }
    }
}

public enum IncrementalMutationError: Error, Equatable, Sendable {
    case volumeMismatch
    case incompleteSubtree
}
