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

Source runs at 05:00 local time and at login for due/catch-up evaluation. Upgrade the installed GUI/helper and registered job together; an older registration may still use 09:00. `KeepAlive` is false, so persistent failures do not create a retry storm.

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

Daily full scanning runs at 05:00; only subsequent manual checks after a published same-local-day full scan attempt incremental scanning. This replaces incremental-first daily checks and the rolling seven-day full-scan design. Incremental and scan-time catch-up sessions use per-device FSEvents and persist both:

- Event Store UUID
- last fully applied Event ID

Inventory mutations, semantic change ledger, samples, and checkpoint advance commit atomically. Event loss, wrapping, root replacement, mount changes, journal replacement, or unresolved inode ambiguity trigger recovery rather than advancing an unsafe checkpoint.

### Full reconciliation

A full scan uses two event sessions:

1. Daily-full path: establish a trusted current-journal pre-scan cursor `E0`, without replaying yesterday’s committed history. Legacy scheduled reconciliation retains its original behavior, but is not selected by the daily policy.
2. Stop the first session.
3. Traverse into a staging generation.
4. Open a second historical session from `E0`.
5. Replay scan-time events into staging; daily full compares against unchanged previous inventory. Legacy reconciliation also maintains expected state.
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
snapshotComparedDelta
eventAttributedDelta
reconciliationCorrection
reconciledIndexedDelta
dailyDiskOverheadDelta
physicalUsedDelta
physicalUnattributedDelta
```

The central formula is:

```text
reconciledIndexedDelta = snapshotComparedDelta + eventAttributedDelta + reconciliationCorrection

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

The normal suite contains Core, Store, Platform, App, CLI, and integration coverage; the million-row stress tests are opt-in and appear as skipped in an ordinary run. Storage-layout and hybrid-adapter commands are documented in Docs/Testing.md.

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

## 10. Running now instead of waiting for the daily schedule

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

The main window uses a sidebar with **概览 / 历史**, a daily-check status card, and a **设置** button that opens the settings sheet (**通用 / 磁盘权限 / 诊断**). The visual style is "Graphite": neutral system surfaces with one indigo accent (`App/DailyDisk/Views/Theme.swift`), supporting light and dark appearance. The app icon (`Config/AppIcon.png`) is unchanged. Overview has one primary setup-aware action, placed in the window toolbar: permission guidance, enable daily checks, approval guidance, first check, check now, or explicit retry. Below the headline and composition card, the overview shows a bar chart of the last (up to 14) non-baseline physical deltas for the same storage domain, with the latest run highlighted and the cumulative sum; it is derived in the GUI from already loaded reports and is hidden with fewer than two such reports. History is a report list beside the selected report; path disclosure and JSON export are toolbar actions. Show feedback above results, never below a topology list. Full reconciliation and reset belong in advanced settings.

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

Before full-generation orphan cleanup, the writer refreshes inventory-path statistics with `ANALYZE inventory_paths` and a 1,000-row-per-index analysis limit. Without statistics, SQLite can choose a generation-only scan for foreign-key cascades despite the composite identity index. A populated synthetic regression verifies identity-bounded child lookups. Statistics are SQLite-managed metadata; their refresh does not require a schema migration.

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

Overview and report details list up to five non-overlapping growth entries and up to five non-overlapping release entries from the stored ranking. Ancestors and duplicate paths are excluded first; each row's bar is relative only to the largest displayed entry, not to all file growth or the physical disk delta. Unattributed APFS space never becomes a source row. A "space composition" card shows `physical delta = net file delta + unattributed delta + DailyDisk overhead`; its proportional bar appears only when all non-zero parts share one sign, and the explanation of unattributed space lives in the card's info popover. The complete stored ranking (including overlapping ancestors, allocated and logical bytes) remains under the report's collapsed details. Fixed system-directory descriptions (for example diagnostics logs below `private/var/db/diagnostics`) appear only after session path disclosure; hidden paths remain hidden in every list.

Darwin `dev_t` is a signed 32-bit bit pattern. Persist device identities by zero-extending `UInt32(bitPattern: st_dev)` and reconstruct native FSEvents device IDs using the same bit pattern. Direct `UInt64(st_dev)` conversion can trap on mounted volumes with negative device IDs, including hosted macOS runners. Positive stored identities are unchanged; regression coverage includes both signed boundaries and rejects values wider than 32 bits.

### Bounded overlay paging and opaque preservation

Full reconciliation pages the base inventory and run overlay independently by raw path bytes before merging at most two bounded candidate pages. Keep subtree bounds, tombstone exclusion, and object-overlay resolution inside the appropriate branch; an outer LIMIT over an unbounded UNION can repeatedly scan/sort the entire remaining inventory. Both opaque preservation and full inventory diff depend on this pager. Mutation paths drive object lookups with CROSS JOIN.

Opaque roots are deduplicated and reduced to disjoint subtrees before reading. Only those path ranges are copied, in transactions of at most 1,024 records. Each transaction invalidates the destination seal before publishing progress; cancellation between batches leaves the active baseline/checkpoint unchanged. Do not skip unreadable history or advance an untrusted FSEvents cursor to avoid a recovery scan.

The cancellable `preservingOpaqueInventory` phase separates history preservation from file traversal. `preservedPaths` and `processedOpaqueRoots` are cumulative, path-free progress counters; missing fields from old progress files decode as zero. Update GUI and helper together and restart the GUI on upgrade because old binaries do not understand the new phase/fields. Temporary identity counters finalize their statements and close SQLite before deleting their private files.

### Space maintenance (schema 5)

Migration 005 adds retirement timestamps and a singleton maintenance record. Existing retired inventory gets a fresh 24-hour window at migration. Retirements are stamped at activation; idle cleanup waits for replacement report publication and absence of running/staging/overlay or pending-report recovery work. Keep the latest retired generation for 24 hours; older ones may be pruned after replacement publication. Preserve active/checkpoint references, historical reports, ledger and samples. Cleanup runs before new work and after report publication, outside activation; expiry does not wake a resident process.

The `reclaimSpace` Control action runs only in DailyDiskAgent. Automatic evaluation uses >1 GB freelist, >25% free pages, and seven days since the last attempt. Manual requests bypass thresholds only. Native VACUUM preflights two database sizes plus 1 GB reserve, uses the existing writer/stable leases, and never swaps database files. Persist a maintenance marker, bracket compaction with integrity/FK/basis checks, and verify interrupted maintenance before further work. A resumed manual request requires explicit retry after verification. Do not alter past overhead/physical sample boundaries.

Cleanup, compression and verification use non-cancellable Control boundaries and truthful phase-only UI; automatic maintenance returns to cancellable scan preparation afterward. `maintenanceCompleted` has zero completed domains and no report IDs. Upgrade GUI/helper together and restart the GUI for the new action, phases and categories. Settings reads allocation/freelist explicitly; normal GUI polling must not run dbstat, table counts or integrity scans.

### Compact inventory (schema 6)

Production inventory now uses integer generation/volume keys, immutable parent/name nodes and a generation-local full raw-path ordering table. The three legacy inventory names are read-only compatibility views; write compact tables directly with batch-scoped prepared statements. Preserve statement reset on error and discard cached IDs across rollback. Full sealing audits ordering completeness/equivalence; incremental sealing audits candidate identities only. Explicit verification and maintenance audit retained inventory. Idle node collection uses a bounded leaf queue, not repeated full-tree sweeps. See Docs/Database.md.

Internal-beta transition uses a fresh database; no old-inventory conversion, dedicated error type, Control category or reset-required UI branch is retained. User authorized deleting the installed old inventory on 2026-09-29. Keep the migration's empty-database precondition as a generic consistency check: dropping inventory while preserving an old checkpoint is invalid. Upgrade GUI/helper together and use the same persistent signing identity. Historical prototype-only/schema-5 and compatibility-UI statements below describe earlier rounds and are superseded by this section.

Incremental attribution must join `hybrid_generations` and `hybrid_objects` directly using the integer generation key plus `(device_id, inode)`. A LEFT JOIN against the `inventory_objects` compatibility view can materialize the complete generation for every surviving candidate. Preserve outer-join behavior for newly created objects. Both per-identity and streamed overlay attribution use this rule. Path-mutation accounting likewise joins compact ordering/path/volume tables by the candidate path, avoiding a generation-wide materialization of `inventory_paths`. The million-row workload must include surviving modifications, new objects, renames and hard links; deletion-only increments bypass the expensive branch and cannot validate its performance.

## TODO

### 当前后续优先级：降低每日全量实际写入（2026-10-02）

详见 `Docs/WriteOptimizationReview.md`。10 月 2 日真实 helper 约写 16.39 GB，主要为遍历入库 11.63 GB、sealing 1.69 GB、提交 1.02 GB、清理 2.02 GB；不是读取量或 NAND 磨损。旧 10 万行 A/B 的 37.6% 降幅不外推真实负载。

- [x] 从 append、canonical sealing、commit、retention 重审生产源码。确认全代重写、多索引维护、带 UUID/完整路径的 canonical 运行中间表、ledger 列与 JSON 双表示。
- [x] 合成 PRAGMA index_xinfo 确认 hybrid_order 反向 UNIQUE 索引携带完整 path；不能直接删除唯一约束或宣称节省同等写入。
- [ ] W1：补齐事务/cache spill/checkpoint 与前后占用/空闲页测量；清理后占用独立展示，不替换旧报表的一半采样边界。
- [ ] W2：同夹具测试 cache/checkpoint、批内写入顺序、no-op upsert，保留 FULL 和 WAL/内存边界。
- [ ] W3：实验 compact canonical 暂存或 inactive staging 一次构建，减少路径重复和提交复制；收益成立再新增迁移。
- [ ] W4：排序表窄键布局和旧代删除写入分别实验，保留 raw-byte seek、FK、恢复窗口和原子激活。
- [ ] W5：明确历史 ledger 保留/汇总与编码策略；不得未经授权淘汰旧明细。
- [ ] **W6 主方案（用户 2026-10-02 决策）**：每日完整读取、差异持久化；一份当前库存 + 本轮变更暂存 + 短期旧值恢复，复用未变化对象/路径/排序/canonical。独立分支开发，不按实现成本后置。先 W1，再 W6，吸收 W3/W4；W5 不作为前置条件。详细设计/验收见 Docs/WriteOptimizationReview.md。
- [ ] W6 不得逐条写 last_seen、复制全代成员关系、长时间钉住 WAL 或用近似结构判删除；批量比较与精确访问标记必须有界。硬链接对象与路径分开处理，opaque 继承，E0/E1 和原子激活不弱化。早期删除旧库存授权不延伸到本次，迁移保留 schema 7 数据。
- [x] 主线小改动：对象 NULL-safe no-op UPDATE 与相同排序映射 UPDATE 跳过，保留 membership/coverage/seal 语义；收益不外推全量扫描。

184.64 MB 是两个提交前占用采样的差，缺少前一日逐表/空闲页/WAL 快照，不能归因成今天提交的约 6 万条 ledger。空间复用与累计写入是两个指标。此次仅更新审查与规划，不修改生产算法或安装。


### 当前优先级：每日默认全量与低写入设计（2026-10-01）

用户决定不再优先追查 macOS journal UUID 重建根因，转向每日默认全量。设计审查见 `Docs/DailyFullScan.md`。目标确定为本地时间 05:00 每日全量；当天已有成功全量后，用户再次请求才尝试增量，可信历史失败时快速回退全量。当前源码已实现 05:00 与新策略；安装和实机验收状态见文末记录。详细行为与四轮顺序以 `Docs/DailyFullScan.md` 为准，不将现有 scheduled-full 等同于新设计。

- [x] 审查跨日历史依赖：现有 scheduled-full 仍回放旧 checkpoint，不能只将七天改成一天。
- [x] 确认写入优化候选：每个事务后的 TRUNCATE checkpoint、512 条批次、库存重建及 VACUUM；优先保留可复用页及 FULL 持久性。
- [x] 第一轮源码：将调度默认值/GUI/安装说明/测试一并改为 05:00，按本地日期及成功全量报告判定自动去重与手动增量；失败/取消不冒充成功，已有成功全量不被后续失败抹去。实现每日直接全量：只要求本次 E0–E1 可信，保留 opaque/硬链接/取消/原子提交；完善每日调度去重。
- [x] 明确定义前后库存差分的报告与告警语义，不把正常日增长全部当作“校正异常”；无需删除历史数据。
- [x] 第二轮：完成同夹具 A/B，采用有界 WAL 与 1024 条批次，保留 FULL；完成读者阻塞、崩溃和关闭失败回归及百万行每日替换验收。
- [x] 第三轮：分开测量过期库存删除和 VACUUM；证据支持复用空闲页，维持恢复窗口与七天压缩冷却，不每日无条件压缩。
- [x] 第四轮：2026-10-02 自然例行全量测得 helper 累计写入约 16.39 GB；后续优化需重新验收，不把数据库体积当累计写入或 NAND 磨损。
- [x] 修复 CI 取消测试的 50 ms 时序假设：子进程通过 ready 文件握手，并阻塞于 FIFO，测试显式取消；保留超时兜底，不通过串行化或重试隐藏失败。


