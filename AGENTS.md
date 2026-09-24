# AGENTS.md

This file applies to the entire `DailyDisk` repository. It is written primarily for coding agents, but it is also a concise operational guide for users asking an agent to build, install, inspect, or troubleshoot DailyDisk.

## 1. Product summary

DailyDisk is a GUI-first, source-built macOS 15+ disk-growth monitor. Users start and observe scans, cancel safely, browse reports, inspect health, manage the helper, and reset data in the app. A user-domain LaunchAgent starts the same windowless helper for manual requests and once-per-day work; the helper scans, writes a report, optionally sends a scheduled notification, and exits.

DailyDisk is intended to answer:

- How much did the internal APFS container grow since the previous successful report?
- Which files and directory ancestors explain that growth?
- How much correction was required when a full scan disagreed with FSEvents maintenance?
- How much physical APFS growth remains unattributed to ordinary files?
- Are snapshots, inaccessible paths, deleted-but-open files, or DailyDisk's own database plausible contributors?

The first full scan is an opening balance. It does **not** report every existing file as new growth. Useful growth reports begin with the next successful run.

## 2. Supported scope

- Minimum OS: macOS 15 Sequoia
- Language/toolchain: Swift 6 / Swift Package Manager
- Supported storage: internal APFS startup container
- Full inventory root: `/System/Volumes/Data`
- Sealed System and special APFS roles: metrics-only
- Excluded by default: external disks, removable disks, network volumes, optical media, and disk images
- Privilege model: Full Disk Access only; no root helper, `sudo`, setuid executable, or LaunchDaemon
- Distribution model: source build; installed use requires a stable local signing identity

Full Disk Access does not bypass POSIX permissions, ACLs, SIP, or Signed System Volume restrictions. DailyDisk preserves previously indexed opaque subtrees when they become unreadable rather than reporting them as deleted.

## 3. Repository map

```text
Package.swift
App/
  DailyDisk/                 SwiftUI foreground application
  DailyDiskAgent/            Windowless scheduled executable
Sources/
  DailyDiskCore/             Models, accounting, policies, coordinators
  DailyDiskStore/            SQLite schema, migrations, generations, reports
  DailyDiskPlatform/         APFS, FSEvents, scanner, launchd, notifications
  dailydiskctl/              Strict read-only CLI
Tests/
  DailyDiskCoreTests/
  DailyDiskStoreTests/
  DailyDiskPlatformTests/
  DailyDiskAppTests/
  DailyDiskIntegrationTests/
  DailyDiskPerformanceTests/
  DailyDiskCLITests/
Config/                      Info.plist, entitlements, privacy manifest
Scripts/                     Build and LaunchAgent lint scripts
Docs/                        Architecture, accounting, DB, operations, testing
```

Important documentation:

- `README.md` — user overview and quick start
- `Docs/Installation.md` — fresh-Mac dependencies, source installation, signing, and distribution limits
- `Docs/Architecture.md` — subsystem and scan-boundary design
- `Docs/Accounting.md` — signed accounting formulas
- `Docs/Database.md` — SQLite generations, overlays, sealing, and recovery
- `Docs/Operations.md` — scheduled pipeline and troubleshooting
- `Docs/Testing.md` — automated/manual release gates
- `SECURITY.md` — security and sensitive-artifact policy

## 4. Executables inside the app bundle

A built app contains three independently signed executables:

```text
DailyDisk.app/Contents/MacOS/DailyDisk
DailyDisk.app/Contents/Helpers/DailyDiskAgent
DailyDisk.app/Contents/Helpers/dailydiskctl
```

- `DailyDisk` is the interactive SwiftUI app.
- `DailyDiskAgent` is the genuinely windowless scheduled worker used by SMAppService.
- `dailydiskctl` performs strict read-only inspection.

The embedded LaunchAgent is:

```text
App/DailyDisk/LaunchAgents/io.github.xiuyuwu.DailyDisk.agent.plist
```

Its label is:

```text
io.github.xiuyuwu.DailyDisk.agent
```

It runs at 09:00 local time and also at login for due/catch-up evaluation. `KeepAlive` is false, so persistent failures do not create a retry storm.

## 5. Core architecture

### APFS discovery

`APFSVolumeProvider` combines:

