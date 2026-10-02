# Daily full scans: design and write-budget review

Status (2026-10-01): daily-full source implementation and synthetic validation. Installed acceptance is recorded separately below; a source change does not update an existing LaunchAgent. UUID root-cause investigation is no longer the priority. Existing diagnostics and trusted fences are preserved.

## Default execution

The source now implements one automatic full scan per local calendar day at **05:00**, with incremental scanning reserved for subsequent explicit requests after a full inventory completed that day and its report was published. This replaces the old incremental-first/seven-day reconciliation design.

| Request/state | Target behavior |
| --- | --- |
| Due scheduled request, no successful full scan today | Direct full scan |
| Due scheduled request, successful full scan today | Skip redundant automatic work |
| Manual check, no successful full scan today | Full scan, including before 05:00 |
| Manual check, successful full scan today | Attempt incremental; trusted-history failure falls back to full |
| Explicit advanced full recheck | Full scan regardless of same-day completion |
| Existing scan in progress | Attach to it; do not launch duplicate writers |
| Failure/cancellation | Does not satisfy today's successful-full requirement; later retry remains possible |
| Powered off/asleep at 05:00 | Catch up at the next eligible login/wake invocation; no guaranteed wake-up |

Use local calendar dates, not elapsed 24-hour intervals: a scan finishing at 05:22 must not make tomorrow's 05:00 request incremental. A manual full scan completed before 05:00 satisfies that day's automatic requirement after report publication. A successful incremental alone does not replace the daily-full requirement. Preserve due-date deduplication, report recovery before new work, one writer and no persistent retry loop. Failed/cancelled work must not erase a prior successful full for the same day. Cover midnight-spanning completion, DST and time-zone changes explicitly in the policy tests; persist enough completion/report information to avoid deriving daily success from scan start or a proposed commit alone. Maintenance actions remain independent of scan selection.

The legacy `FullScanMode.scheduled` still replays previous committed history, but default selection now uses the distinct `FullScanMode.daily` path: establish a trusted E0 from the current journal, scan staging, replay E0–E1 into staging, verify identity/topology and atomically activate. Journal loss during this window still invalidates the scan. Preserve opaque inventory, hard-link canonicalization and mount boundaries.

The daily path compares previous committed inventory directly with final staging. Schema 7 persists snapshot-comparison change kinds and `snapshotComparedDelta`, separately from event attribution and reconciliation correction. The GUI and Markdown export expose this distinction; correction alerts continue to use correction bytes alone. Old report payloads retain their meaning and decode absent snapshot bytes as zero. No inventory reset is needed. Opaque preservation reads the baseline through an empty target descriptor; daily comparison does not build or seal an expected-active event overlay.

## Implementation order

1. **Daily-full policy and accounting.** Update LaunchAgent schedule, due gate, request selection, GUI text and installation/lint tests together for 05:00. Implement current-journal E0–E1 full scanning and baseline/staging comparison before making it the default. Preserve report recovery, cancellations, opaque paths and hard links. Define persistence/UI/alerts for directly observed daily changes without rewriting old reports. Establish the unchanged-storage write baseline for this new path.
2. **Bounded checkpointing and batch sizes.** Compare the same workload before/after removing per-transaction forced TRUNCATE. Coordinate SQLite automatic checkpoints with explicit bounded WAL management, final checkpoints and reader lifetime. Retain FULL durability. Compare 512/1024 batches, write bytes, wall time, memory, WAL peaks and cancellation latency. Require crash and strict-CLI tests before production adoption.
3. **Space-maintenance tuning.** Measure retirement deletion separately from compaction over successive full scans. Prefer free-page reuse; retain the recovery window and existing compression cooldown until measurements justify changes. Never introduce daily unconditional VACUUM.
4. **Installed acceptance.** Upgrade GUI/helper and registered schedule together using the existing signing identity. Verify 05:00/catch-up, same-day manual incremental and failure fallback, then measure one due full helper run through final cleanup. Compare real I/O with the synthetic baseline; do not repeatedly scan real user data merely to benchmark variants.

Later experiments: bulk metadata traversal, bounded parallelism and cross-generation reuse of unchanged records. These are not prerequisites for the four rounds, and speed alone is not proof of reduced writes.

## Two different checkpoints