### 存储落地前的测试失败排查（2026-09-29）

用户要求先排清两个间歇失败，再落地新结构。详见 `Docs/Testing.md` 的 “Investigation of the two intermittent failures”。`stopFallbackIsRequestScoped` 原先靠 10 ms 等待和 100 ms fallback 推测请求切换顺序；受控延迟实验已复现“旧请求仍可取消时合法发信号，却被测试判错”。测试现用显式异步握手控制切换，生产取消保护未改动。历史日志不足以重建当时确切调度顺序。

`quietSinceNowCursor` 的原始失败为 untrusted fence 和 nil cursor。已定位到没有可用设备游标且没有事件建立游标时的保守拒绝路径，但系统为何当时未返回游标仍未查清；不能宣称只是并发抖动，也不能与每日 journal UUID 变化直接等同。定向测试、六轮并发全套和临时 32 路原生探针均未复现。保留的测试新增 history/flush 原因与 provider 返回值诊断，不增加重试或放宽可信规则。最终默认并发全套 235 项通过（三个 opt-in 跳过），不代表历史偶发问题已解决。

- [x] 消除取消测试依赖毫秒等待的顺序假设，保留跨请求禁止误停断言。
- [ ] 捕获原生 quiet-cursor 失败的完整诊断，查明系统游标不可用原因；不得用串行通过、重试转绿或全局事件 ID 代替证据。
- [ ] 持续记录原生游标问题，不将目前未复现视作修复。该项保留为未决诊断，不再优先于每日全量重构；保留已有探针与全部可信事件保护。

### 历史规划：增量回退根因诊断与轻量探针（2026-09-29）

优先级已由 2026-10-01 每日全量规划取代。保留已实现探针和可信保护，以下历史调查不再作为默认每日扫描的设计目标。

目标：在下一次增量回退时，明确指出哪个阶段、哪个输入、哪条规则首先触发，并区分正常周期全量、事件历史失效和程序自身问题。本节取代此前“先压缩、增量调查后置”的当前优先级；旧记录保留为历史依据。下列探针已接入源码，安装与跨日观测仍待验收；本节不授权中断正在运行的检查。

已知证据：9/25、9/26、9/28 曾因 journal UUID changed 回退；9/27 同时记录硬链接身份歧义和缓冲区溢出，但缺少先后顺序，不能推断因果。增量检查的性能问题已修复，不再列为本节待办：兼容视图反复物化整代库存的问题已改为紧凑表按键查找，真实增量验收在 306 秒内完成且未回退全量，详见 `Docs/Testing.md` 的 “Incremental attribution materialization”。当前待查的是为何回退全量，以及 UUID 变化与游标缺失是否有关；不得将已解决的性能问题重新列为待排查根因。

#### 1. 保留决策、具体原因和因果顺序

- [x] 在 `ScanPolicy` / `DailyDiskRunCoordinator` 记录最初选择：首次全量、七天周期全量、用户强制全量或增量；记录检查点是否存在及周期判断依据，避免把计划内全量计为异常回退。
- [x] 从 `ScanCoordinator` 的 `recoveryRequired(reasons:)` 保留具体原因到上层恢复决策，避免只剩统一的 `eventHistoryLost`。增加稳定原因分类，不依赖解析展示字符串；不改变可信判断结果。
- [x] 用 request、run、attempt、session 标识关联同一请求下的增量尝试与恢复扫描。记录阶段、墙上时间、单调耗时和递增序号，单独保存首次触发原因及后续原因；不能用排序去重后的原因集合推断发生顺序。
- [x] 在失败清理前保存关键诊断，成功提交后记录结果；失败、取消、重启和报告恢复仍能串联。诊断写入失败不得推进检查点、改变核算或触发无限重试。

#### 2. 串联设备身份、日志 UUID 与游标

| 采样节点 | 必须记录的信息 | 排查目的 |
| --- | --- | --- |
| 卷发现 | Data 卷/文件系统身份、设备 ID 及原生转换值、拓扑组成 | 检查设备选择、挂载匹配和身份转换；设备号跨重启变化不能直接等同于换卷 |
| 读取检查点 | 已提交 UUID、游标、活动代及拓扑标识 | 确认数据库中的基准来源 |
| 打开事件流 | 实际设备 ID、原生 UUID、起始游标、会话角色 | 区分开流前已变化和会话内变化 |
| HistoryDone / flush | UUID、原生游标返回值、最高已交付事件 ID、批次边界及可信状态 | 确定缺失或拒绝发生的阶段；HistoryDone 不得作为文件事件 ID |
| 提交前后 | 预期旧检查点、拟提交检查点、事务成功状态及提交后值 | 区分读取、持久化和恢复缺陷；提交前日志不等同于提交成功 |

- [x] 在 `APFSVolumeProvider`、`SystemEventStoreUUIDProvider`、`FSEventHistoryReader` 及提交边界接入同一诊断上下文。全量的 E0/E1 两个会话也要明确区分。
- [x] 记录当前游标查询的 Unix/CF 时间基准入参、原始返回值、回退查询是否执行及最终采用值；区分原生返回零、设备转换失败和上层 nil。优先观察业务实际调用，额外只读探针的结果不得替代业务 fence。
- [ ] 对照自然发生的系统重启、睡眠恢复、挂载变化及日志重建，验证 UUID 变化与游标缺失是否存在共同原因。未取得证据前不得合并为同一个 bug，也不得把暂未复现当作修复。

#### 3. 汇总事件压力和身份歧义

- [x] 在 FSEvents mailbox 按批次记录回调/事件数量、关键 flags、缓冲区当前值与峰值、首次溢出时刻，以及消费数量和批次耗时。
- [x] 在 `InventoryMutator` 身份歧义处记录旧/新身份关系、链接数、剩余别名数量及事件标志；需要关联路径时采用受限匿名标识，不输出完整路径、文件名或内容。
- [ ] 通过统一序号还原历史缓冲溢出与身份歧义的先后关系，不凭两条并存错误推断因果。事件压力指标仅用于诊断回退原因，不代表重新开启已解决的增量性能排查；记录事件流停止时刻以区分回调期与停止后的处理。

#### 4. 日志约束、复现与验收

- [x] 手动和定时 helper 共用探针；默认记录阶段摘要与异常，详细批次采样可开关。回调线程不写磁盘，不逐事件创建日志任务；诊断队列必须有界，并记录诊断丢弃数量，与真实事件丢失严格区分。
- [x] 使用用户私有目录和受限权限，固定事件名/字段、无完整路径，轮转总量上限建议 20 MB。关键回退原因优先保留；不记录无限原始事件、不引入常驻任务或额外数据库膨胀。原始诊断不得提交仓库，公开结果只保留脱敏汇总。
- [ ] 合成测试覆盖静默目录、创建/修改/删除、目录改名、硬链接重建/inode 复用、事件突发/慢消费、UUID 变化、游标不可用及检查点恢复；断言首次原因、时间线关联和失败后旧检查点不变。
- [ ] 加入探针启用/关闭、日志轮转、队列饱和及写日志失败的测试；比较探针开关下的吞吐、延迟、内存和日志占用，确认诊断不改变业务结果、不制造新的缓冲溢出。
- [ ] 安装验证须等待当前任务安全结束，沿用原签名和安装路径。先进行同日多轮检查，再观察跨日及实际重启/睡眠恢复；异常全量比例应排除首次、用户强制和周期全量。
- [ ] 验收必须能还原一次回退的首因、阶段、设备/UUID/游标证据和后续恢复结果，再据证据修复实际原因。连续成功仅是观测结果，不足以单独证明间歇问题已消失。

实现记录：已接入策略、稳定原因、请求/尝试/会话上下文、实际设备游标查询、E0/E1、提交边界及身份歧义。默认摘要日志使用 512 条有界队列、20 MiB 轮转上限和 0700/0600 权限，详细批次采样每秒限频；诊断丢弃与事件丢失分别计数。序号表示进程内观测入队顺序，不证明跨线程或跨进程因果；有限保留与异常退出可能丢失证据。合成测试已覆盖策略选择、UUID 拒绝后恢复及旧检查点保留、游标回退入参、迟到回调隔离、探针开关、轮转、饱和和写入失败。已有文件事件回归继续保留，并非每个场景都新增了探针断言；RSS、长时间实扫开销、真实首因时间线及跨日验收仍待完成。操作与验证详见 `Docs/Operations.md`、`Docs/Testing.md`。 最终默认并发全套 252 项通过（3 个 opt-in 跳过），格式、构建、LaunchAgent 与空白检查通过。本轮未更新本机安装或操作已安装数据库。 随后按用户请求完成本机安装：等待 helper 空闲，以原持久签名替换原路径应用并重启 GUI；三个可执行文件的 designated requirements 一致，深度严格签名和 helper dry-run 通过。持有稳定/写入锁核对检查点、扫描记录与报告内容前后一致，定时任务注册保留。未启动新扫描，真实回退与跨日观测仍待验收。

实施顺序：决策与原因记录 + 身份/游标链路 → 按需增加批次压力/身份歧义探针 → 合成复现及跨日观察 → 根因修复与回归。始终保留 UUID、可信游标、事件丢失、硬链接和原子检查点保护；不以全局游标、忽略 UUID 变化、丢弃事件或重试转绿来避免全量恢复。内测不转换旧库存的决定不变，也不免除事务和恢复验证。

### 实机探针观测：2026-09-30 例行检查回退（已确认直接原因）

以下时间均为 Asia/Shanghai（UTC+8）。核对依据为私有 ScanProbes 日志、持有稳定数据/读取锁的只读数据库检查及系统 Unified Log；只记录脱敏汇总，不提交原始日志、卷身份或路径。检查时 helper 已退出，未启动新扫描、修改数据库或放宽可信规则。

- **今日 09:00 例行检查最终执行了全量恢复，并成功完成。** 09:00:05 收到 scheduled 请求；09:00:09 策略明确选择 `incremental`，不是首次、七天周期或用户强制全量。上次全量基准在前一晚，尚未达到 604,800 秒周期。
- **首次且唯一记录的拒绝原因是 `journalUUIDChanged`。** 同一请求的顺序为：序号 25/30 读取旧检查点 → 31 尝试打开增量会话 → 32 实际原生 UUID 查询 → 33 拒绝 → 36 增量失败 → 39 选择恢复 → 43 开始 `recoveryFull`。检查点中的 UUID 与系统 `FSEventsCopyUUIDForDevice` 返回值不同；拒绝发生于创建原生事件流前。增量尝试没有提交新检查点，恢复开始时仍读取原基准。数据库也记录一条 `dailySchedule` 增量失败和随后一条 `eventHistoryLost` 恢复成功，与探针一致。
- 今天 00:37:39 开始的手动增量成功，00:39:49 最后观测到旧 UUID，09:00:09 首次观测到新 UUID。前后 Data 卷、文件系统/卷组身份、设备号及其原生转换、拓扑标识均一致，仅 journal UUID 改变；系统启动时间早于本次观测窗口，可排除窗口内整机重启，但不能排除睡眠恢复、短暂挂载变化或守护进程日志重建。
- 恢复的 E0/E1 使用新 UUID，HistoryDone 和 live flush 均可信。两次实际游标查询的 Unix 路径均返回非零值，未执行 CF 回退；今天没有 `cursorUnavailable`、硬链接歧义或 mailbox overflow 拒绝，恢复 mailbox 峰值为 4,450。失败增量在 UUID 校验处已停止，因此没有该尝试的原生游标查询，不能推断旧 journal 的游标当时是否仍可用。诊断丢弃和写入失败均为零。
- 09:13:37 进入提交阶段，09:18:16 才记录事务提交成功及新 UUID/检查点，09:20:24 完成报告、通知与保留清理流程，整个请求约 20 分 19 秒。数据库的 run finished_at / report 时间为 09:13:37，不能把它误认为落盘或任务完成时间。