- `diskutil apfs list -plist`
- `diskutil apfs listVolumeGroups -plist`
- Disk Arbitration
- the kernel mount table via `getfsstat`

It pairs System/Data volume groups, rejects untrusted backing devices, and selects only the active startup Data volume as `full` inventory mode. Other internal APFS volumes remain available as metrics-only topology.

### Full scan

`FileInventoryScanner` uses descriptor-relative POSIX APIs:

- `fstatat(..., AT_SYMLINK_NOFOLLOW)`
- `openat(..., O_NOFOLLOW)`
- `fstat`

It does not follow symlinks and does not cross nested mount boundaries. It records logical bytes (`st_size`) and allocated bytes (`st_blocks × 512`) in bounded batches.

DailyDisk's own Application Support subtree is excluded from ordinary inventory because its SQLite/WAL/log/report files change during scanning. Their allocation is sampled separately as DailyDisk overhead.

### Incremental scan

Daily scans use per-device FSEvents and persist both:

- Event Store UUID
- last fully applied Event ID

Inventory mutations, semantic change ledger, samples, and checkpoint advance commit atomically. Event loss, wrapping, root replacement, mount changes, journal replacement, or unresolved inode ambiguity trigger recovery rather than advancing an unsafe checkpoint.

### Full reconciliation

A full scan uses two event sessions:

1. Replay history and flush a concrete pre-scan cursor `E0`.
2. Stop the first session.
3. Traverse into a staging generation.
4. Open a second historical session from `E0`.
5. Replay scan-time events into staging and expected state.
6. Flush a final cursor `E1`.
7. Seal, reconcile, and atomically activate staging with `E1`.

This avoids buffering the entire full-scan interval in memory.

### SQLite

The database uses:

- WAL mode
- `synchronous = FULL`
- foreign keys
- one exclusive writer process lease
- inactive staging generations
- run-scoped mutation overlays and revision seals
- atomic generation/checkpoint activation
- a short retained retired-generation recovery window

Never edit an existing migration that may have been applied. Add a new numbered migration and update `DailyDiskSchema.expectedMigrations`.

## 6. Accounting invariants

All deltas are signed `Int64` byte values:

```text
eventAttributedDelta
reconciliationCorrection
reconciledIndexedDelta
dailyDiskOverheadDelta
physicalUsedDelta
physicalUnattributedDelta
```

The central formula is:

```text
reconciledIndexedDelta = eventAttributedDelta + reconciliationCorrection

physicalUnattributedDelta = physicalUsedDelta
                          - reconciledIndexedDelta
                          - dailyDiskOverheadDelta
```

Positive correction means a full scan discovered allocation missing from the event-maintained index. Negative correction means the event-maintained index retained allocation that is no longer present.

Never force `physicalUnattributedDelta` into a fabricated path. APFS clones, shared extents, snapshots, metadata, purgeable space, inaccessible content, and deleted-open files prevent exact per-file physical allocation.

Hard links are keyed by volume/device/inode and receive one canonical attribution path. Secondary links do not duplicate object allocation. Cross-classification canonical changes use a balanced debit/credit pair.

## 7. Build and test

For another user's checkout, follow `Docs/Installation.md`. A stock Mac may require `xcode-select --install`; check Swift 6+ and a matching macOS 15+ SDK. SwiftPM downloads the dependencies pinned in `Package.resolved`. No Homebrew/Python/Node/database-server dependency is required. Full Xcode is optional for the locally tested Command Line Tools build. Persistent signing identities are per-user and are not supplied by the repo; do not imply that permissions or the author's certificate transfer via GitHub.

Current packaging builds the host architecture. Apple Silicon has local acceptance evidence; Intel/fresh-Mac installation and history-page visual acceptance remain incomplete. CI configuration is not evidence of all-machine compatibility. There is no notarization, release installer, universal build, or automatic-update pipeline.

Basic verification:

```bash
swift format lint --recursive Sources App Tests
swift build
swift test
Scripts/lint-launch-agent.sh
```

The normal suite contains Core, Store, Platform, App, CLI, and integration coverage; the million-row stress test is opt-in and appears as skipped in an ordinary run.

Run the stress test with:

```bash
DAILYDISK_RUN_STRESS=1 swift test --filter millionRecordInventory
```

Build a development-only ad-hoc app explicitly:

