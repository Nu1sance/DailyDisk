import Foundation

public enum PathValidationError: Error, Equatable, Sendable {
    case absolutePath
    case trailingSeparator
    case emptyComponent
    case currentDirectoryComponent
    case parentDirectoryComponent
    case nulByte
    case separatorInComponent
}

public enum PathPolicy {
    private static let separator: UInt8 = 0x2F
    private static let nul: UInt8 = 0
    private static let currentDirectory = Data([0x2E])
    private static let parentDirectory = Data([0x2E, 0x2E])

    public static func validate(relativePathBytes bytes: Data) throws {
        guard !bytes.contains(nul) else {
            throw PathValidationError.nulByte
        }
        guard !bytes.isEmpty else {
            return
        }
        guard bytes.first != separator else {
            throw PathValidationError.absolutePath
        }
        guard bytes.last != separator else {
            throw PathValidationError.trailingSeparator
        }

        for component in bytes.split(separator: separator, omittingEmptySubsequences: false) {
            guard !component.isEmpty else {
                throw PathValidationError.emptyComponent
            }
            let componentData = Data(component)
            guard componentData != currentDirectory else {
                throw PathValidationError.currentDirectoryComponent
            }
            guard componentData != parentDirectory else {
                throw PathValidationError.parentDirectoryComponent
            }
        }
    }

    public static func parent(of path: RelativePath) -> RelativePath? {
        guard !path.bytes.isEmpty else {
            return nil
        }
        guard let separatorIndex = path.bytes.lastIndex(of: separator) else {
            return .root
        }
        return try? RelativePath(validating: path.bytes[..<separatorIndex])
    }

    public static func appending(componentBytes: Data, to parent: RelativePath) throws -> RelativePath {
        guard !componentBytes.isEmpty else {
            throw PathValidationError.emptyComponent
        }
        guard !componentBytes.contains(separator) else {
            throw PathValidationError.separatorInComponent
        }
        guard !componentBytes.contains(nul) else {
            throw PathValidationError.nulByte
        }
        guard componentBytes != currentDirectory else {
            throw PathValidationError.currentDirectoryComponent
        }
        guard componentBytes != parentDirectory else {
            throw PathValidationError.parentDirectoryComponent
        }

        var result = parent.bytes
        if !result.isEmpty {
            result.append(separator)
        }
        result.append(componentBytes)
        return try RelativePath(validating: result)
    }

    /// Returns parents from the immediate parent through the volume root.
    public static func ancestors(of path: RelativePath) -> [RelativePath] {
        var result: [RelativePath] = []
        var current = parent(of: path)
        while let path = current {
            result.append(path)
            current = parent(of: path)
        }
        return result
    }

    public static func classify(
        _ path: RelativePath,
        dailyDiskManagedRoots: Set<RelativePath>
    ) -> InventoryClassification {
        for root in dailyDiskManagedRoots where isEqual(path, orDescendantOf: root) {
            return .dailyDiskInternal
        }
        return .ordinary
    }

    public static func isEqual(_ path: RelativePath, orDescendantOf root: RelativePath) -> Bool {
        if root.bytes.isEmpty {
            return true
        }
        if path == root {
            return true
        }
        guard path.bytes.count > root.bytes.count else {
            return false
        }
        guard path.bytes.starts(with: root.bytes) else {
            return false
        }
        return path.bytes[path.bytes.index(path.bytes.startIndex, offsetBy: root.bytes.count)] == separator
    }
}

public struct CanonicalAttribution: Codable, Equatable, Sendable {
    public let objectIdentity: FileIdentity
    public let path: RelativePath
    public let classification: InventoryClassification

    public init(objectIdentity: FileIdentity, path: RelativePath, classification: InventoryClassification) {
        self.objectIdentity = objectIdentity
        self.path = path
        self.classification = classification
    }
}

public enum HardLinkCanonicalizer {
    /// Chooses exactly one stable attribution path for each object. Stores must
    /// persist this result with a unique `(generation, object identity)` key.
    public static func canonicalAttributions(
        from paths: some Sequence<InventoryPath>
    ) -> [FileIdentity: CanonicalAttribution] {
        var selectedPaths: [FileIdentity: InventoryPath] = [:]
        for path in paths {
            if let existing = selectedPaths[path.objectIdentity] {
                if path.relativePath.bytes.lexicographicallyPrecedes(existing.relativePath.bytes) {
                    selectedPaths[path.objectIdentity] = path
                }
            } else {
                selectedPaths[path.objectIdentity] = path
            }
        }
        return selectedPaths.mapValues {
            CanonicalAttribution(
                objectIdentity: $0.objectIdentity,
                path: $0.relativePath,
                classification: $0.classification
            )
        }
    }

    /// Produces a zero-sum debit/credit pair when canonical attribution moves
    /// between ordinary and DailyDisk-owned namespaces. A same-class move has
    /// no allocation effect and therefore produces no transfer records.
    public static func attributionTransferRecords(
        runID: ScanRun.ID,
        source: ChangeSource,
        objectIdentity: FileIdentity,
        footprint: FileFootprint,
        from old: CanonicalAttribution,
        to new: CanonicalAttribution
    ) throws -> [ChangeRecord] {
        guard old.objectIdentity == objectIdentity, new.objectIdentity == objectIdentity else {
            throw ModelValidationError.inconsistentObjectIdentity
        }
        guard old.classification != new.classification else {
            return []
        }

        let kind: ChangeKind
        switch source {
        case .fsevents:
            kind = .eventAttributionTransfer
        case .reconciliation:
            kind = .reconciliationAttributionTransfer
        case .snapshotComparison:
            kind = .snapshotAttributionTransfer
        case .baseline:
            throw ModelValidationError.invalidChangeCombination
        }

        let transferID = UUID()
        return [
            try ChangeRecord(
                runID: runID,
                volumeID: objectIdentity.volumeID,
                objectIdentity: objectIdentity,
                kind: kind,
                pathBefore: old.path,
                pathAfter: new.path,
                transferID: transferID,
                effect: .attributionTransfer(footprint: footprint, direction: .debit),
                classification: old.classification
            ),
            try ChangeRecord(
                runID: runID,
                volumeID: objectIdentity.volumeID,
                objectIdentity: objectIdentity,
                kind: kind,
                pathBefore: old.path,
                pathAfter: new.path,
                transferID: transferID,
                effect: .attributionTransfer(footprint: footprint, direction: .credit),
                classification: new.classification
            ),
        ]
    }
}
