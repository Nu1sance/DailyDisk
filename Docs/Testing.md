# Testing and release gates

## Validation scope

Use [Installation](Installation.md) to provision a source-build machine. Minimum declared support is macOS 15/Swift 6; local runtime validation used Apple Silicon with Command Line Tools Swift 6.3.2. CI is configured on `macos-15` but does not validate FDA, notification grants, Intel hardware, or another user's fresh installation. History-page visual acceptance remains an open gate. Do not turn local observations into cross-machine performance guarantees.

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
3. Install to `~/Applications/DailyDisk.app` using `Scripts/build-app.sh --install`.
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
10. Exercise sleep past 09:00 and confirm the next login/wake invocation runs once.
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

### Generation cleanup (schema 4)

Migration 003 adds a composite path/object lookup index. Migration 004 adds a generation-delete trigger that removes canonical rows and paths in sets before removing objects. SQLite can otherwise prefer a generation-only lookup even when a more selective index exists; deleting a large failed/staging generation then repeatedly scans its entire path set. The trigger keeps foreign keys and transaction rollback intact, including protection of the active checkpoint. Regression coverage upgrades a v2 schema and cancels a 10,000-record staging generation while preserving the active baseline.

Overview refresh uses lightweight WAL-aware read-only queries. Complete database verification and table-size diagnostics run only via **设置 → 诊断 → 验证数据库** (or the strict CLI); opening the app must not trigger a full integrity scan or prevent recovery of a nonempty WAL. An unverified overview is never labeled healthy.

FSEvents callbacks are accepted as whole batches under one mailbox lock. Historical file-event IDs can arrive unsorted: consume every callback through HistoryDone and a synchronous native flush before sealing a cursor, rather than treating callback arrival order as journal loss. Flush work runs off the main/cooperative executor. HistoryDone is a control sentinel, not a filesystem event ID. UUID changes, dropped/wrapped events, buffer overflow, and IDs below the committed cursor still require recovery. Coalesced create/remove flags reconcile missing endpoints, distinct observed identities, and single-link replacements from current metadata; ambiguous shared inode aliases still require recovery. Regression coverage includes unsorted batches, a burst of real FSEvents, and single-link versus hard-link replacement.

Observed inode reuse may proceed only when the run overlay contains no surviving paths for the old identity; surviving aliases still force recovery. Subtree paging uses explicit lower/upper path bounds plus an exact descendant predicate so SQLite seeks into the path index rather than rescanning an entire generation for every changed directory. Tests retain adjacent names such as `cache-neighbor`, `cache.more`, and `cache0`.

Before full-generation orphan cleanup, the writer refreshes inventory-path statistics with `ANALYZE inventory_paths` and a 1,000-row-per-index analysis limit. Without statistics, SQLite can choose a generation-only scan for foreign-key cascades despite the composite identity index. A populated synthetic regression verifies identity-bounded child lookups. Statistics are SQLite-managed metadata; the application schema remains version 4.

On restart, a persisted committing phase with a still-running SQLite scan is treated as an interrupted transaction, not committed-report recovery. The helper publishes non-cancellable failure cleanup, removes abandoned staging, and only then resumes inventory work for that request. Progress counters remain cumulative across recovery attempts. Ordinary cancellation remains forbidden during commit; cleanup is entered only after rollback or after the new helper owns the writer lease.

Overlay path queries keep the path table first with `CROSS JOIN` before looking up object metadata. This preserves path-range seeks even when only inventory paths have refreshed statistics. The million-row test also performs 32 narrow incremental subtree removals after activation, with a 10-second lookup budget to detect whole-object rescans.

Incremental accounting treats an object created and removed during the same replay as no net transition. A synthetic regression covers candidates with neither a baseline nor a final attribution, avoiding an optional-unwrapping crash. GUI polling preserves the immediate requesting state while a manual launch is still being submitted.

Incremental commit limits orphan cleanup to the sealed run’s candidate identities (both previous path identities and object mutations). Full-generation cleanup remains available for full scans. The million-row regression commits 32 incremental removals with a 10-second commit budget and verifies remaining object/canonical counts and checkpoint activation.

Incremental orphan cleanup reuses full-scan path statistics. It does not rerun ANALYZE: on the system SQLite, counting a WITHOUT ROWID table can still read its pages despite a bounded index sample.

## Local end-to-end validation (2026-09-23)

A signed installed build completed a real startup-Data baseline with about 2.36 million visited paths and 2.31 million objects. Opening accounting remained zero, with inaccessible paths reported as incomplete coverage. A private 128 MiB allocated fixture produced exactly +134,217,728 bytes on creation and -134,217,728 bytes on deletion in the FSEvents ledger. The fixture was removed afterward. The final incremental run completed in 17 seconds on this machine; this is an observation, not a universal duration guarantee.

Overview progress, cancellation, reconnect, helper-stop detection, baseline display, positive/negative totals, and path disclosure were exercised. The history-page visual inspection remains unverified because the native UI automation connection closes on that page; the application process remained alive. Real database and report artifacts stay outside the repository.

Final installed strict CLI verification returned `healthy: true`, schema 4/4, `integrity_check: ok`, zero foreign-key, invariant, report-payload, and abandoned-run violations. No writer remained and WAL size was zero. Before the notification repair, the enabled suite passed all 197 tests, including the million-row full/incremental commit exercise; format lint, build, LaunchAgent lint, packaged helper dry-run, and deep strict signature verification also passed.

Notification regressions cover app-executable routing, bounded child execution, signal termination becoming a delivery error, malformed/oversized input, and safe unbundled notification access. Packaged validation must use the persistent installed app identity, check authorization without prompting, send a synthetic aggregate-only notification, and verify interrupted scheduled work reaches terminal state without duplicating its committed scan.

The notification repair was validated against the installed signed bundle: authorization remained `authorized`, a synthetic notification delivery returned 0, and malformed delivery input returned 1 without a crash. Resuming the interrupted scheduled request reached `completed` and helper exit 0, with unchanged scan/report counts and no active database runs. The regular suite passed (200 enabled tests, one opt-in stress test skipped). No full scan was required for this notification-only repair.

Growth-chart regressions cover ancestor/duplicate exclusion, path-component boundaries, negative/zero exclusion, the displayed-subset denominator, and large values without Int64 total overflow. CI's Swift 6.1.2 compiler requires explicit `[Int64]` typing for the optional/defaulted storage-sample validation array; do not rely on newer compiler inference alone.

Keep actor-isolated optional SQLite reads outside short-circuit comparison autoclosures for Swift 6.1 compatibility. Local chart validation passed build, format lint, LaunchAgent lint, and all 203 enabled tests (one opt-in stress test skipped). The installed signed app was visually checked with hidden and disclosed paths; long system paths remain beside the ring without expanding the overview layout.

Darwin `dev_t` is a signed 32-bit bit pattern. Persist device identities by zero-extending `UInt32(bitPattern: st_dev)` and reconstruct native FSEvents device IDs using the same bit pattern. Direct `UInt64(st_dev)` conversion can trap on mounted volumes with negative device IDs, including hosted macOS runners. Positive stored identities are unchanged; regression coverage includes both signed boundaries and rejects values wider than 32 bits.