```bash
ALLOW_ADHOC_SIGNING=1 Scripts/build-app.sh
```

The build script intentionally rejects implicit ad-hoc signing. Do not remove that guard: unstable designated requirements can invalidate Full Disk Access and notification grants.

Verify the packaged helper without scanning:

```bash
DAILYDISK_DRY_RUN=1 \
  build/DailyDisk.app/Contents/Helpers/DailyDiskAgent

echo $?
```

Expected exit status is `0`.

## 8. Quick one-time trial

For a local trial without a persistent certificate:

```bash
ALLOW_ADHOC_SIGNING=1 Scripts/build-app.sh --install
open "$HOME/Applications/DailyDisk.app"
```

This installs to:

```text
~/Applications/DailyDisk.app
```

Then:

1. Open **设置 → 磁盘权限**.
2. Open System Settings → Privacy & Security → Full Disk Access.
3. Add the actual installed bundle, normally `~/Applications/DailyDisk.app`.
4. Quit and reopen DailyDisk after granting access.
5. Open **设置** and request notification permission.
6. Select **安装每日任务**.
7. If status is “等待系统批准”, enable DailyDisk in Login Items & Extensions.

An ad-hoc build is appropriate for a one-time trial only. Rebuilding may require granting permissions again.

## 9. Recommended persistent installation

The script uses an existing valid Code Signing certificate/private key; it does not create one. Apple-issued and valid local self-signed identities are distinct from the explicit ad-hoc trial. See `Docs/Installation.md` for setup and `CODE_SIGN_TIMESTAMP=none` for a local identity. Never distribute a contributor's private signing key.

List available signing identities:

```bash
security find-identity -v -p codesigning
```

Build and install with the same identity on every update:

```bash
CODE_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" \
  Scripts/build-app.sh --install

open "$HOME/Applications/DailyDisk.app"
```

A stable custom bundle ID may be selected before first authorization:

```bash
BUNDLE_IDENTIFIER="com.example.DailyDisk" \
CODE_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" \
  Scripts/build-app.sh --install
```

Changing `BUNDLE_IDENTIFIER` does not create an independent installation: the helper label and runtime data root remain fixed. Prefer the default.

Keep these stable:

- signing identity
- bundle identifier
- installation path

The app must remain under `/Applications` or `~/Applications` for LaunchAgent registration.

## 10. Running now instead of waiting for 09:00

Open **概览** and select **开始首次检查** or **立即检查**. The app writes a private fixed-schema request, starts or attaches to `DailyDiskAgent` without `kickstart -k`, and shows phase/count/elapsed progress. Closing the GUI does not stop the helper; reopening attaches to persistent progress.

Use **取消检查** before atomic commit. Cancellation is cooperative and marks the SQLite run interrupted while preserving the prior active generation/checkpoint. During commit/report publication the UI says the run is finishing and no longer offers cancellation.

Raw `launchctl`, Unified Logging, and local JSONL logs remain developer/expert diagnostics only.

## 11. Inspecting results

Installed CLI:

```bash
CLI="$HOME/Applications/DailyDisk.app/Contents/Helpers/dailydiskctl"
```

Useful commands:

```bash
"$CLI" status
"$CLI" history --limit 14
"$CLI" report
"$CLI" verify
"$CLI" diagnostics
```

Paths are hidden by default. Explicit path output:

```bash
"$CLI" status --include-paths
"$CLI" report --include-paths
"$CLI" report --include-paths --json
"$CLI" report --run <run-uuid> --domain <container-uuid>
```

`report --json` requires `--include-paths` because report JSON contains reversible path bytes.

Reports are automatically written with detailed paths to the private directory:

```text
~/Library/Application Support/DailyDisk/Reports/<run-uuid>/
├── report.json
└── report.md
```

Strict CLI inspection may refuse access while the writer is active or while a WAL file is nonempty. Wait for the scheduled worker to finish and retry.

CLI exit status:

- `0` success / healthy verification
- `2` verification found an unhealthy database
- `64` usage error
- `65` corrupt or invalid data
- `66` missing database or report

## 12. Quick behavior test

After the opening baseline completes:

```bash
mkdir -p "$HOME/Downloads/DailyDisk-Test"
mkfile 2g "$HOME/Downloads/DailyDisk-Test/growth-test.bin"
```

