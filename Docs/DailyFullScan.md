# Daily full scans

## Default execution

At 05:00 local time, the helper performs a full metadata scan. Login also evaluates due work; the app does not wake a powered-off Mac. A published full scan completed on the same local day satisfies daily work. Subsequent manual requests that day attempt incremental scanning; untrusted event history causes full recovery. Advanced full recheck explicitly requests a full scan.

Daily completion uses actual post-commit inventory completion and report publication, not scan start time. Delayed publication must not turn yesterday's inventory into today's completed full check. The opening baseline is an opening balance, not new file growth.

## Trusted scan boundary

Daily full scans establish a current-journal cursor E0 without replaying yesterday's history, stop that session, traverse, and replay only scan-time events from E0 through a trusted final E1. Validate volume, device, topology and journal identity before commit. Full scanning still needs scan-time event compensation; the checkpoint is an event-consistency boundary, not a resumable traversal position.

## Inventory reuse persistence

With an existing daily baseline, compare bounded batches against current inventory plus the run overlay; persist changed objects and paths only. An exact bounded in-memory seen bitmap detects deletions while preserving opaque subtrees. Unchanged records receive no daily last_seen or membership writes. Initial/legacy full scans may still construct a staging generation.

Commit changed old values, inventory mutations, signed ledger, samples and checkpoint atomically. All in-place incremental commits also preserve old values. Retention prunes only expired published version prefixes and protects referenced generations. Failed or interrupted observations restart after normal overlay cleanup. See [Database](Database.md) for details.

## Write management and measurement

Use FULL durability and bounded WAL checkpoints: 32 MiB soft target and 128 MiB inter-transaction guard. A single atomic transaction can exceed these thresholds. Scanner batches contain at most 1,024 records. Reuse free database pages; do not VACUUM every day. Automatic compaction retains the seven-day cooldown and free-space thresholds.

Logical file bytes, allocated file bytes, database size, process I/O and physical NAND writes are different quantities. Measure complete runs including publication and cleanup; keep compaction and upgrade backups identifiable. Do not infer SSD endurance from process counters or compare different workloads as matched A/B results. DailyDisk overhead is sampled at the existing report boundary; later cleanup does not retroactively alter that report.

## Verification

See [Testing](Testing.md) for synthetic regression gates and opt-in write workloads, and [Installation](Installation.md) for signed upgrades. Validate same-day policy, midnight boundaries, opaque preservation, E0–E1 loss, hard links, transaction rollback, report recovery and retained-history expiry. Real-system performance depends on file count, churn, permissions, caches and concurrent activity.