**系统侧进一步线索：** `fseventsd` 在 06:07:34.894 报告事件日志与卷不同步（`out of sync with volume`），并销毁旧日志；06:07:35.147 记录生成新 UUID，紧接着出现两条输出文件不存在的日志。上述事件落在本应用观测到的 UUID 变化窗口内，是系统主动重建日志的有力线索。不过 Unified Log 将卷路径和 UUID 隐去，现有记录无法将该系统事件与目标 Data 卷严格一一对应，也没有说明“不同步”的上游原因。后续文件打开失败发生在销毁/换 UUID 之后，不能倒推为本次重建的初因。01:45 的 history purge 记录本身同样不足以证明导致此次重建。

结论边界：已还原本次真实回退的首因、阶段、身份对比、旧检查点保留及恢复提交链路；这是 journal 身份改变后的保护性恢复，不能通过忽略 UUID 来强行增量。系统为何判定日志与卷不同步仍待查，尚不能宣称频繁回退问题已修复或与历史 nil-cursor 问题同源。此外，探针另记录到前一晚 22:58 起的手动请求因 `hardLinkRecreated` 回退，说明多次全量可能有不同原因，不能统一归因于 UUID 变化。

后续优先事项：

- [x] 还原至少一次真实定时回退的完整首因与恢复结果（本次 UUID 变化）。
- [ ] 针对系统 06:07 的日志重建，继续核对可获得的睡眠/唤醒、挂载及 fseventsd 生命周期证据；在能关联目标卷前，保留“相关线索”而非确定因果的表述。
- [ ] 单独分析已捕获的硬链接重建回退，判断是否有可安全消除的保守歧义，不与本次 UUID 变化合并。
- [ ] 继续跨日观察并单独追踪游标缺失；取得上游证据后再设计修复及回归，保留全部事件可信和原子提交保护。

### 根因调查执行规划（2026-09-30；尚未实施新增采集器）

目标分三层：① 已证实应用因 journal UUID 变化回退；② 将系统日志重建与目标 Data 卷可靠对应；③ 查明系统为何判定日志与卷不同步。仅同时出现两条日志或连续数次成功不足以完成②/③。Apple 的 FSEventsCopyUUIDForDevice 文档说明 UUID 不同表示事件流改变，列出的日志清除、磁盘擦除、事件计数回绕只是可能情形，不能直接套用为本机根因。

#### A. 优先保全现存证据并对齐系统时间线（普通权限优先）

- [ ] 尽早保存当前有界 ScanProbes 日志，以及 2026-09-30 05:55–06:20 的 fseventsd、diskarbitrationd、powerd、kernel 和与 fseventsd 有关的 launchd 日志；再按结果扩展到 00:39–09:01。使用 `log show --info --debug` 读取仍被保留的记录；这两个选项不会追溯生成此前未持久化的日志。
- [ ] 对齐 `pmset -g log`、系统启动时间、fseventsd 的 PID/进程生命周期和已有崩溃报告，区分实际 sleep/wake、dark wake、仅电源 assertion 释放、挂载/卸载和进程重启。06:07 附近出现 assertion 记录不能自行证明系统睡眠。补记 macOS 版本/build、当前卷组/文件系统身份及磁盘剩余空间；当前状态不能替代事发时状态。
- [ ] 核对同时间段备份/恢复、系统更新、磁盘/清理工具和用户操作的实际运行证据，特别是是否对事件日志所在卷做过删除、恢复或替换。不得从“安装了某工具”或某进程恰好活跃就判定责任；不递归遍历用户文件。
- [ ] 建立脱敏证据表：本地/UTC 时间、来源、进程、卷身份、操作、成功/失败及缺失字段。`<private>`、日志保留缺口和丢失记录必须标明，不将“查不到”解释为“没发生”。系统现存日志若无法关联卷，结论仍为高度相关线索。

可在普通终端手动采集的最小命令（新建私有目录，位于 repo 和 DailyDisk 运行目录之外）：

```bash
umask 077
DD_DIAG_DIR="$(mktemp -d "$HOME/Library/Logs/DailyDisk-investigation.XXXXXX")"
/usr/bin/log show --style ndjson --info --debug \
  --start '2026-09-30 05:55:00+0800' --end '2026-09-30 06:20:00+0800' \
  --predicate 'process == "fseventsd" OR process == "diskarbitrationd" OR process == "powerd" OR process == "kernel" OR (process == "launchd" AND eventMessage CONTAINS[c] "fseventsd")' \
  > "$DD_DIAG_DIR/system-window.jsonl"
pmset -g log | awk '$1 == "2026-09-30" && $2 >= "05:55:00" && $2 <= "06:20:00"' \
  > "$DD_DIAG_DIR/power-window.txt"
sw_vers > "$DD_DIAG_DIR/os-version.txt"
sysctl kern.boottime > "$DD_DIAG_DIR/boot-time.txt"
printf '%s\n' "$DD_DIAG_DIR"
```

若某一命令报权限不足，仅对该采集操作按实际报错补充权限；先保留报错，不改系统保护设置。短窗口文本也可能较大，应检查输出体积再决定是否扩大范围。原始材料只在本机私有目录保存，仓库仅存脱敏结论。

#### B. 缩小 UUID 改变窗口并确认目标卷（拟新增独立只读诊断工具）

- [ ] 设计一个显式启动、最多运行 24 小时的临时采样工具，每 60 秒调用一次目标设备的 `FSEventsCopyUUIDForDevice`，并记录时间、单调时间、启动标识、Data 卷/文件系统身份、dev_t 转换、journal UUID、fseventsd 可见 PID 和采样错误。遇到设备/挂载变化重新校验 Data 卷，不把旧设备号当成永久身份。只记录摘要，不读取日志文件内容，不建立库存、不写检查点，也不增加产品常驻 helper 或永久 LaunchAgent。
- [ ] 日志上限 2 MiB、0700/0600 权限、单写入队列；记录启动配置和停止原因。睡眠期间不阻止休眠，也不假装每分钟都采到了值；唤醒后记录采样空档。UUID 变化只定位到最后旧值和首次新值之间，不能声称精确发生时刻。工具自身 I/O 与睡眠采样缺口须纳入解释。
- [ ] 工具开始前测试：正常相同 UUID、切换、nil、设备号变化、睡眠式采样空档、写日志失败及期限退出；确认与现有检查并行时不改变业务 fence、权限或检查点。先部署一天，按实际证据决定是否延长，不自动无限续期。
- [ ] 若允许读取受保护目录，可补充固定 `.fseventsd` 目录及固定身份文件的存在性/元数据，仅用于对应重建时刻；不用递归扫描、轮询文件内容或修改目录。FDA/POSIX/SIP 的实际限制分别记录；读取失败即跳过，不能为此关闭 SIP。

#### C. 只有证据不足时升级系统采集（需要本机管理员参与）

本机已核对 `log help` 和手册；`log config --status --process fseventsd` 返回需要 root。以下操作是调查工具权限，不改变 DailyDisk 无 root helper 的产品模型，也不意味着已开启采集。

| 操作 | 权限/用途 | 限制及退出方式 |
| --- | --- | --- |
| 普通 `log show`、`pmset`、现有探针和 UUID API | 先用当前用户，只读时间线和身份 | 当前已能读到 fseventsd 重建记录；受保护文件按实际失败决定是否给运行终端 FDA |
| `sudo /usr/bin/log collect --last 1h --size 200m --output "$DD_DIAG_DIR/incident.logarchive"` | 管理员，复现后及时保全系统日志 | 按本机工具支持设置 200 MB 收集上限，检查实际磁盘占用；不能恢复已隐藏字段，旧事件使用覆盖其时间的 `--start` 而非固定 last 1h |
| `sudo /usr/bin/log config --status --process fseventsd` | 管理员，查看当前日志配置 | 如确需 info/debug，先保存原配置，明确只限 fseventsd、最长 24 小时，再配置并恢复原值；不是全局开启 debug |
| `sudo /usr/bin/fs_usage -w -f filesys -t 120 fseventsd` | 管理员，复现窗口内观察守护进程文件操作/失败 | 最多 120 秒；必须配套私有、有容量限制的接收器再写盘。仅追踪 fseventsd 看不到其他进程删除文件的全部证据，不能据此排除外部操作；不默认整夜全系统追踪 |
| `sudo /usr/bin/sysdiagnose -f "$DD_DIAG_DIR"` | 管理员，复现后尽快采集系统诊断 | 会额外产生 I/O 和较大文件，无上述 200 MB 上限，先检查空间；手册支持 Ctrl-Option-Command-Shift-句点快捷键触发，默认材料位于 /private/var/tmp。由用户本机输入密码，勿发密码给 agent |

- [ ] 若 `<private>` 是关键障碍，向 Apple 获取适合当前 macOS 的官方日志 profile/采集指导后再安装，记录启用期限及移除方法；不使用未经验证的 `private_data:on` 或承诺 root 能解密历史隐藏字段。本机 `log help config` 没有列出该开关。额外采集的路径/身份只留本机，完成分析后按用户决定删除。
- [ ] 每次改变日志级别或增加追踪，都先确定范围、磁盘预算和恢复配置的方法，再由用户授权该具体系统变更；当前请求仅完成规划，未修改系统日志设置、安装 profile 或运行管理员采集。

#### D. 用证据决定修复与验收

- 若目标卷确实被系统重建日志，查明前置操作：有确切删除/恢复调用则定位调用者；有实际挂载/睡眠/进程异常则围绕该触发条件复现。只在可丢弃的测试卷/虚拟机重现破坏性操作，不删生产 `.fseventsd`、不 kill 系统守护进程、不重置基线来试错。测试卷结果不能自动等同于启动 Data 卷问题。
- 若 OS 返回值稳定而数据库/应用身份不一致，转查设备选择、持久化和会话上下文；目前证据支持系统返回 UUID 确实改变，但仍保留对其他时段应用缺陷的检验。
- 若系统持续自行重建且上游无法从公开诊断中判断，向 Apple Feedback Assistant 提交私有 sysdiagnose、最小时间线、OS build、卷身份对照和只读 UUID 采样复现；原始材料不公开发布，提交前由用户决定。内核/守护进程内部原因可能需要 Apple 分析，不保证靠更多权限即可查明。
- 验收必须包括目标卷关联、触发条件的独立证据、修复后相同条件下的回归与跨日观察；单日成功或仅有相关时间不足。硬链接歧义继续作为独立分支调查。始终保留 journal UUID、游标、事件丢失和原子检查点保护。