Select **立即检查** in the app. After completion, inspect **历史**. For CLI regression only:

```bash
"$CLI" history --limit 5
"$CLI" report --include-paths
```

The report should attribute approximately 2 GB to the test path and its directory ancestors. Remove the test data afterward:

```bash
rm -rf "$HOME/Downloads/DailyDisk-Test"
```

A subsequent run should show the corresponding negative change.

## 13. Runtime data

```text
~/Library/Application Support/DailyDisk/DailyDisk.sqlite
~/Library/Application Support/DailyDisk/DailyDisk.sqlite.lock
~/Library/Application Support/DailyDisk/Reports/
~/Library/Application Support/DailyDisk/Logs/
~/Library/Application Support/DailyDisk/AlertState.json
~/Library/Application Support/DailyDisk/Control/
```

`Control/` is mode 0700 with atomic 0600 request/progress/cancel/summary files. Progress contains only fixed IDs, phases, timestamps, counters, and closed error categories—never paths or commands.

Operational logs and notifications do not expose full paths. Scheduled JSON/Markdown reports do contain detailed paths and are private user-only files.

## 14. Uninstall and reset

1. In DailyDisk → **设置**, select **移除每日任务** (including pending-approval registrations).
2. If history should also be removed, use **设置 → 重置历史与基线** while the app is still installed; this performs lease-protected fixed-root cleanup.
3. Quit the app.
4. Remove `~/Applications/DailyDisk.app`.
5. Remove stale DailyDisk entries from Full Disk Access and Notifications in System Settings.

Deleting history removes the baseline and therefore the ability to explain changes relative to the previous run.

## 15. Troubleshooting

### The app says no report exists

- Reopen **概览** to reconnect to persistent scan progress.
- Open **设置 → 诊断 → 验证数据库** for explicit verification; verification waits while a writer is active.
- A committed scan with a missing report is recovered before a new scan.
- Use `launchctl print` or `dailydiskctl verify` only for expert troubleshooting.

### CLI says the database is being written or WAL is nonempty

The strict CLI refuses potentially stale inspection. Wait for `DailyDiskAgent` to exit and retry.

### Full Disk Access looks enabled but scanning reports opaque paths

FDA does not override POSIX/SIP restrictions. Review the report's unreadable count. DailyDisk preserves prior opaque inventory instead of treating it as deletion.

### The LaunchAgent is waiting for approval

Open DailyDisk → **设置 → 打开登录项设置**, approve DailyDisk, then return to the app and refresh.

### Permissions disappear after rebuilding

The signing identity, bundle ID, or app path changed. Rebuild with the original persistent identity and reinstall to the same path, then authorize again if necessary.

## 16. Agent modification rules

When changing this repository, preserve these invariants:

1. Never advance an FSEvents checkpoint without a fully applied trusted fence.
2. Keep generation activation and checkpoint update in one atomic transaction.
3. Preserve the sign of reconciliation corrections.
4. Never map physical unattributed bytes to a fabricated path.
5. Do not scan both sealed System and Data namespaces.
6. Do not follow symlinks or unverified nested mounts.
7. Do not interpret opaque permission subtrees as deletions.
8. Do not put full paths in notifications, Unified Logging event names, default CLI output, or public log metadata.
9. Do not make the scheduled job resident or add a persistent failure retry loop.
10. Keep manual scans in `DailyDiskAgent`; the GUI may request/observe/cancel but must not become an inventory writer.
11. Keep Control files path-free, fixed-schema, owner-only, atomically replaced, and resistant to symlink/hard-link substitution.
12. Do not allow cancellation once atomic commit begins.
13. Do not weaken the persistent-signing requirement for installed use.
14. Do not edit an already published migration; add a new migration and migration test.
15. Keep tests synthetic: never commit a real inventory DB, report, username, certificate, or local path dump.

Before declaring work complete, run the commands in section 7 and update this file plus the relevant documents when installation, runtime behavior, schema, or user-facing commands change.

## 17. Simple UI and observable execution

The main window has **概览 / 历史** and a settings sheet (**通用 / 磁盘权限 / 诊断**). Overview has one primary setup-aware action: permission guidance, enable daily checks, approval guidance, first check, check now, or explicit retry. Show feedback above results, never below a topology list. Full reconciliation and reset belong in advanced settings.

