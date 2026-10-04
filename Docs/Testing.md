# Testing and release gates

## Validation scope

Use [Installation](Installation.md) to provision a source-build machine. Minimum declared support is macOS 15/Swift 6. CI is configured on `macos-15` but does not validate FDA, notification grants, Intel hardware, or another user's fresh installation. History-page visual acceptance remains an open gate. Do not turn local observations into cross-machine performance guarantees.

## Automated PR suite

Run:

```bash
swift format lint --recursive Sources App Tests
swift build
swift test
Scripts/lint-launch-agent.sh
ALLOW_ADHOC_SIGNING=1 Scripts/build-app.sh
DAILYDISK_DRY_RUN=1 build/DailyDisk.app/Contents/Helpers/DailyDiskAgent
codesign --verify --deep --strict build/DailyDisk.app
```

The suite covers:

- checked signed accounting and report invariants
- SQLite migrations, composite foreign keys, generation/checkpoint atomicity, WAL rollback, and recovery
- semantic ledger validation and same-net false-ledger rejection
- APFS container/volume-group parsing and external-device exclusion
- descriptor-relative full/subtree scanning, symlinks, sparse files, hard links, permissions, and scan races
- real local FSEvents live flush and stopped-session historical replay outside CI
- incremental/full equivalence using a complete staging-generation diff
- directory replacement, MustScan subtree repair, hard-link removal, journal replacement, and full-scan race replay
- snapshot, deleted-open-file, overhead, physical diagnosis, reports, alerts, cooldown, retention, and privacy
- read-only CLI executable behavior, path consent, exit classes, and byte-for-byte no-write inspection
- LaunchAgent plist semantics, due-time behavior, exact non-destructive kickstart/status/stop arguments, helper shutdown handshake, packaging, and dry-run
- private control protocol permissions/schema/atomic claim/restart, progress privacy/order/throttling, commit cancellation boundary, and run binding
- GUI controller enqueue/reconnect/cancel/finishing/external-writer state; inspection waiting/verify/path disclosure; safe reset lease/root/symlink behavior

## Manual stress workflow

The GitHub `Stress tests` workflow runs the opt-in million-row test:

```bash
DAILYDISK_RUN_STRESS=1 swift test --filter millionRecordInventory
```

It streams one million records in batches of 1,024 through SQLite staging, stages 128 scan-time removals, seals canonical attribution, commits the opening generation/checkpoint, and verifies the remaining object/canonical counts. The exact object counter is disk-backed, so scanner memory does not retain every identity. Capture `time -l` or Activity Monitor memory when changing scanner/store batching.

The ordinary suite also verifies canonical pagination across multiple pages, including signed storage of UInt64 inode boundary values. Canonical pages must seek by the composite identity key instead of repeatedly scanning the run prefix.

## Crash and recovery matrix

Automated tests inject SQLite failure at checkpoint update and assert inventory, ledger, samples, run status, generation, and checkpoint all roll back. Startup recovery tests abandoned staging runs. Before release, repeat these subprocess checks:

1. Kill `DailyDiskAgent` during full staging: the prior active generation/checkpoint must remain.
2. Kill during incremental mutation staging: restart must replay from the prior event ID.
3. Kill during full activation: reopening must expose either the complete old tuple or complete new tuple, never mixed state.
4. Kill after scan commit but before report commit: request/run binding plus `latestUnreportedBasis` must publish the exact report without a duplicate scan.
5. Kill after progress or summary persistence: restart must idempotently finalize control state and remove the active marker.
6. Close/reopen the GUI during scanning and cancellation: the app must reconstruct phase/count/cancellation from Control files.
7. Leave a nonempty WAL deliberately: strict `dailydiskctl` inspection must refuse it rather than read stale pages.

## Signed app and Full Disk Access checklist

These checks require a persistent local signing identity and cannot run safely on ordinary hosted CI:

