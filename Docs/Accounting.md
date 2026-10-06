# Space accounting

DailyDisk keeps filesystem-index accounting separate from APFS physical-capacity accounting. The numbers are related, but they are not interchangeable.

## Signed byte convention

All deltas use signed 64-bit byte counts:

- Positive means disk growth.
- Negative means shrinkage.
- Zero means no net allocation change.

Arithmetic is checked. An overflow fails the report instead of silently wrapping.

## Inventory measurements

Each indexed object stores:

- **Logical bytes** — the apparent file length (`st_size`).
- **Allocated bytes** — filesystem blocks attributed to the object (`st_blocks × 512`).

Directory reports primarily use allocated bytes. Logical bytes remain available to explain sparse files and similar cases.

Hard-linked paths share one `FileIdentity` (`volume + device + inode`). One deterministic path, selected by raw filesystem-byte ordering, receives object-size attribution. The persistence layer enforces one canonical attribution per object and generation. Other links remain in the path index but do not multiply the object's total.

Creating or removing a secondary hard link produces a path-only ledger entry with zero allocation delta. If deleting or renaming the canonical link selects a replacement in the same classification, the change remains zero. If canonical attribution crosses between an ordinary path and a DailyDisk-owned path, the ledger stores a matching debit/credit pair for the same object. The pair sums to zero physical bytes while preserving correct category totals.

APFS clones and shared extents cannot be deduplicated accurately with ordinary `stat` metadata. Consequently, indexed allocated bytes are an attribution signal rather than a claim about unique physical blocks.

## Daily-full target and accounting compatibility

Daily full scans compare previous committed inventory directly with the final logical inventory (staging for an initial/legacy build, or baseline plus daily inventory reuse deltas). `snapshotComparison` ledger records use addition/removal/modification/attribution-transfer kinds and contribute to `snapshotComparedDelta`. They are not event attribution or reconciliation errors. Same-day incremental checks and legacy recovery retain their existing decomposition. Existing reports remain readable after updates. Ordinary daily differences do not feed correction alerts.

```text
reconciledIndexedDelta = snapshotComparedDelta + eventAttributedDelta + reconciliationCorrection
```

The signed physical/file/overhead balance is unchanged. See [the design](DailyFullScan.md).

## Current persisted formulas

For ordinary files:

```text
eventAttributedDelta = sum(FSEvents-derived allocated deltas)
reconciliationCorrection = sum(full-scan reconciliation allocated deltas)
reconciledIndexedDelta = snapshotComparedDelta + eventAttributedDelta + reconciliationCorrection
```

DailyDisk-owned database, WAL, report, and log changes are classified separately:

```text
dailyDiskOverheadDelta = indexed DailyDisk-owned changes
                       + known unindexed DailyDisk writes
```

The change records and both capacity samples must cover the same APFS storage domain and sampling interval. DailyDisk rejects mixed-volume input or reversed sample timestamps rather than producing a plausible but invalid residual.

When both a current and previous APFS storage-domain sample exist:

```text
physicalUsedDelta = current physical used - previous physical used

physicalUnattributedDelta = physicalUsedDelta
                          - reconciledIndexedDelta
                          - dailyDiskOverheadDelta
```

If no physical baseline exists, both `physicalUsedDelta` and `physicalUnattributedDelta` are unknown (`nil`), not zero.

## Reconciliation correction

A full scan compares the event-maintained expected inventory with a newly scanned authoritative generation. Its signed correction is split into:

- `missedAdditions`: objects present in the full scan but absent from the expected index.
- `staleRemovals`: objects still in the expected index but absent from the full scan; normally negative.
- `sizeCorrections`: objects present in both with different allocated sizes; either sign.
- `attributionTransfers`: the ordinary side of canonical ownership moving between ordinary and DailyDisk-owned paths.

These signed categories must sum exactly to `reconciliationCorrection`.

A correction changes the inventory. For example:

```text
incremental indexed total: 412.37 GiB
full indexed total:        414.81 GiB
reconciliation correction:  +2.44 GiB
```

The sign is never clamped or converted to an absolute value.

## Physical unattributed change

Physical unattributed change does **not** modify inventory. Possible explanations include:

- APFS snapshots
- clone/shared extents
- filesystem metadata
- purgeable-space reporting
- inaccessible paths
- deleted files still held open by a process
- unmounted or special-role APFS volumes
- changes racing with metric collection

Reports may attach evidence for these causes, but must not assign the difference to a fabricated path.

## Commit integrity

A scan commit binds one volume checkpoint to the discovered volume's event-store UUID and topology fingerprint. Incremental cursors cannot regress or switch event stores, and a full/recovery activation on a persistent-event volume requires a trusted post-scan `liveFlush` fence. Inventory generation activation, its exact cursor, and ledger changes are therefore one validated unit.

Reports are persisted separately and idempotently after the referenced scan ledgers commit. A `ReportCommit` carries the exact domain scope, ledger changes, previous/current physical samples, and known DailyDisk overhead; its initializer recomputes accounting and reconciliation and rejects a contradictory report.

## Path representation

Inventory paths are stored relative to their volume as raw bytes. DailyDisk does not Unicode-normalize, case-fold, resolve symlinks, or accept `.`/`..` traversal components. Display strings are lossy views only; raw bytes remain authoritative.

daily inventory reuse keeps the active generation ID on subsequent daily full checks, but the before/after boundary is still the previous committed checkpoint versus the newly sealed inventory. Reusing storage does not turn the run into incremental accounting. Snapshot changes are derived and validated for candidate identities; unchanged objects contribute zero. Old-value recovery rows are storage metadata and never additional growth ledger entries. Physical and DailyDisk-overhead sampling boundaries remain unchanged.

## Report rankings and complete change records

Direct path deltas are netted by raw attribution path before ranking; transfer debits belong to the old canonical path and credits to the new path. Positive and negative allocated-byte rankings each retain ten direct paths. Directory-descendant rollups are ranked separately and overlap; they must not crowd out direct changes. Directory metadata can itself be a direct change. Logical-only changes remain available in the ledger even when allocation does not change.

The GUI summarizes five paths per direction and shows total net growth/release path counts. “全部变化记录” pages ordinary non-baseline ledger records without a size threshold, including zero-allocation path changes. These are recorded accounting transitions, not every filesystem write; repeated paths and balanced transfers can appear. Direction filters apply to each record, whereas summary counts describe net paths. JSON export is a bounded report summary.

Legacy reports lack the optional `pathRanking` field. The GUI rebuilds that summary read-only from the existing published ledger, without changing accounting, sample boundaries, historical JSON/Markdown files or schema. New scans publish separate rankings directly. No extra full inventory or detail ledger is persisted.
