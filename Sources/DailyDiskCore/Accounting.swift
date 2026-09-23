import Foundation

public enum AccountingError: Error, Equatable, Sendable {
    case overflow(operation: String)
}

public enum AccountingMath {
    public static func add(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw AccountingError.overflow(operation: "\(lhs) + \(rhs)")
        }
        return result
    }

    public static func subtract(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (result, overflow) = lhs.subtractingReportingOverflow(rhs)
        guard !overflow else {
            throw AccountingError.overflow(operation: "\(lhs) - \(rhs)")
        }
        return result
    }

    public static func multiply(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else {
            throw AccountingError.overflow(operation: "\(lhs) * \(rhs)")
        }
        return result
    }

    public static func sum<S: Sequence>(_ values: S) throws -> Int64 where S.Element == Int64 {
        try values.reduce(0) { partial, value in
            try add(partial, value)
        }
    }

    public static func allocatedBytes(blockCount: Int64, blockSize: Int64 = 512) throws -> Int64 {
        guard blockCount >= 0, blockSize >= 0 else {
            throw ModelValidationError.negativeByteCount
        }
        return try multiply(blockCount, blockSize)
    }
}

public enum ChangeSetValidator {
    public static func validateAttributionTransfers(in changes: [ChangeRecord]) throws {
        let transfers = changes.filter { $0.transferID != nil }
        let groups = Dictionary(grouping: transfers, by: { $0.transferID! })

        for records in groups.values {
            guard records.count == 2,
                let debit = records.first(where: { record in
                    if case .attributionTransfer(_, .debit) = record.effect { true } else { false }
                }),
                let credit = records.first(where: { record in
                    if case .attributionTransfer(_, .credit) = record.effect { true } else { false }
                }),
                debit.runID == credit.runID,
                debit.objectIdentity == credit.objectIdentity,
                debit.kind == credit.kind,
                debit.pathBefore == credit.pathBefore,
                debit.pathAfter == credit.pathAfter,
                debit.classification != credit.classification,
                debit.logicalDelta == -credit.logicalDelta,
                debit.allocatedDelta == -credit.allocatedDelta
            else {
                throw ModelValidationError.unbalancedAttributionTransfer
            }

            guard case .attributionTransfer(let debitFootprint, .debit) = debit.effect,
                case .attributionTransfer(let creditFootprint, .credit) = credit.effect,
                debitFootprint == creditFootprint
            else {
                throw ModelValidationError.unbalancedAttributionTransfer
            }
        }
    }
}

public enum SpaceAccounting {
    /// Calculates a summary for exactly one APFS storage domain and sampling
    /// interval. All supplied volume IDs must belong to `currentSample`'s
    /// domain; callers obtain that set from the discovered topology.
    public static func summarize(
        changes: [ChangeRecord],
        scope: StorageDomainScope,
        previousSample: StorageSample?,
        currentSample: StorageSample,
        additionalDailyDiskOverheadDelta: Int64 = 0
    ) throws -> AccountingSummary {
        try ChangeSetValidator.validateAttributionTransfers(in: changes)
        guard currentSample.storageDomainID == scope.domain.id,
            changes.allSatisfy({ scope.volumeIDs.contains($0.volumeID) })
        else {
            throw ModelValidationError.mismatchedStorageDomain
        }

        let physicalUsedDelta: Int64?
        if let previousSample {
            guard previousSample.storageDomainID == currentSample.storageDomainID else {
                throw ModelValidationError.mismatchedStorageDomain
            }
            guard previousSample.sampledAt < currentSample.sampledAt else {
                throw ModelValidationError.invalidSampleChronology
            }
            physicalUsedDelta = try AccountingMath.subtract(currentSample.usedBytes, previousSample.usedBytes)
        } else {
            physicalUsedDelta = nil
        }

        let ordinaryChanges = changes.filter { $0.classification == .ordinary }
        let eventAttributedDelta = try AccountingMath.sum(
            ordinaryChanges.lazy
                .filter { $0.source == .fsevents }
                .map(\.allocatedDelta)
        )
        let reconciliationCorrection = try AccountingMath.sum(
            ordinaryChanges.lazy
                .filter { $0.source == .reconciliation }
                .map(\.allocatedDelta)
        )
        let reconciledIndexedDelta = try AccountingMath.add(
            eventAttributedDelta,
            reconciliationCorrection
        )

        let recordedDailyDiskOverhead = try AccountingMath.sum(
            changes.lazy
                .filter { $0.classification == .dailyDiskInternal && $0.source != .baseline }
                .map(\.allocatedDelta)
        )
        let dailyDiskOverheadDelta = try AccountingMath.add(
            recordedDailyDiskOverhead,
            additionalDailyDiskOverheadDelta
        )

        let physicalUnattributedDelta: Int64?
        if let physicalUsedDelta {
            physicalUnattributedDelta = try AccountingMath.subtract(
                try AccountingMath.subtract(physicalUsedDelta, reconciledIndexedDelta),
                dailyDiskOverheadDelta
            )
        } else {
            physicalUnattributedDelta = nil
        }

        return try AccountingSummary(
            eventAttributedDelta: eventAttributedDelta,
            reconciliationCorrection: reconciliationCorrection,
            reconciledIndexedDelta: reconciledIndexedDelta,
            dailyDiskOverheadDelta: dailyDiskOverheadDelta,
            physicalUsedDelta: physicalUsedDelta,
            physicalUnattributedDelta: physicalUnattributedDelta
        )
    }

    public static func reconciliationBreakdown(
        from changes: [ChangeRecord]
    ) throws -> ReconciliationBreakdown? {
        try ChangeSetValidator.validateAttributionTransfers(in: changes)
        let reconciliationChanges = changes.filter {
            $0.source == .reconciliation && $0.classification == .ordinary
        }
        guard !reconciliationChanges.isEmpty else {
            return nil
        }

        let additions = try AccountingMath.sum(
            reconciliationChanges.lazy
                .filter { $0.kind == .reconciliationAddition }
                .map(\.allocatedDelta)
        )
        let removals = try AccountingMath.sum(
            reconciliationChanges.lazy
                .filter { $0.kind == .reconciliationRemoval }
                .map(\.allocatedDelta)
        )
        let corrections = try AccountingMath.sum(
            reconciliationChanges.lazy
                .filter { $0.kind == .reconciliationCorrection }
                .map(\.allocatedDelta)
        )
        let transfers = try AccountingMath.sum(
            reconciliationChanges.lazy
                .filter { $0.kind == .reconciliationAttributionTransfer }
                .map(\.allocatedDelta)
        )

        let breakdown = ReconciliationBreakdown(
            missedAdditions: additions,
            staleRemovals: removals,
            sizeCorrections: corrections,
            attributionTransfers: transfers,
            affectedRecords: reconciliationChanges.count
        )
        let total = try AccountingMath.sum(reconciliationChanges.map(\.allocatedDelta))
        guard try breakdown.correction == total else {
            throw ModelValidationError.inconsistentReconciliationBreakdown
        }
        return breakdown
    }
}