1. Build twice with the same `CODE_SIGN_IDENTITY` and bundle identifier.
2. Compare `codesign -d -r-` designated requirements for both app builds and both `DailyDiskAgent` helpers.
3. Install to `/Applications/DailyDisk.app` using `Scripts/build-app.sh --install`.
4. Grant Full Disk Access to the installed app and enable notifications interactively.
5. Rebuild/install with the same identity; verify protected-directory probes remain available.
6. Confirm an intentionally different identity does not inherit the grant.
7. Register the agent, inspect it with:

   ```bash
   launchctl print gui/$UID/io.github.xiuyuwu.DailyDisk.agent
   ```

8. In a disposable test account, inject dry-run state into the launchd user domain, kickstart, then remove it and verify the helper exits without a window or resident process:

   ```bash
   launchctl setenv DAILYDISK_DRY_RUN 1
   launchctl kickstart gui/$UID/io.github.xiuyuwu.DailyDisk.agent
   launchctl unsetenv DAILYDISK_DRY_RUN
   ```
9. Deny notification permission and verify scan/report success remains unaffected.
10. For the planned rollout, exercise sleep past 05:00 and confirm the next eligible login/wake invocation runs once. Current installed behavior remains 09:00 until the schedule is changed; do not report the 05:00 gate as passed against that build.
11. In the GUI, click **立即检查** after a same-day report and confirm a new run/report is created; close/reopen during the scan and cancel once before commit.

## Real-system acceptance

On an internal APFS Mac:

- System is metrics-only and `/System/Volumes/Data` is the only full root.
- External USB APFS containers are absent from monitored domains.
- Root-only opaque subtrees remain preserved across weekly reconciliation.
- FSEvents journal replacement triggers topology refresh and a fresh SinceNow full scan.
- Reports show signed correction separately from physical unattributed change.
- No full file paths appear in notifications, Unified Logging events, default CLI output, or JSONL operational logs.

## UI observability regression gates

- Fractional worker start dates survive whole-second Control JSON round trips through commit and completion.
- Scheduled due, not-due, cancelled and report-recovery runs use a real Control store and finish without stale active markers.
- An idle GUI discovers a new scheduled run, reconnects, and requests cancellation only before commit.
- A stale snapshot with a stopped helper becomes an interruption, without automatic kickstart retries.
- The first screen displays setup failures and progress above results; one primary action guides setup/check/retry.
- Verify the installed signed app with real baseline, file growth, removal and GUI reopen checks. Never commit the real report or inventory.

### Generation cleanup

A composite path/object lookup index and a generation-delete trigger remove canonical rows and paths in sets before removing objects. SQLite can otherwise prefer a generation-only lookup even when a more selective index exists; deleting a large failed/staging generation then repeatedly scans its entire path set. The trigger keeps foreign keys and transaction rollback intact, including protection of the active checkpoint. Regression coverage tests migration and cancels a 10,000-record staging generation while preserving the active baseline.

Overview refresh uses lightweight WAL-aware read-only queries. Complete database verification and table-size diagnostics run only via **设置 → 诊断 → 验证数据库** (or the strict CLI); opening the app must not trigger a full integrity scan or prevent recovery of a nonempty WAL. An unverified overview is never labeled healthy.

FSEvents callbacks are accepted as whole batches under one mailbox lock. Historical file-event IDs can arrive unsorted: consume every callback through HistoryDone and a synchronous native flush before sealing a cursor, rather than treating callback arrival order as journal loss. Flush work runs off the main/cooperative executor. HistoryDone is a control sentinel, not a filesystem event ID. UUID changes, dropped/wrapped events, buffer overflow, and IDs below the committed cursor still require recovery. Coalesced create/remove flags reconcile missing endpoints, distinct observed identities, and single-link replacements from current metadata; ambiguous shared inode aliases still require recovery. Regression coverage includes unsorted batches, a burst of real FSEvents, and single-link versus hard-link replacement.