参考：[Apple FSEvents UUID API](https://developer.apple.com/documentation/coreservices/1444453-fseventscopyuuidfordevice)、[Apple Feedback Assistant](https://developer.apple.com/feedback-assistant/)、[Apple Profiles and Logs](https://developer.apple.com/feedback-assistant/profiles-and-logs/)，以及本机 `log help show/config/collect`、`man fs_usage`、`man sysdiagnose`。

### 根因调查执行结果（2026-09-30；新增系统更新线索，尚未定论）

已按规划保存私有探针副本、05:55–06:20 系统/电源记录，并追加 06:07:32–06:07:36 短窗口全进程日志。采集位于本机 `~/Library/Logs/DailyDisk-investigation-20260930/`，原始材料不入库。当前 macOS 为 26.5 / 25F71。现存记录显示 fseventsd 与 diskarbitrationd 自本次系统启动后持续运行；短窗口电源日志没有实际 Sleep/DarkWake/Wake 转换记录，不能将 assertion 变化解释为睡眠。

新增证据链（本地时间）：

1. 06:07:32.840，softwareupdated 报告持久化状态校验失败（SUMacControllerError 7403），随后进入 `PurgeAllAssetsAtStartup` 清理。
2. 06:07:34.114，系统 `CleanupPreparePathService` 清理未使用的已准备更新；期间多次挂载/卸载 System 卷，并明确记录回退系统更新快照。
3. 06:07:34.151 起，Disk Arbitration 向 fseventsd 等订阅者发送该 System 卷的 `DAVolumePath` 变化通知。
4. 06:07:34.894，fseventsd 报告日志与卷不同步并销毁日志；06:07:35.147 生成新 UUID。

这使“软件更新状态恢复/清理和临时 System 挂载触发日志重建”成为优先验证假设，证据比单纯同日活动更具体。但更新服务明确操作的是 System 卷，而已经确认 UUID 改变的是内置 Data 卷；日志重建记录仍隐藏卷身份。**尚缺将两者连成因果链的证据，不能宣称已经确定 macOS 更新服务是根因，也不能据此禁用更新或删除更新状态。** 日志中的负数及计数含义未经验证，不作为已解码的错误原因。

用户补充外接 `/Volumes/Data`：只读检查确认它是外置 USB APFS 卷，与内置 `/System/Volumes/Data` 属于不同设备/容器，设备身份不同，当前 journal UUID 也不同。现存短窗口日志未找到外接设备的挂载/卸载记录；应用旧探针没有其跨夜 UUID 样本。因此暂没有支持“外接盘导致内置卷回退”的证据，但不能排除系统守护进程层面的间接影响。不能因为同名 Data 就合并两个卷，也不能仅靠拔盘后单次成功定责；如需拔盘对照，先由用户安全推出且确认无读写，再做多轮对照。

实施了独立开发诊断工具 `Scripts/observe-event-journal.py`（本机 Python 3，非产品运行依赖）。显式启动，60 秒采样、最长 24 小时、日志上限 2 MiB，私有目录/文件 0700/0600，串行写入，无库存/数据库/检查点写入，无永久 LaunchAgent、无防休眠。记录启动标识、设备/卷身份、UUID、进程 PID、墙上/单调时间与采样空档；每轮重新核对挂载和设备，nil/失败单独记录。限额/期限/信号终止；睡眠时不执行，唤醒后检查期限。采样由 diskutil 的 DeviceNode 对应块设备 rdev 驱动，而非直接采用 `stat("/").st_dev`：本机根路径 stat 呈现 Data 设备，不能拿它冒充 System 采样。mount/设备校验仍是离散观察，不能排除两次调用间极短的挂载变化。

本轮已启动三路 24 小时采样（Data、System、外接 Data），无自动续期。私有输出目录由 `~/Library/Logs/DailyDisk-investigation-20260930/observer-launch.txt` 指示，其中 `observer.pid` 记录 PID；要提前停止，先核对该 PID 对应此脚本，再发送 SIGTERM。观察结束后读取 `samples.jsonl` 的 stopped 记录确认退出。没有更改已安装应用或启动扫描。

验证：4 项独立 Python 合成测试通过，覆盖 UUID/设备变化、nil、根路径设备与块设备差异、睡眠式期限、时钟回退、输出容量/权限/失败；短时本机三路采样通过且按期限退出，三卷得到不同 UUID。首次短时试运行发现本机 diskutil plist 不提供 Mounted 字段，已改为 MountPoint/设备校验后再启动正式采样。24 小时自然变化尚未观测完成，不将启动成功等同根因验收。

权限边界：`sudo -n true` 确认需要密码，固定 `.fseventsd/fseventsd-uuid` 元数据读取被 POSIX 权限拒绝。没有尝试绕过权限、修改日志级别、安装 profile 或运行 root 追踪。若下次复现仍无法关联卷，由用户在本机终端执行规划 C 的有限日志归档/sysdiagnose，或申请 Apple 对当前系统的诊断指导；不要把密码交给 agent。

下一次优先读取三路 UUID 时间线，检查是单卷还是多卷变化，再围绕变化前后软件更新清理、临时挂载及 fseventsd 操作缩小采集窗口。独立继续排查硬链接歧义。当前结论为“确认保护性回退原因，并发现具体上游候选”，不是根因已经修复。

### 多日回退对比与软件更新状态追查（2026-09-30 10:40 截止）

本轮只读查询了 9/24 00:00 至 9/30 10:40 的系统日志。结果保存在此前私有调查目录的 `multiday.jsonl`、`fsevents-coverage.json`、`update-startup.jsonl`、`control-cleanup.jsonl`；原始身份/路径不入库。以下是**查询实际返回的记录**，不是完整系统事件统计。

| 日期（本地） | 已知 DailyDisk 回退 | 本轮返回的 7403 加载失败实例数 | 返回的系统快照回退日志条数 | 能否对应系统 journal 重建时刻 |
| --- | --- | ---: | ---: | --- |
| 9/24 | 历史记录为 UUID 变化，手动恢复 | 3 | 7 | 无该日 fseventsd 可读记录，无法对齐 |
| 9/25 | 历史记录为 UUID 变化，每日增量失败 | 3 | 12 | 同上 |
| 9/26 | 历史记录为 UUID 变化，每日增量失败 | 5 | 15 | 同上 |
| 9/27 | 历史记录为硬链接歧义及 mailbox overflow | 12 | 37 | 同上；回退类型本来就不同 |
| 9/28 | 历史记录为 UUID 变化，每日增量失败 | 12 | 38 | 同上 |
| 9/29 | 探针：22:58:56 首次硬链接拒绝，23:04:05 选择全量恢复 | 16 | 39 | fseventsd 仅从 20:37:02 可读，此段无 UUID 重建记录 |
| 9/30 至 10:40 | 00:37 手动增量成功；09:00:09 定时 UUID 拒绝并恢复 | 7 | 19 | 06:07:34.894 重建，06:07:35.147 新 UUID |

7403 计数取 `Failed to load persisted state` 并按 boot/process 实例去重，避免同一错误被五条上层日志重复计数；快照列是日志条数，同一清理可能回退两次，不能解释成独立更新次数。历史回退类型来自此前已记录的实机核查，9/24–9/28 的旧数据库/报告已在获授权的 schema 6 重置中删除；旧日志和备份不在当前数据根内。本轮 DailyDisk Unified Log 查询也未返回记录。因此没有依据补写这些日期的精确回退时分秒，不能直接把 09:00 调度配置当成实际执行时间。

**日志覆盖限制已单独验证：** 对 fseventsd 进行不带错误关键词的整段查询，最早返回 9/29 20:37:02，共返回当晚 2,049 条、9/30 截止 10:40 的 6,148 条；早期没有可读记录。软件更新记录保留更久，所以“早几天有更新清理、没有 fseventsd 重建日志”不能解释为当时没重建。现存 fseventsd 覆盖窗口内返回了 22 条快照回退日志，却只有一次 out-of-sync/new-UUID 记录；说明更新清理不是每次都伴随可见重建。

#### 7403 的具体来源已缩小到缺少更新上下文，而非已证实文件损坏

本轮按同一软件更新进程和线程关联读取记录，避免把并行加载 DDM 状态的日志误当作控制器状态：

- 06:07:32.543，launchd 因 Mach IPC 启动 softwareupdated；现存日志未确定最初调用者，不能断言是用户操作或固定每日任务。
- 06:07:32.827–32.832，控制器**成功读入** `SoftwareUpdateMacController.state`；结构/版本字段存在，业务 policy 字段只含 `PersistedVersionNumber=25F71`，其余更新对象为空。
- 06:07:32.835，同一线程明确记录缺少 access control context、update UUID、descriptor、overrides；随即以 SUMacControllerError 7403 拒绝该状态。
- 06:07:32.841–32.842，控制器自行执行 currentUpdateCancelled、清除状态文件并确认删除成功，然后创建空状态并重新设置 PersistedVersionNumber。因此稍后的“找不到状态文件”是此次主动清除后的结果，不能拿它反证之前文件被外部清理工具删除。
- 之后进入 PurgeAllAssetsAtStartup / removeAllUpdateContent，CleanupPreparePathService 清理准备更新，临时挂载 System 卷并回退更新快照；随后发生此前已记录的 out-of-sync 和 journal 重建。

07:07:28–07:07:31 的独立对照窗口同样读到只含版本号的状态、缺少同样四个字段、两次回退同一系统快照和多次临时挂载/卸载；该窗口没有 out-of-sync/new-UUID 记录。由此不能宣称“7403 是文件损坏”或“7403/快照回退必然导致 Data journal 重建”。一种待验证解释是无活动更新时保留版本号的状态在启动恢复路径中被判无效并例行清理；这只是对日志的解释，不是对 Apple 内部设计的已证实结论。

当前证据强弱：

1. **已确认：** 今天 DailyDisk 比较的是内置 Data 设备的实际 UUID；UUID 改变导致保护性全量恢复。
2. **已确认：** 软件更新在 06:07 执行了具体状态恢复/清理与 System 快照操作；fseventsd 几百毫秒后记录不同步和重建。
3. **尚未确认：** 隐藏卷身份的系统重建是否就是内置 Data 的那一次；System 操作为何影响 Data；为何同类清理的大多数时段未出现重建；最初是谁触发软件更新启动。不能将相关时间线升级为完整因果链。

后续收敛方向：保留正在运行的三路 UUID 采样，在下一次变化时同时确认 Data/System/外接卷是否一起改变；以**未触发变化的同类更新清理为对照**，比较设备映射/挂载状态及日志重建前的文件操作。若还缺日志目录身份和实际 I/O，只增加有限窗口、明确进程范围的管理员追踪或 Apple 指导的诊断，不全局关闭隐私、不删更新状态或 FSEvents 日志、不禁用系统更新来试错。当前没有证据支持把外接 SSD 或某个清理工具定为责任方。

本轮未修改生产代码、应用安装、数据库或系统配置，未触发更新/扫描；仅采集分析及文档更新，空白检查通过。三路观察继续按原 24 小时期限运行，不延长、不重启采样。

### 第二次自然复现与实时证据保全（2026-09-30）

13:21 检查已运行采样时发现问题已自然复现，无需等到明天：10:50:14 的样本仍为旧 UUID，10:51:15 内置 Data 首次变为新 UUID，10:52:15 保持新值；三个样本中 System snapshot 与外接 Data 的 UUID 均不变，fseventsd PID 也未变。每轮三卷串行读取，时间为采样轮开始时间，变化窗口约一分钟，不能将其当作精确原生事件时刻。

及时保全了 10:49–10:52 的系统记录（私有 `second-recurrence.jsonl`）：

- 10:50:49.621，软件更新状态再次因缺少同样四类字段校验失败。
- 10:50:52.498，CleanupPreparePathService 回退同一系统更新快照。
- 10:50:53.202，fseventsd 报告 out-of-sync 并销毁旧日志；10:50:53.260 生成新 UUID。第二次快照回退日志位于两者之间。
- 此事件落在采样确认的内置 Data UUID 变化窗口内；这比第一轮跨夜间隔提供了更强的卷/时间关联，且排除了此次“只有外接盘 UUID 变化被当作 Data”以及守护进程 PID 改变的解释。但重建日志中的卷身份仍隐藏，不能把窄时间关联等同于完整文件操作因果证明。

两个自然复现都伴随同类更新清理，另有未触发可见重建的清理对照。当前优先假设仍是某种临时挂载/快照清理条件触发日志不同步；为何只有部分清理触发，以及对应哪个文件/卷操作，尚待定位。不得承诺“明天一定查清”：可能没有再次复现，也可能关键内核/守护进程信息只有 Apple 能解释。

为避免再等一次却丢失过程，新增并已运行 `Scripts/record-journal-system-log.py`：普通权限 `log stream --level debug`，只筛选 fseventsd、更新状态加载/清理、快照/挂载、Disk Arbitration 卷路径变化与相关进程启动；不改变全局日志级别或隐私配置。串行逐行写入私有目录，2 MiB × 10 文件轮转，总量不超过 20 MiB（不含微小 PID/result 文件），单行过大计数丢弃，期限/信号停止并回收 log 子进程。实时流只能采到系统实际发出的事件，仍可能有系统日志丢失与 `<private>` 字段，不能声称包含全部文件操作。

实时记录器截止时间与已运行的三卷采样对齐，约 10/1 10:32，未延长 UUID 采样期限。输出目录由私有调查目录 `system-recorder-launch.txt` 指示；其中 recorder.pid/result.json 用于核对进程和退出原因。轮转可能覆盖早期记录，故本次两个已知复现窗口已独立保存。只读观察器继续每分钟采样，不引入产品常驻服务，也不主动触发更新或重建。

验证：实时流短时运行可启动并按期限退出；轮转、权限、完整行、容量和关闭后拒绝写入的合成测试通过。三卷采样原有 4 项测试继续通过。管理员 `fs_usage`/sysdiagnose 尚未执行（sudo 需要用户本机认证）；若普通证据仍不足，应在明确范围和容量的前提下补充文件操作追踪或 Apple 指导，不把现有普通权限采集宣称为足以保证根因结论。新的实时采集会产生少量系统事件和 I/O，属于观测扰动，必须纳入比较。

### mailbox 快速失败（2026-09-30）

已实现不可恢复的 mailbox 信任失败的协作式快速退出：历史 drain 前、原生 flush 前、每个实时 drain、consume 前后检查历史/实时 assessment；仅 `fullScanRequired` 触发，`subtreeRescanRequired` 保留原修复路径。即使历史仍未消费完，已经观察到的实时溢出也使本次尝试无效。消费期间通过 TaskLocal 捕获信任检查并包装 mutator 的进度 observer，文件/子树已有协作检查点可及时退出，不必等待整个 4,096 条批次应用结束。当前正在执行的单个同步系统调用/数据库操作不能被立即抢占，不承诺固定毫秒延迟。

退出抛出专用 EventReplayInvalidated，不构造提前完成的可信 fence、不清除丢失标志、不推进游标。session 原有 catch 停止原生事件流；增量层转换成原有 recoveryRequired 错误并执行失败清理，再由 ScanCoordinator 选择恢复。既有取消优先级、旧检查点和原子提交保护保持。全量 E0/E1 的消费也会终止并进入原有失败清理；不会在无可信游标时激活 staging。该修复减少失败后无效工作，不降低事件数量，不解决 UUID 变化或本身的容量不足；mutator 独立身份歧义的处理策略未变。

验证：默认并发全套 254 项通过（3 个 opt-in 跳过），格式、构建、LaunchAgent 和空白检查通过。新增覆盖：HistoryDone 前溢出在下个消费检查点停止、实时丢失中止未完历史、子树重扫标志不误报；恢复端同时覆盖原 fence 拒绝及专用快速失败，断言 session 已 stop、无失败尝试提交、恢复使用旧 generation/cursor 且恢复成功。未更新本机安装。

UUID 采样复查截至 9/30 15:49:51：315 轮、三卷查询零错误；只有 10:50:14–10:51:15 内置 Data 的已知一次变化，随后未观测到新的变化，System/外接 Data 无变化。60 秒离散采样无法证明间隔内绝无短暂变化；现有观察器及实时日志记录器继续运行，未重启或延长期限。

### 历史存储优化与增量调查（第一轮已验收；第二轮 2A 已完成）

以下为历史规划和验收记录；每日增量优先的产品方向已被每日 05:00 全量、同日后续手动增量取代。保留日期、实际运行时间和测量结果，不将其作为当前目标设计。

目标：降低 DailyDisk 的常驻占用和扫描期间的峰值占用，同时保留历史报告、可靠恢复能力和现有扫描性能。以下记录 2026-09-24 的初始测量及 2026-09-28 对最近四天扫描的只读复查，不代表后续实时状态，也不代表优化已经完成。接手时先核对代码和数据状态；已有的扫描、分页及提交性能修复必须保留。实施优先级（2026-09-28 用户调整）：先安全降低磁盘占用，再优化存储结构；连续增量失败的根因排查后置，可信 FSEvents 校验保持不变。

#### 已授权实施规划（2026-09-28）

第一轮先实现以下内容，不改路径存储结构、不删除历史 ledger/样本/报告，也不放宽增量可信检查：

- [x] 新增编号 migration，记录 generation 的退休时间；报告发布且无恢复引用后最多保留一份 retired，默认恢复窗口 24 小时，从被替换时起算。旧库迁移时给予完整恢复窗口，不用创建时间冒充退休时间。
- [x] 新库存和检查点已提交、报告已持久化、没有运行/恢复引用后，才可清理过期 retired。helper 在后续工作建立 staging 前检查；不增加常驻进程。删除仍保留集合清理触发器、外键和查询索引。
- [x] 增加 GUI 发起、helper 执行的独立空间维护请求及真实状态。在独占 writer/维护锁下检查恢复状态、可用空间，清理过期库存，执行原生 VACUUM，验证库存、检查点和报告，记录实际分配空间变化。维护不得与扫描、重置或不安全的连接切换竞争。
- [x] 采用低频维护策略：自动维护评估起点为 freelist 超过 1 GB 且超过 25%，距上次尝试至少七天；根据全量复用需求调整。手动维护也要执行空间和恢复前置检查，不每日无条件压缩。VACUUM 最坏额外空间按原库两倍并加 1 GB 余量预检；不足时保留原库并给出明确状态。
- [x] “本轮自身增长”继续使用原采样边界；设置中另显示当前数据占用、SQLite 可复用空间及上次维护释放量。不要将维护后占用替换进历史报告。
- [x] 明确维护可取消边界及崩溃恢复，覆盖空间不足、锁竞争、中断和重启；失败必须保留活动基线、检查点和报告。维护恢复先于新扫描。
- [x] 验证百万级长路径、多代库存、重复全量恢复的稳定占用、数据库/WAL/SHM 采样峰值与耗时，保留现有分页、opaque 保留和增量查询/提交性能预算。运行第 7 节检查及 opt-in 百万行测试，更新数据库、操作、测试和用户文档。系统临时文件和真实扫描峰值仍待安装验收。

第二轮在实测后确定新 schema：优先比较 generation/volume 整数代理键与共享完整原始路径字典；父节点加名称方案已按用户要求进入补充实验，正式接入选择待实测更新。必须保持原始非 UTF-8 路径、范围分页、硬链接唯一归属、历史视图隔离及可靠迁移。历史 ledger 的保留/归档另行设计。

性能取舍：清理和 VACUUM 会产生集中 I/O、WAL 及临时空间，需独立维护和低频触发；过度回收会使后续全量重新扩容。路径字典可能增加关联和垃圾回收成本，不能直接删现有索引换空间。第一轮验收按“增量仍失败、持续全量恢复”的情形进行，不承诺固定压缩比例或 1 GB 以下。

#### 第一轮实现与合成验收结果（2026-09-28）

Schema 5、retired 清理、独立维护请求、GUI 状态及空间不足/崩溃恢复已实现。百万行长路径测试连续替换两代库存并维护：实际分配由 2,720,239,616 / 2,605,862,912 字节分别降至 1,012,027,392 字节，维护耗时 37.88 / 33.15 秒。回收后 32 次窄子树增量查询 0.056 秒、提交 0.012 秒；opaque 保留 26.89 秒、完整 diff 30.84 秒，均通过原有预算。50 ms 采样记录的数据库/WAL/SHM 最大峰值为 3,743,653,888 字节；不包含 SQLite 在系统临时目录的所有文件，也不代表真实遍历峰值。

第 7 节格式、构建、常规测试和 LaunchAgent 检查通过，百万行测试单独通过；开发包签名校验及 helper dry-run 通过。常规测试运行器报告 222 项通过（压力用例默认跳过）；一次先前运行中两个既有时序/原生 FSEvents 测试偶发失败，无代码变更复跑通过，详情见 `Docs/Testing.md`。这不代表增量失败根因已解决。

首次代码验收未更新本机安装、未迁移或压缩真实数据库；随后完成了下述用户授权的单次安装与维护验收。24 小时窗口按退休时刻计算，下一次每日检查开始时可能尚未到期，因此全量扫描仍可能同时持有 active、retired 和 staging。第一轮解决可安全回收的空间及维护入口，不消除路径重复存储，也不保证持续全量恢复时文件不再扩容。完整视觉验收、多日空间趋势、完整临时文件峰值及后续结构优化仍待完成；以下未勾选的广义验收项包含这些后续工作。

2026-09-28 本机维护验收：使用原持久签名身份、bundle ID 和安装路径更新应用，重启 GUI，通过已注册 helper 执行独立维护。先在写入锁保护下备份运行数据并逐字节验证数据库副本，保留旧应用；维护完成后对全部原有业务表列按主键顺序计算摘要，与备份逐项一致，报告文件摘要亦完全一致。原有两代库存、活动检查点及 10 份历史报告均保留。压缩前 schema 4 和压缩后 schema 5 的严格 CLI 验证均 healthy，所有完整性/外键/检查点约束/报告检查通过，WAL 为空，helper 退出码为 0。最终数据库实际分配从 12,985,589,760 降至 7,183,630,336 字节，减少 5,801,959,424 字节（约 5.80 GB / 44.7%），freelist 从 4,997,627,904 字节降至 0。helper 维护含前后验证耗时 17 分 52 秒；这是真实单次测量，不能用合成测试耗时估计真实维护时长。全部验证通过后，按用户要求删除了本次数据及旧应用备份。未执行新扫描，未改变既有报告采样边界。

#### 已确认的现象与原因

报告中的“DailyDisk 自身 +3.83 GB”来自两次分配空间采样之差：2026-09-23 09:02:39 为 4,345,466,880 字节，2026-09-24 11:25:11 为 8,172,830,720 字节，相差 3,827,363,840 字节。时间为本地时间，本文 GB 使用十进制。该项统计 Application Support 下的数据库及其他运行数据，不是应用安装包大小。

采样发生在 `collectingDiagnostics`、原子提交之前，提交和报告发布还会继续写入。因此这项增量不是任务结束时的最终占用。该次任务完成后，SQLite 文件逻辑大小为 8,886,820,864 字节，实际分配约 8.89 GB；WAL 为零、没有活动扫描，运行临时表已清空，报告和日志合计约 160 KB。主要空间来自持久化库存及索引，不是日志或未退出的扫描进程。

当时 `dbstat` 与 SQLite 页统计如下（按组取近似值）：

| 组成 | 占用 | 原因 |
| --- | ---: | --- |
| `inventory_paths` 及三个索引 | 5.03 GB | 路径、父路径与索引键重复存储 |
| `canonical_attributions` | 1.12 GB | 规范归属中再次保存完整路径 |
| `inventory_objects` 及唯一索引 | 1.15 GB | 对象元数据与复合键重复存储 |
| `change_ledger` 及索引 | 0.20 GB | 历史变化记录 |
| SQLite 空闲页 | 1.38 GB | 删除记录后可复用，但尚未归还文件系统 |

具体结构性原因：

1. 当时同时保留 active 和 retired 两份完整 generation；每轮全量扫描约访问 240 万条路径。`InventoryStore.pruneGenerations` 使用 `LIMIT 1` 保留最近一份 retired generation，没有按时间到期的清理机制，后续只有增量检查时仍会长期保留。
2. 保存的是文件名称和元数据，而非文件内容，但百万级记录乘以长路径和多个索引仍很大。`inventory_paths` 是 `WITHOUT ROWID` 表，主键为 `(generation_id, path)`；二级索引会附带缺失的主键列。实测 `inventory_paths_parent_object_idx` 即使声明中没有 `path`，也包含完整路径。同一路径在路径表、三个索引和规范归属表中反复出现，`parent_path` 又重复前缀。
3. generation/volume 的 UUID 文本在大量记录和索引中重复。全量扫描期间还会同时存在 staging、运行覆盖层和 WAL，峰值会高于稳定状态。
4. 当时 `page_size = 4096`、`page_count = 2169634`、`freelist_count = 338129`，空闲页共 1,384,976,384 字节；`auto_vacuum = 0`。删除旧记录只产生内部可复用空间，不会自动缩小数据库文件。

#### 2026-09-28 复查：新增证据及判断边界

| 指标 | 9 月 24 日任务完成后 | 9 月 28 日任务完成后 |
| --- | ---: | ---: |
| 数据库实际分配空间 | 8.89 GB | 12.99 GB |
| SQLite 空闲页 | 1.38 GB | 5.00 GB |
| 非空闲数据库页 | 7.50 GB | 7.98 GB |

9 月 28 日文件逻辑大小为 12,978,671,616 字节，实际分配为 12,985,589,760 字节；`page_size = 4096`、`page_count = 3168621`、`freelist_count = 1220124`，空闲页共 4,997,627,904 字节，`auto_vacuum = 0`。相对 9 月 24 日，新增数据库页空间约 88% 最终为空闲页；“非空闲页”仍包含索引和页内未用空间，不等于纯有效数据大小。本次没有重新执行逐表 `dbstat`，不能据此认定哪张表贡献了剩余增长。

仍只有一份 active 和一份 retired generation，运行覆盖层为空、WAL 为零、helper 已空闲；最近几天全量库存约 234 万条路径，没有数量暴涨。由此排除“每天永久累积一份完整库存”的解释。连续全量恢复、文件扩展后不收缩与当前证据一致，但各阶段瞬时峰值尚未连续测量，需要后续补证。

| 日期 | 提交前自身占用采样 | 相比上次增长 | 增量失败记录 | 启动至完成报告约耗时 |
| --- | ---: | ---: | --- | ---: |
| 9/24 | 8.17 GB | +3.83 GB | journal UUID changed | 32 分钟（手动恢复轮次） |
| 9/25 | 11.95 GB | +3.77 GB | journal UUID changed | 37 分钟 |
| 9/26 | 12.64 GB | +688 MB | journal UUID changed | 39 分钟 |
| 9/27 | 12.85 GB | +218 MB | 硬链接身份无法判定，同时事件缓冲区溢出 | 43 分钟 |
| 9/28 | 12.90 GB | +50 MB | journal UUID changed | 41 分钟 |

9/25–9/28 的每日增量均失败并转为成功的全量恢复，最近一次成功增量仍为 9/23。生成成功报告不代表增量链路健康。UUID 比较失败的记录为 `FSEvents journal UUID changed`；9/27 同时记录 `A hard-linked path was removed and recreated before identity could be disambiguated` 和 `DailyDisk FSEvents buffer overflowed`。目前无法区分 UUID 变化来自系统重建日志还是设备匹配、取值或检查点处理缺陷，也不能由两条并存错误推断其因果顺序。自身增长放缓与空闲页复用一致，但不足以证明长期稳定。

另外，9/27 物理增长 5.00 GB、普通文件净变化 -504 MB、自身增长 218 MB、未归因部分 5.29 GB；9/28 分别为 +4.52 GB、+31 MB、+50 MB、+4.44 GB。最近两天物理增长主体已不是 DailyDisk 自身。报告记录 214 个不可读路径、9/28 约 1.56 GB 已删除但仍打开文件的逻辑大小，以及不完整的快照诊断。这些只能作为线索：逻辑大小不是唯一物理块占用或每日增量，快照数量差为零也不能在覆盖不完整时排除快照影响。

#### 后续：定位连续增量失败，减少不必要的全量恢复（用户要求后置）

- [ ] 为 journal 校验补充有界、无路径的诊断：比较双方 UUID、设备身份、事件游标、取样阶段和失败分类，区分无法读取与确实变化；核对发现卷、事件 session 和持久化 checkpoint 使用的设备是否一致。保留有限历史以关联重启、挂载变化和日志重建，不把真实机器标识或日志提交到仓库。
- [ ] 复现 UUID 跨日不匹配，分别验证系统日志重建、读取/匹配错误和检查点持久化问题；取得证据后再修复。真实 UUID 变化或事件丢失时仍必须恢复，不得放宽可信检查来强行保持增量模式。
- [ ] 分别调查 9/27 的硬链接身份歧义与缓冲溢出。测量历史事件回放速率、消费速率、队列高水位和批次处理耗时；评估有界处理或可靠暂存，不能仅无限增大内存缓冲，也不能丢事件后推进游标。仍存活的硬链接别名无法消歧时保留恢复策略。
- [ ] 加入跨 session、跨进程及历史事件突发的合成回归，覆盖稳定/变化 UUID、真实溢出和硬链接替换。实际连续多日记录执行模式、恢复原因、总耗时和空间趋势；仅单次手动增量成功不足以验收。真实必须恢复的情况应明确呈现原因。

#### 第一轮：明确保留周期并安全回收空间

- [ ] 建立优化前基线：分别统计每个 generation 的记录数、表和索引页占用、空闲页、数据库/WAL/临时文件实际分配空间，以及扫描峰值。优先使用合成数据或受控只读检查；大型 `dbstat` 本次耗时约 111 秒，不得放入 GUI 常规轮询。
- [x] 为 retired generation 设计明确、有限的恢复窗口与清理触发条件。核实新 generation 激活、检查点提交、报告成功发布及恢复依赖后再清理；保留必要的短期恢复窗口，不能直接删除唯一可用的恢复依据。明确历史报告及待补发报告需要哪些 ledger/样本数据，不要把它们随旧库存一起删除。
- [ ] 设计独立的空间维护流程，在独占 writer lease 下、无扫描写入时执行；比较 `VACUUM` 与增量回收方案的耗时、临时空间及故障恢复。现有 `auto_vacuum = NONE` 不能只设置参数就假定旧文件能增量收缩，须验证转换或重建步骤。不要每天无条件执行整库压缩。
- [ ] 以本次约 5.00 GB freelist 为回收评估基线，不承诺等量物理释放。结合后续扫描复用需求设计阈值和频率，避免每天“压缩后又扩容”；分别记录遍历、seal、提交、generation 清理及报告发布阶段的峰值与完成后占用。
- [x] 处理空间不足、维护中断、进程崩溃和重启，明确维护状态与可取消边界；不绕过现有提交不可取消规则。验证压缩前后数据库、活动基线、检查点和报告一致性，并以实际分配字节确认回收效果。
- [x] 明确界面中“本轮自身增长”和“当前数据占用”的区别。若调整采样时机，必须一起审查 APFS 物理使用量与自身开销的采样边界，保持第 6 节公式；不能只把提交后的自身占用替换进旧边界的报告。

#### 第二轮：减少路径和标识符的重复存储

##### 第二轮实施规划（2026-09-28 规划；2026-09-29 完成首批原型验证）

按“可运行原型与实测 → 选定结构 → 正式迁移与运行路径接入”推进。本次首个交付是可复现的存储原型、正确性测试和百万行对比结果，不直接把未经验证的实验 schema 用于本机数据库。保留第一轮 schema 5 与全部现有性能修复；后续发布迁移从 006 起编号，001–005 不得改写。日常增量失败根因仍后置。

- [x] **2A：建立对照原型。** 对照现有 UUID/原始路径结构、仅 generation/volume 整数代理键、整数键加共享完整原始路径字典三种布局。库存对象、路径、规范归属的字段、唯一性和外键约束保持等价；保留身份查找索引及集合删除顺序。外部 UUID 不变。字典采用稳定整数 ID，原始路径仍为 BLOB；计入 UNIQUE 路径索引本身的空间，不能把逻辑去重误报成物理零重复。
- [x] **2A：验证语义与查询计划。** 覆盖非 UTF-8 路径、相邻目录边界、多页子树、硬链接规范归属、跨 generation 不同对象/分类、删除/替换，以及字典中大量属于其他 generation 的路径。路径范围与 generation 成员查询必须有界，不能只在小而高度重合的两代库存上得出性能结论。用 EXPLAIN QUERY PLAN 加实际耗时验证身份查询、分页和外键清理。
- [x] **2A：量化收益和代价。** 使用相同百万条合成路径，覆盖长重复前缀、两代库存、代际变化、连续替换及删除；分别记录单代/双代紧凑页占用、freelist、每条路径成本、构建/查找/分页/更新/删除/字典回收耗时。记录数据库/WAL/SHM 阶段采样峰值并标明不含全部 SQLite 系统临时文件。原型只衡量热点库存结构，不能冒充完整扫描或真实升级压测。
- [x] **2B：基于证据选择结构。** 先评估整数代理键能否独立交付，再决定共享路径字典是否进入正式 schema。字典不能牺牲现有范围分页与 10 秒增量查找/提交预算；若高度不重合代际使字典驱动分页扫描大量无关路径，应记录失败门槛并设计 generation 局部有序访问，不能直接上线。父节点加名称的递归路径重建先在测试原型中验证，不直接引入生产。
- [ ] **2B：接入完整运行路径。** 将已选结构应用于 staging 写入、run overlay 合并、opaque 保留、seal/规范归属、增量 orphan 清理、原子激活、retired 删除、报告恢复和只读诊断。共享字典的回收必须同时考虑 active/retired/staging/overlay/规范归属和父节点引用，分批完成；历史 ledger/报告继续保留原始语义。
- [ ] **2C：内测新库切换（2026-09-29 用户调整）。** 不实现旧库存转换；新结构使用新的版本标识，明确拒绝把非空旧库当作新库使用。通过可观察的新建基线流程切换，在 writer/stable lease 下处理初始化、空间不足和进程中断恢复。不能把旧 checkpoint 带入空的新库存，首次报告保持 opening balance 语义。已发布 001–005 保持不变，历史报告是否保留须在切换流程中明确。
- [ ] **2C：发布验收。** 运行第 7 节检查、原有百万行完整运行链路与新结构百万行比较；保留原有时间预算，更新 Database/Operations/Testing。独立报告原型结果、正式实现状态和真实安装状态；下一次安装切换须采用相同签名并验证新建基线流程，不把本次原型自动部署到刚压缩完成的本机库。

性能门槛：首先保证语义等价和索引范围查找，其次比较紧凑后的有效页占用，最后衡量新增关联、字典 GC 与迁移成本。不通过的候选必须保留可复现用例及结论；空间收益不能抵消无界分页或不可恢复的迁移。

2B 接入方向（首批三方案的阶段性结论；以随后树形补充实验的更新为准）：先实施整数 generation/volume 代理键，原始路径及现有范围索引继续保留。优先评估新增持久映射表，使外部 UUID、checkpoint、run target 和历史报告的身份保持稳定；常驻库存三表通过整数键关联，避免为压缩库存而重写历史数据。转换应在批次/查询上下文边界完成，不能逐行执行额外 UUID 查找。需要单独验证 UUID 解码/关联成本、映射缺失时拒绝推进 checkpoint、组合外键的卷/代一致性、generation 删除触发器及全部 overlay 分支。原型没有实现这一适配层，因此空间测量不是正式迁移已经可用的证据。共享字典只有在按代排序分页和完整引用回收方案通过门槛后才可接入。


##### 树形节点补充实验（2026-09-29，已完成）

用户要求补齐父节点＋文件名比较。新增纯树形节点和树形＋按代完整路径排序索引两种候选；所有辅助索引均计入空间。节点保存不可变的原始 BLOB 名称及父节点，代成员保存对象身份/分类，重命名建立新节点而不改旧视图。纯树原型采用按代成员向上递归重建路径后排序；混合原型以额外按代索引消除重建分页。测试长路径百万库存、深目录、宽目录、非 UTF-8 名称、硬链接、整目录改名、稀疏代、连续替换及 GC。若纯树分页工作量随代大小增长，记录首分页与 SQLite VM 步数并拒绝该算法，不运行已知二次复杂度的百万行全分页，也不将首分页冒充全分页。所有修改限于合成实验和文档，不安装、不迁移本机库。

补充实验结果：五种布局同一次 Release 百万行比较通过（589.4 秒）。双代紧凑占用：UUID 原始路径 2,480,533,504；整数原始路径 1,508,061,184；共享完整路径 589,516,800；纯父节点＋名称 390,815,744；树形＋按代排序表 847,151,104 字节。纯树最省（较 UUID -84.2%），但当前递归重建分页每次处理整代，首 1,024 条耗时 3.47 秒，拒绝该分页实现；这不排除未来设计其他有界树遍历。混合方案较 UUID -65.8%、较整数方案再省 43.8%，完整百万行分页 0.62 秒、32 次查找/删除 0.0034/0.0103 秒、稀疏代 38 VM 步，通过原型性能门槛。代价是首次构建 29.90 秒（整数 8.06 秒），第二次替换构建＋seal 37.77 秒（整数 13.51 秒）。完整结果见 Docs/Testing.md。

实验中发现混合方案规范归属查询可能从整代排序表驱动，形成重复整代扫描；已用 CROSS JOIN 固定身份候选优先，再按 generation/path_id 查排序表，并新增 EXPLAIN 回归。初次压测因此中止，修复后重新完成全部五种布局，未将中止结果当作验收。所有测试保持合成数据；无生产 schema、安装或本机数据库变更。

验证收尾：常规 230 项测试通过（两个百万级 opt-in 用例在普通运行中跳过）；五布局 Release 百万行对照单独通过。格式 lint、swift build、LaunchAgent lint、git diff --check 均通过。本次仅修改测试原型和文档，原有生产百万行链路代码未改动，未重复运行该独立耗时用例。

2B 候选更新：若继续以空间为首要目标，优先验证“整数键＋不可变父节点/名称＋按代完整路径排序表”的完整运行层适配；整数原始路径保留为构建更快、改造更小的备选。不得将混合原型通过等同于正式上线：仍需覆盖 staging/overlay、opaque、diff、seal、引用回收、报告恢复及正式迁移；按代排序表会增加维护和迁移成本。上面的整数优先方向是首批三方案实验的阶段性结论，由本次补充实验更新。

##### 混合树方案后续验证（2026-09-29，存储适配器实验已完成）

本轮继续验证测试原型，尚不发布 schema 006：补齐排序表与节点的一致性审计（缺行、错误路径、节点循环）、按代原始路径 overlay 分页（删除、身份替换、共享对象元数据）、有界 opaque 拷贝与双游标 diff、候选身份增量提交及异常回滚。采用独立预期记录核对，特别覆盖相邻目录、非 UTF-8、符号边界、硬链接和跨代隔离。新增独立 opt-in 百万行工作负载，测量完整 overlay 分页、窄子树、opaque、diff、增量提交和审计成本；不把测试适配器等同于完整生产运行层/FSEvents/报告恢复或崩溃迁移验证。

本轮结果：新增 HybridTreeExperiment / HybridTreeValidationTests，验证按 run/generation 隔离的双分支有界 overlay、共享对象元数据与路径分类、删除/替换/创建后删除、规范硬链接切换、逐条 oracle 对比、双游标 diff、有界 opaque 拷贝（含空卷根及中断）、候选身份原子提交与异常回滚。逻辑审计证明排序行缺失、排序路径错误、成员可达节点循环可能通过 SQLite 外键检查，生产接入必须额外校验排序表完备性与节点路径等价，并保持节点不可变；不得仅凭 integrity/FK 结果推进新基线。显式审计按 512 条成员批次及本批祖先缓存重建，不放入 GUI 轮询/每次增量提交。

独立 Release 百万行验证通过（115.2 秒）：非路径顺序 inode 构建＋seal 98.06 秒、32 次窄范围 overlay 查询 0.0379 秒、完整 overlay 分页 2.365 秒、双视图 diff 4.710 秒、999 条 opaque 保留 0.0143 秒、64 条修改/删除的候选提交 0.0360 秒、逻辑审计 3.621 秒；10 秒查询/提交和 60 秒分页/diff 门槛通过。紧凑后 374,464,512 字节，DB/WAL/SHM 采样峰值 823,468,032 字节（不含其他 SQLite 临时文件）。新夹具路径和身份分布不同，不与前次大小/构建时间直接相减来推断优化收益。详细口径见 Docs/Testing.md。

本轮验证收尾：4 组新增普通用例通过；swift test --no-parallel 报告 235 项通过（三个百万级 opt-in 用例跳过），新增百万行 Release 工作负载单独通过。格式 lint、swift build、LaunchAgent lint、diff 空白检查通过。两次默认并发全套运行分别在既有 quietSinceNowCursor 和 stopFallbackIsRequestScoped 用例失败；前者单独复查通过，串行全套二者均通过，未修改可信事件或取消保护。默认并发测试的时序稳定性仍需单独处理，不能将串行通过报告为默认并发全套通过。

结论：混合方案通过本轮存储运行模式验证，可继续做正式运行层适配；尚未通过生产 run revision、可信 fence、完整 ledger/报告恢复、进程崩溃及迁移门槛，2B/2C 仍未完成。新增代码全部在测试目录；没有 schema 006、安装更新或真实数据库读写。

##### 2A 实现结果（2026-09-29；测试原型，生产仍为 schema 5）

新增 `StorageLayoutPrototype.swift` 与 `StorageLayoutTests.swift`，三种布局均可实际写入、选择规范硬链接归属、分页、切换 checkpoint、清理旧代并验证外键/回滚。共享字典使用复用的预编译语句和每批清空的路径缓存；GC 按整数主键有界分页，并保护成员、overlay 引用及父节点。百万行测试包含两次完整替换、10% 路径改名、身份替换、非 UTF-8 硬链接、32 次增量删除和独立稀疏代；这是热点库存实验，不是完整运行层或旧库迁移实现。

| 布局 | 单代紧凑字节 | 双代紧凑字节 | 稀疏代首分页 SQLite VM 步数 |
| --- | ---: | ---: | ---: |
| UUID + 原始路径 | 1,240,322,048 | 2,480,533,504 | 32 |
| 整数键 + 原始路径 | 744,034,304 | 1,508,061,184 | 32 |
| 整数键 + 共享路径字典 | 400,027,648 | 589,516,800 | 6,606,108 |

整数键双代占用下降约 39.2%，保留按代路径范围定位；选为 2B 正式接入候选。字典下降约 76.2%，但单代构建约 29.17 秒（整数布局 8.96 秒），稀疏分页仍随无关路径增长，当前候选明确未通过接入门槛。不能以一次机器上的 0.063 秒稀疏查询耗时掩盖不受结果页大小约束的工作量。单项性能也不是全面提升：本次整数布局首次 seal 为 6.14 秒，UUID 布局为 4.28 秒，需在真实适配层接入后重测完整链路。

227 项常规测试通过；新版布局百万行测试 359.7 秒、原有完整链路百万行测试 477.6 秒均通过，10 秒增量查找/提交及既有 opaque/diff 预算保留。格式、构建、LaunchAgent lint、独立开发包签名校验及 helper dry-run 均通过。完整测量与边界见 `Docs/Testing.md`。本次没有新增 006 迁移、没有修改安装或真实数据库；2B 运行层适配与 2C 正式迁移仍未实现，不能把原型空间收益视作本机已经获得的收益。

- [ ] 先比较新旧 schema 的空间与查询计划，再确定迁移设计。优先评估共享路径字典：完整原始路径只存一次，generation 成员关系、索引和规范归属引用整数 `path_id`；使用 `parent_id` 避免反复保存父路径。跨 generation 共享路径，但不得使旧 generation 的视图随新扫描修改。
- [ ] 评估 generation/volume 使用内部整数代理键，外部继续保留稳定 UUID。设计字典垃圾回收，只有所有活动、保留、staging、overlay 及必要报告恢复引用都解除后才删除条目。
- [x] 比较“完整路径字典”和“父节点＋名称”方案对原始非 UTF-8 路径、重命名、硬链接及子树范围查询的影响（含纯树及附加排序索引混合原型；正式接入尚未实现）。保留按原始路径字节分页、相邻目录边界判断和有界内存，避免为节省空间引入整表遍历或无界路径重建。
- [ ] 不可直接删除现有复合索引来缩小文件。`inventory_paths_parent_object_idx` 等索引用于修复外键级联、对象查询和分页的严重性能退化；任何替代方案必须提供查询计划及大规模测试，证明查找仍按身份或路径范围定位。
- [ ] 使用新的编号 migration 并更新 `DailyDiskSchema.expectedMigrations`，不得修改已发布的 001–005 migration。规划旧库升级所需峰值空间、事务边界及失败恢复，保留用户基线和检查点，避免无必要的全盘重扫。

#### 第四阶段：补强未归因磁盘增长诊断

- [ ] 排查快照诊断不完整的具体失败类别和卷覆盖范围，明确区分“未发现变化”与“无法观测”；审查物理、自身开销和库存变化的采样边界，不能直接将残差归给某一路径。
- [ ] 对已删除但仍打开文件提供有限、隐私安全的关联诊断，并区分当前逻辑大小、跨次变化与未知物理占用；不能直接从残差扣除逻辑大小。不可读路径保持 coverage 提示和旧库存保留。
- [ ] 报告明确区分确定的普通文件变化、DailyDisk 开销和未归因部分；候选原因应标明证据及限制。使用合成夹具验证采样边界、部分诊断失败和带符号核算，避免把候选原因当作确定归因。

#### 验收与交接要求

- [ ] 使用百万级合成记录，包含现实长度的路径、重复前缀、多个 generation、硬链接、非 UTF-8 路径及删除/替换；重复执行全量恢复与增量周期。记录优化前后稳定占用、峰值占用、每条记录成本和维护耗时，不预先承诺压缩到 1 GB 以下或固定节省比例。
- [ ] 验证历史报告及待发布报告恢复、opaque 子树保留、硬链接唯一归属、带符号核算和可信 FSEvents fence；generation 激活与检查点更新必须仍为同一原子事务。
- [ ] 覆盖维护/迁移中断、重启、磁盘空间不足、writer lease 竞争；验证失败后仍可使用原基线或按设计恢复。测试不得提交真实库存、用户路径或报告。
- [ ] 比较全量/增量扫描、子树分页、清理与提交耗时，防止全表反复扫描和内存增长；保留现有百万行测试的增量查询与提交性能预算。
- [ ] 实现后运行第 7 节检查及 opt-in 百万行测试，更新 `Docs/Database.md`、`Docs/Operations.md`、`Docs/Testing.md`、相关 README 和本文件。记录实际节省空间及限制；若更新本机安装，保持签名、bundle ID 和安装路径稳定。

接手入口：`Sources/DailyDiskStore/InventoryStore.swift`（`pruneGenerations`、`cleanupStagingState`、`commit`、分页与 opaque 保留）、`Sources/DailyDiskStore/SQLiteDatabase.swift`、`Sources/DailyDiskStore/Migrations/`、`Sources/DailyDiskPlatform/DailyDiskOverheadSampler.swift`、`Sources/DailyDiskCore/FullScanCoordinator.swift`，以及 `ScheduledRunner`/`ReportCoordinator` 的报告发布和恢复流程。

增量诊断另从 `Sources/DailyDiskCore/EventTrust.swift` 的 `assessJournal`、`Sources/DailyDiskCore/Protocols.swift` 的 fence 校验、`Sources/DailyDiskPlatform/DailyDiskRunCoordinator.swift` 的恢复分支及原生 FSEvents session/mailbox 实现追踪。复查证据来自本机 `scan_runs`、`scan_errors`、`inventory_generations`、`overhead_samples`、SQLite 页统计和私有 Reports/Control/Logs；只把去标识的汇总写入文档，不提交原始运行数据。

### 混合原型对抗测试与修复（2026-09-29）

本轮遵照用户最新优先级继续测试空间方案，发现两个可复现的隐藏缺陷，均已在测试原型修复，尚未发布新生产 schema：

- 节点插入失败后，复用的 SQLite statement 未重置；事务回滚后同连接重试报 `SQLITE_MISUSE`。错误路径现在也执行 statement reset，保留原始错误并清空批次缓存。故障触发器回归覆盖失败、回滚、撤除故障、重试及旧基线不变。
- 字典 GC 对每层祖先重新扫存活节点；同样 65 个废弃节点，1,024/8,192 条无关存活路径导致 132/594 批扫描。改为一次叶节点发现加分批父节点候选队列，两种规模均为 65 批。初始发现仍扫描字典一次，不宣称全部 GC 成本恒定；每批重查成员、overlay 和子节点引用，支持中断后重新发现候选。

新增四项普通回归，包含 2,304 次确定性变更、48 轮提交、跨设备身份、硬链接、原始非 UTF-8 路径、根路径、别名元数据同步、回滚重试、跨代隔离及 GC 中断。修复后的 Release 百万行混合工作负载通过（118.34 秒）：构建＋seal 101.202 秒、窄查询 0.0345 秒、完整分页 2.787 秒、diff 4.125 秒、候选提交 0.0220 秒、显式审计 3.851 秒；紧凑占用 374,464,512 字节，DB/WAL/SHM 采样峰值 823,050,240 字节，不含其他 SQLite 临时文件。

默认并发全套报告 239 项通过（三项 opt-in 跳过），混合百万行用例单独通过；格式、构建、LaunchAgent lint、diff 检查通过。详细口径见 `Docs/Testing.md`。本轮未安装、未修改真实数据库。正式接入必须携带以上修复，补齐生产 revision/fence、完整 ledger/报告恢复和崩溃恢复验证；旧库存迁移按用户决定取消，改为显式新建基线。不得把原型通过表述为生产接入完成。

### 混合存储正式接入（2026-09-29）

- [x] 接入 migration 006、紧凑库存读写、opaque 保留、规范归属、清理和显式一致性检查；沿用正式 revision/ledger/report/checkpoint 协议。
- [x] 内测不转换旧库存，已按用户授权删除旧数据；移除旧版专用提示和任务分支，仅保留迁移层一致性校验。
- [x] 使用原签名和安装路径替换应用，按授权删除旧运行数据并启动 schema 6 首次基线。
- [ ] 等待首次报告完成并验证后续增量；启动和进度验证不等同于完整验收。
- [ ] 历史未决项：游标缺失和跨日日志 UUID 变化的深入调查已后置；当前先按每日全量四轮规划推进，继续保留既有可信事件保护。

正式接入验收：默认并发全套报告 244 项通过（3 项 opt-in 跳过），原有生产百万行完整链路另行通过，耗时 242.388 秒。两轮替换、报告和维护后均为 396,828,672 字节；DB/WAL/SHM 采样峰值 1,779,724,288 字节。后续 32 次窄查询/增量提交为 0.0583/0.7536 秒，opaque/diff 为 34.104/10.096 秒，全部通过既定预算。相同生产夹具旧 schema 5 紧凑后为 1,012,027,392 字节，新布局下降约 60.8%；某些单项（增量提交、opaque 拷贝）比历史记录慢，不能宣称所有操作加速。排序缺行/错误路径、失败重试和杀死未提交 SQLite 子进程后恢复均有正式库测试。未替换安装、未重置真实历史；实机落地验收仍待完成。
格式、构建、LaunchAgent lint、diff 检查及独立开发包深度签名校验/helper dry-run 均通过。开发包为显式 ad-hoc，仅用于验证；后续安装须沿用原持久签名与安装路径。

### Installed fresh-baseline rollout (2026-09-29)

The user explicitly authorized deleting old inventory. Removed the dedicated old-format error type, Control category, GUI reset message and manual/scheduled compatibility branches. Retained the generic migration consistency precondition against dropping inventory beneath old checkpoints. A clean concurrent suite passed 243 tests (three opt-in workloads skipped); format, LaunchAgent, diff checks, persistent-signed package verification and helper dry-run passed. Inventory algorithms did not change; the accepted production million-row workload was not repeated.

After confirming the helper was idle, deleted the old runtime database, reports, logs and Control files under stable reset/writer leases, without an inventory backup. Replaced the app at its original install path with the same signing identity; all three executable designated requirements matched. Daily 09:00 registration remains intact. The registered helper started a fresh manual baseline: schema 6, seven hybrid tables, zero inherited checkpoints, one running full scan and increasing initialFull/scanningFiles counters. The new GUI was reopened, but computer-use access was unavailable. Execution was verified through persisted progress and read-only schema inspection. Initial report completion, visual acceptance and subsequent incremental acceptance remain pending; startup is not full end-to-end acceptance.

These installed results supersede the earlier not-installed and compatibility-UI status statements.

### Graphite frontend integration (2026-09-29)

PR #3 supplies the sidebar, theme, trend chart and growth/release bars. Integration keeps its visual design while preserving schema-6 space-maintenance controls, phase-only maintenance progress, cancellation boundaries and maintenance completion feedback. The sole textual conflict was the progress counter block: preserve the maintenance conditional and apply the incoming semibold typography/card styling. No inventory/accounting or database-format change is part of this frontend integration.

The integrated default concurrent suite passed 243 tests in 7.228 seconds (three opt-in workloads skipped). Format, build, LaunchAgent and whitespace checks passed. The million-row storage workload was not repeated because the storage algorithm was unchanged. Visual acceptance remains separate from compilation and automated tests.

Installed Graphite acceptance: rebuilt with the existing persistent signing identity and replaced the original app bundle, then reopened the GUI. All three executable designated requirements matched; deep strict signature verification passed. Lease-protected before/after inspection confirmed schema 6, the existing active checkpoint and the one completed baseline report were unchanged. No inventory reset or new scan was performed for this frontend update. The baseline report is now complete; subsequent incremental and visual UI acceptance remain pending. GitHub PR #3 was merged with its original commit ancestry preserved, and local storage/maintenance improvements were published together with the integration.

### Swift 6.1 CI fixture compatibility (2026-09-29)

CI on macOS 15 / Swift 6.1.2 failed while compiling `SpaceMaintenanceTests.maintenanceCompactsAndPreservesBasis`: the combined throwing map, string concatenation and integer inference exceeded the type-checker's budget. Local Swift 6.3.2 had accepted it. The fixture now builds the same 2,000 records with an explicit array/loop, precomputed prefix and typed link count. No assertion, production code or frontend style changed. Local concurrent tests passed all 243 cases (three opt-in workloads skipped); format, build, LaunchAgent and whitespace checks passed. Keep compatibility with the older supported compiler rather than removing the test or moving CI to macOS 26 to hide the failure.

### Reinstall helper registration recovery

An enabled SMAppService registration does not prove that its launchd job exists. `LaunchAgentManager.startIfNeeded` repairs a confirmed missing job once via unregister/register, preserving Control state and rechecking approval/runtime before attaching or kickstarting. Never apply this repair to a loaded idle/running job or an unknown launchctl error, and never add a polling repair loop. Regression coverage includes queued-request preservation, RunAtLoad attachment, approval, failed repairs, unstable paths and bounded recovery. See Docs/Operations.md.

Validation: the new reinstall recovery regression fails against the unmodified manager and passes with the fix. Format, build, LaunchAgent lint and whitespace checks pass. The default suite reports one real-machine `realStartupVolumeDiscovery` failure (missing System volume at `/`), reproduced with the unmodified upstream manager; the remaining 247 tests pass with that case excluded (three opt-in workloads skipped). This change does not alter APFS discovery. Installed SMAppService recovery still requires manual acceptance; synthetic registration tests do not claim real reinstall acceptance.

Concurrent start requests snapshot a registration revision before awaiting launchctl. If another call changes registration during that await, the missing result is stale: recheck approval/runtime without another unregister. Registration attempts advance the revision before the operation, including failures, so overlapping callers cannot repeatedly repair or terminate a newly started helper. Manual register/unregister also invalidate in-flight observations. Regressions synchronize two missing inspections and cover successful repair, failed registration and a still-missing job.

Review follow-up validation: default concurrent suite passed 250 tests (three opt-in workloads skipped), including the previously failing duplicate-unregister regression. Format, build, LaunchAgent and whitespace checks passed. The earlier APFS discovery failure did not reproduce on this machine; installed missing-registration acceptance remains separate.

PR #4 已于 2026-09-30 合并（merge 578f5ea，修复 2737179）。先修复 actor 重入导致的重复注销，再合入重装后缺失 helper 的恢复逻辑。PR 独立全套 250 项通过；与当前本地探针/快速失败组合及同步后的 main 全套 261 项通过（3 个 opt-in 跳过）。本地待提交源码和新增文件恢复后逐字节校验一致，文档追加冲突保留双方内容。当前未更新本机安装。

### 每日全量设计首轮测量（2026-10-01）

百万条目生产存储压力测试通过（475.784 秒）。新增 Darwin 进程磁盘写入计数：初始 append 1.682 GB，至激活累计 2.911 GB；第二轮 staging/seal/激活/报告 3.769 GB，之后强制清理/验证/VACUUM 另写 2.301 GB。压缩后 DB 396,828,672 字节。计数是进程 I/O，不是 NAND 写放大；夹具不包含真实文件遍历/原生事件回放，不能直接外推本机寿命。设计与完整口径见 `Docs/DailyFullScan.md`。先实施每日 05:00 全量策略及报告语义，第二轮再测试有上限的 WAL checkpoint（当前每次事务后 TRUNCATE）和 512/1024 批次，保留 FULL 持久性及恢复不变量；不将强制压缩改为每日例行步骤。

本轮验证：默认并发全套 261 项通过（3 个 opt-in 跳过），百万条目独立测试通过；格式、构建、LaunchAgent lint 和 diff 检查通过。CI 取消/超时夹具改为 FIFO 阻塞及 ready 握手，移除两秒自然退出与 50 ms 调度假设。仅本地修改，无提交、无云端推送、无本机安装变更；真实例行 helper 的全流程写入采样仍待完成。


### 05:00 每日全量规划文档同步（2026-10-01）

已将正式目标及四轮顺序同步至 README、架构、记账、数据库、安装、运维与测试文档。第一轮为调度/全量边界/报告语义，第二轮为有上限的 WAL checkpoint 与批次测量，第三轮为空间维护，第四轮为实机验收。同日后续手动检查尝试增量，可信历史失败则回退全量。旧版 09:00 及七天全量仅作为当前尚未迁移的实现说明或历史证据保留；七天压缩冷却仍有效。此次仅更新文档，未改代码、plist 或安装。格式、构建、LaunchAgent lint、diff 检查通过；默认全套 261 项通过（3 个 opt-in 跳过），不代表新策略已实现或通过验收。

### Daily-full rollout (schema 7, 2026-10-01)

Source now selects daily full at 05:00 by local calendar and actual full/recovery inventory completion date, qualified by a published report. Subsequent same-day manual checks try incremental; advanced recheck forces direct full. Old report payloads/inventory are preserved. Migration 007 adds snapshot-comparison accounting, post-commit inventory completion time and report publication time; absent JSON snapshot bytes decode as zero, and historical timestamps approximate the existing finish/report dates. Report retry must not change an existing publication timestamp. New completion markers are written only after inventory COMMIT. Missing markers conservatively do not satisfy daily work; later report recovery must not invent a new completion day. Never substitute scan start or a proposed checkpoint for success.

Daily E0 starts from the current journal, without yesterday’s history. E0–E1 updates staging only; opaque preservation may open an empty baseline descriptor but must not build/seal an expected-active event inventory. Direct baseline/staging semantic validation uses snapshot change kinds, with no normal-growth correction alerts. Legacy reconciliation reports retain their old meaning. Before activation revalidate volume/device/topology/journal identity; mid-scan trust loss still aborts safely.

Production writer uses bounded WAL checkpoints (32 MiB soft, 128 MiB inter-transaction guard), disabled SQLite auto-checkpointing and FULL durability. A single atomic transaction can exceed those thresholds; pinned readers stop subsequent writes before BEGIN. Final publication/close checkpoints may defer truncation for busy readers; strict CLI remains conservative. Native checkpoint-on-close must not instantiate a Swift statement referring unowned to a deinitializing database. Scanner batches are 1024; cancellation remains checked inside traversal chunks.

Same-fixture 100k A/B measured about 37.6% fewer process writes across three full replacements/deletions for bounded WAL + 1024 batches. This is not a device-wear estimate. Retirement deletion and final forced VACUUM were measured separately; the 24-hour recovery window and seven-day compaction cooldown remain unchanged. Helper start/end and phase probes sample process write counters for a naturally due full run. See Docs/DailyFullScan.md and Docs/Testing.md for measured evidence, fixture corrections and remaining installed acceptance.

Final source validation: clean concurrent suite 275 tests passed (four opt-in workloads disabled), all three final isolated 100k write variants passed, and formatting/LaunchAgent/whitespace checks passed. Original million-row full/incremental/opaque/maintenance regression passed in 436.34 s; new three-cycle daily-path million-row test passed in 200.56 s before the final completion-marker refinement. Final timing/persistence changes were retested in the full suite and 100k variants. Keep the recorded SIGBUS clean-build limitation and the separately fixed unowned-reference destructor failure in Docs/Testing.md; do not report every intermediate run as passing.

Installed acceptance update (2026-10-01): Computer Use access is now working. Removed the old job through Settings, quit the GUI, and installed GUI/helper/CLI together at the original path with the same persistent signing identity. All three designated requirements match and deep strict verification passes. Re-registered through Settings; both GUI and launchd now show 05:00 (Hour 5, Minute 0). The RunAtLoad helper migrated schema 6 to 7, recognized today's published full report, returned skippedNotDue and exited with status 0; no additional inventory scan was launched. Lease-protected comparison preserved the active checkpoint and all nine historical reports. Notification permission remains allowed; the GUI disk-access probe reports three accessible protected locations and zero denials. Overview and the nine-report history page render correctly with paths hidden by default. Fixed the stale advanced-settings seven-day description to daily 05:00 and rebuilt/reinstalled; format, LaunchAgent and whitespace checks pass. The final post-install source suite passed all 275 tests in 7.086 seconds (four opt-in workloads disabled). Installed strict CLI verification also passed: integrity ok, schema 7, zero foreign-key/inventory/report violations and zero abandoned runs. This supersedes the prior Computer Use blocker and not-installed status. The remaining acceptance item is whole-helper write measurement during one naturally due full scan; do not repeat real scans just for benchmarking.

2026-10-02 写入审查验证：仅新增/更新规划文档；格式、构建、LaunchAgent lint、diff 检查通过，默认并发 275 项通过（4 个 opt-in 未启用）。反向索引表示用内存夹具验证，无新真实扫描、压缩、迁移或安装。详见 `Docs/WriteOptimizationReview.md`。


2026-10-02 主线发布准备：W6 提升为主要低写入架构，详见 Docs/WriteOptimizationReview.md。新增相同对象/排序映射 no-op UPDATE 防护，membership 返回值、opaque 计数、seal 失效和冲突检测不变。默认并发 276 项通过（7.001 秒，4 个 opt-in 未启用）；格式、构建、LaunchAgent lint、diff 检查及两个开发诊断脚本的 5 项测试通过。此前已验收的 schema 7/05:00/探针改动一并提交；不把小改动宣称为 W6 完成，不更新本机安装或触发扫描。