Both manual and scheduled work publish real progress and share cooperative cancellation. Show phase, counters, elapsed time, and last-update age; never invent a percent complete. Detect a stopped helper with stale progress and no writer after an observation grace period, without a persistent kickstart retry loop. Keep detailed paths hidden until session disclosure. The legacy GUI `--scheduled` writer is removed.

Control JSON uses whole-second ISO8601 timestamps; comparisons against in-memory dates must use that wire precision. Regression tests must include fractional timestamps and actual persisted progress, not only no-op trackers or integer epoch fixtures.

### Generation cleanup (schema 4)

Migration 003 adds a composite path/object lookup index. Migration 004 adds a generation-delete trigger that removes canonical rows and paths in sets before removing objects. SQLite can otherwise prefer a generation-only lookup even when a more selective index exists; deleting a large failed/staging generation then repeatedly scans its entire path set. The trigger keeps foreign keys and transaction rollback intact, including protection of the active checkpoint. Regression coverage upgrades a v2 schema and cancels a 10,000-record staging generation while preserving the active baseline.

Overview refresh uses lightweight WAL-aware read-only queries. Complete database verification and table-size diagnostics run only via **设置 → 诊断 → 验证数据库** (or the strict CLI); opening the app must not trigger a full integrity scan or prevent recovery of a nonempty WAL. An unverified overview is never labeled healthy.

Failed full scans publish `cleaningUpFailedRun` before deleting staging data. The UI must show safe cleanup, not stale file traversal or report publication, while that transaction completes.

Metadata operations retry `EINTR` with a bounded retry budget. Dataless directories are not materialized for inventory. Provider `EDEADLK` failures are recorded as `contentUnavailable`, included in unreadable coverage, and preserve prior opaque inventory just like permission-denied paths. Other I/O failures remain fatal rather than silently removing indexed content.

FSEvents callbacks are accepted as whole batches under one mailbox lock. Historical file-event IDs can arrive unsorted: consume every callback through HistoryDone and a synchronous native flush before sealing a cursor, rather than treating callback arrival order as journal loss. Flush work runs off the main/cooperative executor. HistoryDone is a control sentinel, not a filesystem event ID. UUID changes, dropped/wrapped events, buffer overflow, and IDs below the committed cursor still require recovery. Coalesced create/remove flags reconcile missing endpoints, distinct observed identities, and single-link replacements from current metadata; ambiguous shared inode aliases still require recovery. Regression coverage includes unsorted batches, a burst of real FSEvents, and single-link versus hard-link replacement.

Observed inode reuse may proceed only when the run overlay contains no surviving paths for the old identity; surviving aliases still force recovery. Subtree paging uses explicit lower/upper path bounds plus an exact descendant predicate so SQLite seeks into the path index rather than rescanning an entire generation for every changed directory. Tests retain adjacent names such as `cache-neighbor`, `cache.more`, and `cache0`.

Canonical attribution pagination uses a composite `(device_id, inode)` seek. Preserve this index range bound: an equivalent OR predicate can rescan the complete run prefix for every page. Multi-page coverage includes UInt64 inode boundary values stored as signed SQLite integers.

Cancellation cleanup can take several minutes for a large staging inventory. The GUI explicitly displays that it is waiting for temporary-index cleanup, including after reconnecting, instead of treating the absence of per-file updates as a stale scan. The stopped-helper watchdog remains active.

During atomic commit and report publication, the GUI shows that it is waiting for saving to finish. These phases do not produce per-file progress updates; a large first inventory may take several minutes to save, and cancellation remains unavailable.

Before full-generation orphan cleanup, the writer refreshes inventory-path statistics with `ANALYZE inventory_paths` and a 1,000-row-per-index analysis limit. Without statistics, SQLite can choose a generation-only scan for foreign-key cascades despite the composite identity index. A populated synthetic regression verifies identity-bounded child lookups. Statistics are SQLite-managed metadata; the application schema remains version 4.

The opt-in million-row regression includes 128 staged deletions and an actual opening-generation commit, not just insertion and canonicalization. This exercises foreign-key cleanup and activation at realistic scale.