Observed inode reuse may proceed only when the run overlay contains no surviving paths for the old identity; surviving aliases still force recovery. Subtree paging uses explicit lower/upper path bounds plus an exact descendant predicate so SQLite seeks into the path index rather than rescanning an entire generation for every changed directory. Tests retain adjacent names such as `cache-neighbor`, `cache.more`, and `cache0`.

Before full-generation orphan cleanup, the writer refreshes inventory-path statistics with `ANALYZE inventory_paths` and a 1,000-row-per-index analysis limit. Without statistics, SQLite can choose a generation-only scan for foreign-key cascades despite the composite identity index. A populated synthetic regression verifies identity-bounded child lookups. Statistics are SQLite-managed metadata.

On restart, a persisted committing phase with a still-running SQLite scan is treated as an interrupted transaction, not committed-report recovery. The helper publishes non-cancellable failure cleanup, removes abandoned staging, and only then resumes inventory work for that request. Progress counters remain cumulative across recovery attempts. Ordinary cancellation remains forbidden during commit; cleanup is entered only after rollback or after the new helper owns the writer lease.

Overlay path queries keep the path table first with `CROSS JOIN` before looking up object metadata. This preserves path-range seeks even when only inventory paths have refreshed statistics. The million-row test also performs 32 narrow incremental subtree removals after activation, with a 10-second lookup budget to detect whole-object rescans.

Incremental accounting treats an object created and removed during the same replay as no net transition. A synthetic regression covers candidates with neither a baseline nor a final attribution, avoiding an optional-unwrapping crash. GUI polling preserves the immediate requesting state while a manual launch is still being submitted.

Incremental commit limits orphan cleanup to the sealed run’s candidate identities (both previous path identities and object mutations). Full-generation cleanup remains available for full scans. The million-row regression commits 32 incremental removals with a 10-second commit budget and verifies remaining object/canonical counts and checkpoint activation.

Incremental orphan cleanup reuses full-scan path statistics. It does not rerun ANALYZE: on the system SQLite, counting a WITHOUT ROWID table can still read its pages despite a bounded index sample.

### Overlay paging performance regression

Regular coverage includes multi-page base/overlay merging with dense deletions, replacements, additions, overlapping roots and adjacent path names; cancellation between preservation batches; and persisted progress with fractional timestamps and legacy counter decoding. The opt-in million-row test now also copies the surviving inventory through opaque preservation and performs a full zero-difference comparison. Test budgets are 120 seconds and 60 seconds respectively.

Installed recovery validation after the paging repair completed successfully across approximately 2.4 million visited paths in 32 minutes 16 seconds. The 214 opaque roots were processed in approximately one second (no historical paths needed copying). The remaining major full-scan costs were traversal, canonical/index preparation and atomic persistence; the fix does not make full recovery instantaneous. Reports were published and the helper exited normally. Post-run inspection found no active runs, an empty WAL, and a checkpoint journal UUID matching the current device. The pre-run full integrity/foreign-key/invariant/report verification was healthy. Regular coverage passed all 208 enabled tests, the million-row stress test passed separately, and GitHub CI passed. Final synthetic preservation/diff timings were 13.6/9.8 seconds.

## Space maintenance regression gates

Migration tests preserve checkpoints and exercise retention timestamps at fractional precision. Synthetic fixtures cover expiry boundaries, pending reports, running scans, rollback of cascaded cleanup, long paths, non-UTF-8 hard-link aliases, space preflight failure, writer contention, and report/checkpoint preservation through real VACUUM. A subprocess test kills `/usr/bin/sqlite3` during VACUUM WAL writes and verifies reopened inventory/report integrity; it uses only a temporary synthetic database.

Platform/App coverage exercises the distinct `reclaimSpace` request, persisted fractional-time progress, cancellation closure, GUI reconnect, zero-domain `maintenanceCompleted`, explicit insufficient-space errors, and interrupted manual maintenance without automatic re-compression. Normal overview polling still does not run storage analysis or full verification.