An FSEvents checkpoint binds a trusted applied event cursor and journal UUID to the active inventory. SQLite WAL checkpointing transfers committed database pages from WAL to the database file. Neither is a saved directory-walk position: interrupted staging is cleaned up and full traversal restarts. Crash-safe commits still require WAL/transaction durability. Remove the old cross-day event-history dependency from daily full scans, and reduce the frequency of forced WAL checkpoints; do not delete trusted scan-time fences or all WAL management.

## Optimization priorities

1. **Bounded WAL checkpointing (first write-budget experiment).** The pre-refactor baseline TRUNCATE-checkpointed after each transaction and emitted 512-record batches. Repeated checkpoints can write the same upper index pages repeatedly. Test a bounded WAL threshold and checkpoints at explicit publication/close/maintenance boundaries. Preserve `synchronous=FULL`, writer leases, crash recovery, and strict CLI refusal while WAL is nonempty. Do not simply disable checkpoints: WAL growth must be bounded, and read-only GUI snapshots can hold readers open.
2. **Batch size.** Compare 512/1024 records with the same fixture and cache configuration; measure write bytes, elapsed time, peak memory/WAL and cancellation latency. The existing million-row fixture uses 1024, so its result is not a direct measurement of the 512-record production traversal.
3. **Reuse free database pages.** Daily generation replacement naturally needs reusable capacity. Keep retention and the existing >1 GB, >25%, seven-day automatic VACUUM gates. Do not compress after every daily scan. Measure expiry/deletion separately from VACUUM before changing thresholds. Keep the 24-hour recovery window until a replacement design is tested.
4. **Avoid duplicate inventory work.** A direct baseline/staging comparison can avoid maintaining and sealing an event-derived expected inventory. Shared parent/name nodes already reduce path duplication; per-generation objects/order still account for substantial writes. Reusing unchanged objects via revisioned storage is a later, higher-risk schema experiment, not a prerequisite for daily full scans.
5. **Traversal throughput.** `getattrlistbulk` and bounded parallel traversal are potential runtime improvements, not proven SSD-wear improvements. They need equivalence tests for dataless entries, opaque directories, symlinks, hard links, mount changes and cancellation. Prioritize measured database writes first.
6. **Keep small operational writes bounded.** Progress/diagnostic throttling and report retention remain useful, but are unlikely to dominate million-row inventory writes. Do not remove recovery markers or truthful progress to save negligible bytes.

## Measurement and limits

The opt-in production-store million-row test now reports `WRITE_METRIC` deltas from Darwin `proc_pid_rusage(RUSAGE_INFO_V2).ri_diskio_byteswritten`. Run it alone, after building, so other tests do not share the counters:

```sh
swift test --filter systemProcessRunnerStopsWork
DAILYDISK_RUN_STRESS=1 swift test --skip-build --filter millionRecordInventory
```

Counters cover this test process, not SSD NAND program/erase cycles or writes attributed to other processes. Separate initial insertion, insertion-through-commit, replacement activation/report, and forced maintenance. Cycle 1's staging was constructed before the cycle counter starts; cycle 2 includes staging. Forced maintenance includes retirement cleanup, verification and VACUUM, not just VACUUM. The synthetic zero-change fixture does not include live filesystem enumeration, native event replay, real path distributions or a large change ledger. File size, peak allocation and cumulative writes are different quantities.

For installed acceptance, instrument one actual full helper run from before preparation through cleanup, with the same process counters and phase deltas. Avoid extra real scans merely for repeated benchmarks: compare alternatives on synthetic data, then sample one already-due scheduled run. If device-wide host-write counters are available, record them before/after with background activity noted; they cannot uniquely attribute unrelated writes to DailyDisk. Do not infer a Mac SSD's TBW rating from another vendor/model.

Annual host-write budget = measured bytes per run × runs per year; five-year budget = that × 5. NAND write amplification and model-specific endurance remain unknown without device telemetry. No claim of zero wear or a precise remaining lifespan follows from this benchmark.

## Acceptance before changing the default

- Daily scheduling selects full even when yesterday finished after today's start time.
- Previous UUID replacement does not require replay of old history; replacement during E0–E1 still fails safely.
- Baseline is an opening balance; daily positive/negative changes and opaque/hard-link behavior remain correct.
- Cancellation/crash leaves prior generation and checkpoint active; report recovery remains idempotent.
- Growth from full comparison does not spuriously trigger reconciliation-correction alerts.
- Compare write counts under the same fixture and phase boundaries, retaining FULL durability. Run actual installed acceptance once after synthetic checks.

## First measured baseline (2026-10-01)