On restart, a persisted committing phase with a still-running SQLite scan is treated as an interrupted transaction, not committed-report recovery. The helper publishes non-cancellable failure cleanup, removes abandoned staging, and only then resumes inventory work for that request. Progress counters remain cumulative across recovery attempts. Ordinary cancellation remains forbidden during commit; cleanup is entered only after rollback or after the new helper owns the writer lease.

Overlay path queries keep the path table first with `CROSS JOIN` before looking up object metadata. This preserves path-range seeks even when only inventory paths have refreshed statistics. The million-row test also performs 32 narrow incremental subtree removals after activation, with a 10-second lookup budget to detect whole-object rescans.

Incremental accounting treats an object created and removed during the same replay as no net transition. A synthetic regression covers candidates with neither a baseline nor a final attribution, avoiding an optional-unwrapping crash. GUI polling preserves the immediate requesting state while a manual launch is still being submitted.

Incremental commit limits orphan cleanup to the sealed run’s candidate identities (both previous path identities and object mutations). Full-generation cleanup remains available for full scans. The million-row regression commits 32 incremental removals with a 10-second commit budget and verifies remaining object/canonical counts and checkpoint activation.

Incremental orphan cleanup reuses full-scan path statistics. It does not rerun ANALYZE: on the system SQLite, counting a WITHOUT ROWID table can still read its pages despite a bounded index sample.

### Notification process isolation

Scheduled notification delivery runs in a short-lived process of the enclosing signed `Contents/MacOS/DailyDisk` executable. The internal `--deliver-notification` mode accepts a bounded encoded aggregate-only message, uses a prohibited activation policy, creates no SwiftUI scene or inventory writer, never requests authorization, and exits after delivery. The scan helper waits at most 15 seconds; denial, launch failure, timeout, or a child framework crash is caught as notification-unavailable and cannot prevent report/task completion. Alert cooldown is persisted only after successful delivery. The internal `--notification-status` mode reads authorization without sending or requesting permission. The GUI bundle identifier/signature/install path remain unchanged.

Do not instantiate the system notification center from the bare `DailyDiskAgent` helper: macOS can raise an Objective-C assertion that Swift `catch` cannot handle. `NotificationManager` lazily checks for an app bundle before accessing the center; unsupported processes return an error.

### Growth chart interpretation

Overview and report details keep their source lists and add a ring chart for up to five non-overlapping positive entries from the stored ranking. Ancestors and duplicate paths are excluded before calculating percentages. The denominator is only the displayed subset, not all file growth or the physical disk delta. Negative file changes and unattributed APFS space do not become pie slices. The overview separately explains `physical delta = net file delta + unattributed delta + DailyDisk overhead`. Fixed system-directory descriptions (for example diagnostics logs below `private/var/db/diagnostics`) appear only after session path disclosure; hidden paths remain hidden in the chart and legend.

Darwin `dev_t` is a signed 32-bit bit pattern. Persist device identities by zero-extending `UInt32(bitPattern: st_dev)` and reconstruct native FSEvents device IDs using the same bit pattern. Direct `UInt64(st_dev)` conversion can trap on mounted volumes with negative device IDs, including hosted macOS runners. Positive stored identities are unchanged; regression coverage includes both signed boundaries and rejects values wider than 32 bits.

### Bounded overlay paging and opaque preservation

Full reconciliation pages the base inventory and run overlay independently by raw path bytes before merging at most two bounded candidate pages. Keep subtree bounds, tombstone exclusion, and object-overlay resolution inside the appropriate branch; an outer LIMIT over an unbounded UNION can repeatedly scan/sort the entire remaining inventory. Both opaque preservation and full inventory diff depend on this pager. Mutation paths drive object lookups with CROSS JOIN.

Opaque roots are deduplicated and reduced to disjoint subtrees before reading. Only those path ranges are copied, in transactions of at most 1,024 records. Each transaction invalidates the destination seal before publishing progress; cancellation between batches leaves the active baseline/checkpoint unchanged. Do not skip unreadable history or advance an untrusted FSEvents cursor to avoid a recovery scan.

The cancellable `preservingOpaqueInventory` phase separates history preservation from file traversal. `preservedPaths` and `processedOpaqueRoots` are cumulative, path-free progress counters; missing fields from old progress files decode as zero. Update GUI and helper together and restart the GUI on upgrade because old binaries do not understand the new phase/fields. Temporary identity counters finalize their statements and close SQLite before deleting their private files.