The opt-in million-row test now uses long shared path prefixes. It retains its 10-second incremental lookup and commit budgets, then commits two authoritative generations, publishes reports, expires retired inventories and performs compaction twice. It records staged/retained/compacted allocated bytes and activation/maintenance time. A 50 ms sampler measures database/WAL/SHM allocation peaks by phase; this is not a measurement of all OS temporary files or a production scanner peak. All fixtures are synthetic and removed afterward.

## Second-round storage layout experiments

Run the isolated million-row layout comparison with:

```bash
DAILYDISK_RUN_LAYOUT_STRESS=1 swift test --filter millionRecordLayoutComparison
```

This opt-in test complements the existing `millionRecordInventory` end-to-end store test; it does not replace it. Five layouts use identical long raw paths, UUID-length external IDs and hot inventory metadata. Each builds one million rows in batches of 1,024, adds ten non-UTF-8 hard-link aliases, seals canonical attribution, activates a checkpoint, then repeats with 10% renamed paths and selected replaced identities; classification changes are covered separately by ordinary tests. Measurements cover compacted one-/two-generation pages, generation build/seal, narrow lookups, 32 candidate-bounded incremental deletions, full path paging (except the deliberately rejected pure-tree reconstruction pager), retired cleanup and dictionary GC. Million-row paging verifies the surviving count; the ordinary 4,096-row fixture compares every returned page with its expected records. A separate sparse generation measures first-page VM steps and the query plan. A second full replacement returns to the original path set after GC, verifying re-interning, activation, cleanup and final object/path/canonical counts. A 50 ms sampler records database/WAL/SHM allocation by phase, excluding SQLite's other OS temporary files.

Ordinary tests cover raw non-UTF-8 aliases, signed inode boundaries, canonical path selection independent of insertion order, generation/classification isolation, adjacent directory names, multi-page seeks, checkpoint-protected deletion rollback, and overlay/parent references during dictionary GC. A 4,096-row sparse-generation regression proves that an indexed dictionary range query can do over 100 times the work of generation-local paging despite the same LIMIT. This negative test is intentional: it prevents an unsafe layout from being approved solely on size or a superficial EXPLAIN plan.

Only hot inventory tables and simplified catalogs are compared; full production overlays, history, scanner traversal and migration are not benchmarked by this fixture. UUID layout catalogs also carry explicit external-ID mapping columns for a uniform harness, so these totals are not a complete production database measurement. Timings use a fixed layout order on one machine, not repeated cold-cache trials. All input is synthetic, temporary databases are removed, and no installed database is read or modified.

## Inventory reuse regression gates

Coverage added:

- Triggers reject any live inventory writes on a zero-change full run; generation count stays one and the trusted checkpoint advances.
- Metadata-only changes trigger no path/order/live-canonical writes and retain old object values without old path duplication.
- Object update + deletion with an injected checkpoint failure rolls back inventory, history and checkpoint; retry succeeds. A partial observation batch with an injected SQLite error rolls back, poisons the comparison, refuses sealing and restarts through interrupted-run recovery.
- Aliases observed in opposite metadata states across batches of 1 and 1,024 retain last-observation semantics; opaque roots preserve history and exclude adjacent names.
- Mixed churn (delete, rename, resize, hard links, raw non-UTF-8 path) matches fresh-generation inventory and signed semantic ledger; retained records reconstruct the original inventory. Cross-classification transfer has a balanced debit/credit pair.
- Version reconstruction survives deletion/replacement and backwards timestamps; unpublished history pins retention, only contiguous published prefixes expire, referenced retired generations remain protected.
- Supported database upgrades preserve inventory, checkpoints and historical report payloads.
- Real Control progress, daily E0–E1 event replay/loss/recovery, cancellation, report recovery, FULL WAL crash/pinned-reader tests continue in the normal suite. The new comparingInventory phase is cancellable and cannot jump directly to commit.