Isolated `millionRecordInventory` passed in 475.784 seconds, using the production store and synthetic data. Decimal units below (GB = 10^9 bytes):

| Measured phase | Kernel process write bytes | GB |
| --- | ---: | ---: |
| Initial append (including store setup) | 1,682,034,688 | 1.682 |
| Initial append through activation (includes preceding row) | 2,910,666,752 | 2.911 |
| Cycle 1 activation/report (excludes already-built staging) | 978,718,720 | 0.979 |
| Cycle 1 forced cleanup/verification/compaction | 2,347,081,728 | 2.347 |
| Cycle 2 staging/seal/activation/report | 3,768,950,784 | 3.769 |
| Cycle 2 forced cleanup/verification/compaction | 2,300,764,160 | 2.301 |

Compacted allocation after each cycle was 396,828,672 bytes. Cycle 2 writes before maintenance were about 9.5 times that allocation; forced maintenance added another 2.30 GB. This ratio is process writes versus final allocation, **not SSD NAND write amplification**. The full-diff workload earlier in the test took 27.305 seconds, and opaque preservation took 75.956 seconds; timings vary with machine load and are not the elapsed time of a real daily scan.

At one identical cycle-2 pre-maintenance workload per day, the arithmetic is 1.376 TB/year or 6.88 TB over five years. This is an illustrative budget for this synthetic phase, not an estimate of this Mac's 2.26-million-object full helper run or its lifetime. Forced maintenance is separately measured and must not be assumed daily. The current data identifies measurable costs; it does not yet prove how much a checkpoint/batching optimization saves. No production durability or checkpoint policy changed in that initial measurement round; subsequent implementation is recorded below.

## Implemented policy and persistence

`ScanPolicy` and `DueTimeGate` share a local calendar. A full/recovery inventory satisfies its actual post-COMMIT completion date once its report is published, including scans spanning midnight. Delayed report recovery does not move completion to the publication date. Pending publication and incrementals alone do not count. Later failures/cancellation cannot erase earlier full success. Migration 007 preserves all old payloads and inventory; historical timestamps use stored finish/report dates because actual boundaries were not recorded. New `inventory_completed_at` markers are written after COMMIT, separately from `published_at`. A crash or failure before this follow-up marker leaves completion unknown and does not satisfy the daily gate; it never invalidates an already committed inventory. Idempotent retries do not move a persisted publication date.

Daily E0 opens without the old checkpoint, and only E0–E1 replay mutates staging. The final volume/device/topology/journal identity and trusted cursor are checked before atomic activation. The store rederives the snapshot ledger rather than accepting aggregate equality. Initial inventory remains an empty-ledger opening balance. Incremental-history failure still uses existing recovery diagnostics.

## WAL and batch experiment (100,000 records)

Same synthetic path/object fixture, three consecutive unchanged full inventories, direct baseline/staging comparisons, report persistence and expired-generation deletion. Expiry uses a future maintenance clock solely in the fixture; production still retains the newest retired inventory for 24 hours. Each variant ran in isolation; the table is the final clean-build rerun, including post-commit completion markers. Decimal MB below; phase counters can shift buffered writes into a subsequent phase, so compare cumulative totals as well as individual phases.

| Configuration | Three scans + deletion writes | Final forced maintenance writes | Total test time | Sampled WAL peak | Sampled resident peak |
| --- | ---: | ---: | ---: | ---: | ---: |
| Per-transaction TRUNCATE, 512 records | 1,063.32 MB | 68.60 MB | 19.89 s | 34.36 MB | 144.05 MB |
| Bounded WAL, 512 records | 728.12 MB | 68.58 MB | 18.43 s | 63.57 MB | 105.28 MB |
| Bounded WAL, 1024 records | 663.98 MB | 68.58 MB | 17.82 s | 62.23 MB | 147.24 MB |

The selected 1024/bounded configuration reduced pre-compaction process writes by about 37.6% in this fixture. This is one synthetic observation per variant, not a universal speedup or NAND-wear measurement. The fixture omits actual traversal and event replay. Scanner cancellation is tested separately with both batch sizes and remains checked at directory chunks, not only batch publication.

Production store connections now disable SQLite auto-checkpointing and request a nonblocking checkpoint at 32 MiB. If a reader prevents progress and WAL reaches 128 MiB, the next write transaction first attempts a bounded-wait checkpoint and fails before BEGIN if still pinned. A single atomic transaction can exceed either threshold; these are inter-transaction limits, not an absolute WAL-size cap. Publication and writer close request final truncation. Busy final readers may defer it, and strict CLI inspection continues to refuse nonempty WAL. `synchronous=FULL` and atomic commit/fence semantics remain unchanged.