Reproduction (run separately; process I/O benchmarks must not overlap):

```bash
# 100k production daily inventory reuse; omit DAILYDISK_WRITE_REUSE for full-generation control.
DAILYDISK_DAILY_WRITE_TEST=1 DAILYDISK_WRITE_WAL=bounded \
  DAILYDISK_WRITE_BATCH=1024 DAILYDISK_WRITE_REUSE=1 \
  DAILYDISK_WRITE_CHANGED_PERCENT=3 swift test --filter dailyFullWriteBudget

# Use DAILYDISK_WRITE_CHANGED_PERCENT=100 for metadata high churn;
# add DAILYDISK_WRITE_ROWS=1000000 for the million-row low-change workload.
DAILYDISK_RUN_STRESS=1 swift test --filter millionRecordInventory

```

Production write comparisons must use matched inputs and run separately. Process counters exclude physical NAND write amplification; fixtures do not measure full-disk traversal. Keep benchmark results and local acceptance transcripts outside version control. Signed-app permissions, fresh-machine installation and natural scheduled cleanup require separate acceptance; a passing synthetic suite does not establish them.

## Installer safety

Run `Scripts/test-install-app.sh` for synthetic fresh-install, replacement, busy-process, registered-job, inspection-failure, signature-mismatch, concurrent-install and rename-failure rollback checks. The fixtures mock platform tools and never modify a real app or job. Signed installation and permissions still require manual acceptance.

## Update preparation and versions

Run `Scripts/test-version-config.sh`, `Scripts/test-build-options.sh` and `Scripts/test-install-app.sh` alongside the standard suite. Update tests use synthetic Control roots and task managers: helper admission races, queued-request preservation, restart, partial unregister, failed restore, disabled preferences, approval and installer-lock exclusion. Malformed fields, linked files and file permissions must remain fail-closed. Metadata checks compare CLI with the shared resource; packaged CLI build-number must match Info.plist even when BUILD_NUMBER overrides the development default. These tests do not establish Sparkle installation, notarization, Gatekeeper or real SMAppService upgrade acceptance.


## Sparkle update gates

Run `Scripts/test-update-config.sh` for disabled/default configuration and rejection of missing, insecure or malformed feed/key inputs. Platform update tests exercise source/target build admission, persistent scan blocking, old/unknown-build refusal, cancellation before extraction and enabled/disabled task restoration. App tests verify absent configuration never creates an updater. Packaging must embed Sparkle.framework, preserve its symlinks, verify all nested signatures with `codesign --verify --deep --strict`, and include `@executable_path/../Frameworks` in the GUI's runpaths. Helper and CLI must not link Sparkle.

These synthetic checks do not replace the signed two-version Sparkle acceptance matrix in Installation.md. Until a feed and public key are configured, no live update or notarized distribution acceptance is claimed.

### Settings sheet / update termination regression

App tests cover deferring the check until settings dismissal, exactly-once continuation, restoring settings after an acknowledged no-update cycle, leaving settings closed for a menu-origin check, and waiting for settings reopened during download before final installation. Network errors/cancellation must not carry stale restore intent into the next check.

For signed release acceptance, test from both Settings and the application menu, with and without settings reopened during download. Confirm Install and Relaunch exits without manual intervention and retains permissions and the prior task preference. A target-only fix cannot correct the running old updater: install the fixed source build first, then update it to a higher immutable build. Separately test /Applications and ~/Applications and the non-writable-parent failure case; do not equate synthetic tests with these acceptance results.

Private-installation tests cover a read-only app directory, lease exclusion, symlink substitution, conservative other-user rejection, and native flock ownership transferred to the shell via exec. Shell fixtures use an isolated DAILYDISK_INSTALL_CONTROL_ROOT and never touch production Control state. Real /Applications authorization and cancellation are separate acceptance gates; the session guard is a conservative single-user policy, not a guarantee against a new login during replacement.