The deletion/space experiment supports free-page reuse: after the second and third inventories, about 50.65/51.64 MB of a 90.22/91.21 MB database was reusable; deleting records did not shrink the file. A final forced maintenance step reduced allocation to about 34.3 MB and wrote another 68.6 MB. Forced compaction is a measurement step, not a daily production action. The 24-hour retention window and >1 GB / >25% / seven-day compaction gates remain unchanged.

Reproduce separately (after building tests):

```sh
DAILYDISK_DAILY_WRITE_TEST=1 DAILYDISK_WRITE_WAL=legacy DAILYDISK_WRITE_BATCH=512 swift test --skip-build --filter dailyFullWriteBudget
DAILYDISK_DAILY_WRITE_TEST=1 DAILYDISK_WRITE_WAL=bounded DAILYDISK_WRITE_BATCH=512 swift test --skip-build --filter dailyFullWriteBudget
DAILYDISK_DAILY_WRITE_TEST=1 DAILYDISK_WRITE_WAL=bounded DAILYDISK_WRITE_BATCH=1024 swift test --skip-build --filter dailyFullWriteBudget
```

Set `DAILYDISK_WRITE_ROWS=1000000` for the million-row variant. Helper probes now include process disk-write counters at helper start/end, request boundaries and phase changes. Subtract counters only within one process identity. They include that helper’s other work, but exclude notification child processes and do not measure NAND writes. Use a naturally due helper run for installed acceptance rather than repeated real scans.

## Million-row daily-path validation

Before the final completion-marker refinement, the selected bounded/1024 storage variant passed three million-row inventories in 200.56 seconds. Initial scan/seal/activation/report wrote 1.961 GB in 45.01 s; replacements wrote 1.888/2.120 GB in 57.93/59.01 s. Expired-generation deletion separately wrote 0.941/0.971 GB in 7.74/7.46 s. The final forced maintenance wrote 0.925 GB in 15.15 s and left about 344.13 MB allocated. After replacements the database was 910.17/918.49 MB with 511.93/520.22 MB reusable. Sampled WAL peak was 345.42 MB and resident memory peak 205.73 MB. The WAL peak exceeds the inter-transaction guard because large atomic transactions are allowed to complete; no claim of a 128 MiB absolute cap is made.

This is production storage, direct snapshot ledger validation and report persistence, with synthetic unchanged files. It does not exercise real traversal, native scan-time replay or notification children. Do not compare its elapsed time directly with the older 475.78-second workload, which exercises additional opaque/incremental operations and two forced maintenance cycles.

Installed acceptance update (2026-10-01): Computer Use access is now working. Removed the old job through Settings, quit the GUI, and installed GUI/helper/CLI together at the original path with the same persistent signing identity. All three designated requirements match and deep strict verification passes. Re-registered through Settings; both GUI and launchd now show 05:00 (Hour 5, Minute 0). The RunAtLoad helper migrated schema 6 to 7, recognized today's published full report, returned skippedNotDue and exited with status 0; no additional inventory scan was launched. Lease-protected comparison preserved the active checkpoint and all nine historical reports. Notification permission remains allowed; the GUI disk-access probe reports three accessible protected locations and zero denials. Overview and the nine-report history page render correctly with paths hidden by default. Fixed the stale advanced-settings seven-day description to daily 05:00 and rebuilt/reinstalled; format, LaunchAgent and whitespace checks pass. The final post-install source suite passed all 275 tests in 7.086 seconds (four opt-in workloads disabled). Installed strict CLI verification also passed: integrity ok, schema 7, zero foreign-key/inventory/report violations and zero abandoned runs. This supersedes the prior Computer Use blocker and not-installed status. The remaining acceptance item is whole-helper write measurement during one naturally due full scan; do not repeat real scans just for benchmarking.


## 2026-10-02 production write follow-up

The first observed scheduled helper wrote approximately 16.39 GB from helperStarted to helperFinished; traversal/insertion accounted for approximately 11.63 GB. These process counters supersede extrapolations from the smaller synthetic fixture, not the fixture measurements themselves. See [the fresh write-path review and ordered experiments](WriteOptimizationReview.md) for confirmed duplication, hypotheses, measurement limits and preservation requirements. No further write optimization was implemented in that review.
