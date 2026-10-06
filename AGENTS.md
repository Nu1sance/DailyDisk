# AGENTS.md

This file applies to the entire `DailyDisk` repository. It is written primarily for coding agents, but it is also a concise operational guide for users asking an agent to build, install, inspect, or troubleshoot DailyDisk.

## 1. Product summary

DailyDisk is a GUI-first, open-source macOS 15+ disk-growth monitor. Users start and observe scans, cancel safely, browse reports, inspect health, manage the helper, and reset data in the app. A user-domain LaunchAgent starts the same windowless helper for manual requests and once-per-day work; the helper scans, writes a report, optionally sends a scheduled notification, and exits.

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
- Distribution model: MIT-licensed source and signed GitHub Release archives; the stable 0.2.3 build 18 archive is notarized and stapled for Apple Silicon. Installed source builds require a stable Apple signing identity.

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

Source runs at 05:00 local time and at login for due/catch-up evaluation. Upgrade the installed GUI/helper and registered job together and verify the registered schedule. `KeepAlive` is false, so persistent failures do not create a retry storm.

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
3. Traverse all file metadata. With a daily baseline, compare against current inventory and stage differences; initial/legacy full scans build a staging generation.
4. Open a second historical session from `E0`.
5. Replay scan-time events into the same target overlay.
6. Flush a final trusted cursor `E1` and revalidate topology and journal identity.
7. Seal and atomically commit inventory changes, accounting and `E1`; daily inventory reuse retains the active generation ID and changed old values.

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

For another user's checkout, follow `Docs/Installation.md`. A stock Mac may require `xcode-select --install`; check Swift 6+ and a matching macOS 15+ SDK. SwiftPM downloads the dependencies pinned in `Package.resolved`. No Homebrew/Python/Node/database-server dependency is required. Full Xcode is optional for a compatible Command Line Tools build. Persistent signing identities are per-user and are not supplied by the repo; do not imply that permissions or the author's certificate transfer via GitHub.

Current packaging builds the host architecture. Intel/fresh-Mac installation and history-page visual acceptance require separate acceptance. CI configuration is not evidence of all-machine compatibility. Sparkle 2 is embedded for explicitly configured, user-initiated updates. Public feed/key, signed end-to-end acceptance, notarization, release publication and Homebrew distribution are separate release gates; current packaging is not a universal build.

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
open "/Applications/DailyDisk.app"
```

This installs to:

```text
/Applications/DailyDisk.app
```

Then:

1. Open **设置 → 磁盘权限**.
2. Open System Settings → Privacy & Security → Full Disk Access.
3. Add the actual installed bundle, normally `/Applications/DailyDisk.app`.
4. Quit and reopen DailyDisk after granting access.
5. Open **设置** and request notification permission.
6. Select **安装每日任务**.
7. If status is “等待系统批准”, enable DailyDisk in Login Items & Extensions.

An ad-hoc build is appropriate for a one-time trial only. Rebuilding may require granting permissions again.

## 9. Recommended persistent installation

The script uses an existing valid Code Signing certificate/private key; it does not create one. Persistent builds require an Apple-issued identity with a Team ID to load the embedded Sparkle framework; local self-signed identities are not supported by this packaging path. See `Docs/Installation.md` for setup and `CODE_SIGN_TIMESTAMP=none` for a local identity. Never distribute a contributor's private signing key.

List available signing identities:

```bash
security find-identity -v -p codesigning
```

Build and install with the same identity on every update:

```bash
CODE_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" \
  Scripts/build-app.sh --install

open "/Applications/DailyDisk.app"
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
CLI="/Applications/DailyDisk.app/Contents/Helpers/dailydiskctl"
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
4. Remove the installed app (normally `/Applications/DailyDisk.app`; older/user installs may be in `~/Applications`).
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

### Generation cleanup

A composite path/object lookup index and a generation-delete trigger remove canonical rows and paths in sets before removing objects. SQLite can otherwise prefer a generation-only lookup even when a more selective index exists; deleting a large failed/staging generation then repeatedly scans its entire path set. The trigger keeps foreign keys and transaction rollback intact, including protection of the active checkpoint. Regression coverage tests migration and cancels a 10,000-record staging generation while preserving the active baseline.

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

The overview trend supports pointer inspection by scan column: highlight the selected bar in adaptive soft lemon yellow (resting positive bars blue, negative bars gray) and show a compact report time and signed physical delta in a compact pointer-adjacent overlay with edge avoidance and no reserved layout space. Respect Reduce Motion and retain per-bar accessibility values. History path disclosure uses a text-and-icon status button: eye.slash means currently hidden, eye means currently visible; disclosure confirmation and session-only scope remain required.

Overview and report details list up to five direct growth entries and five direct release entries. Direct net path deltas and synthetic ancestor rollups have separate top-ten rankings: ancestors must never consume direct-path slots. Direct paths include directory metadata and may legitimately overlap. Rows are scaled only to the largest displayed entry; neither the top five nor the top ten is the complete change list. Report details show net growth/release path counts, separate overlapping directory-descendant summaries, and an on-demand, 100-record seek-paginated ledger view with growth/release/logical-only filters. Pages contain ordinary non-baseline records, may include repeated paths, and are not an I/O audit log. Reset paging state across report changes and keep every path hidden until session disclosure, including move endpoints and accessibility text.

New report JSON has optional `pathRanking`; absent means legacy mixed ranking. The GUI rebuilds legacy rankings from the published ledger on first access and caches at most 32 reports in memory. It does not rewrite historical report files or accounting, rescan the disk, or migrate the database. GUI JSON exports include the corrected bounded summary, not the entire ledger. Paginated reads seek through `(run_id, sequence)` with short-lived WAL-aware connections; no persistent detail table or offset scan. Preserve directory-growth notification thresholds using the separate rollups.

Unattributed APFS space never becomes a source row. The space composition card shows `physical delta = net file delta + unattributed delta + DailyDisk overhead`; its proportional bar appears only when all non-zero parts share one sign. Fixed system-directory descriptions appear only after session path disclosure.

Darwin `dev_t` is a signed 32-bit bit pattern. Persist device identities by zero-extending `UInt32(bitPattern: st_dev)` and reconstruct native FSEvents device IDs using the same bit pattern. Direct `UInt64(st_dev)` conversion can trap on mounted volumes with negative device IDs, including hosted macOS runners. Positive stored identities are unchanged; regression coverage includes both signed boundaries and rejects values wider than 32 bits.

### Bounded overlay paging and opaque preservation

Full reconciliation pages the base inventory and run overlay independently by raw path bytes before merging at most two bounded candidate pages. Keep subtree bounds, tombstone exclusion, and object-overlay resolution inside the appropriate branch; an outer LIMIT over an unbounded UNION can repeatedly scan/sort the entire remaining inventory. Both opaque preservation and full inventory diff depend on this pager. Mutation paths drive object lookups with CROSS JOIN.

Opaque roots are deduplicated and reduced to disjoint subtrees before reading. Only those path ranges are copied, in transactions of at most 1,024 records. Each transaction invalidates the destination seal before publishing progress; cancellation between batches leaves the active baseline/checkpoint unchanged. Do not skip unreadable history or advance an untrusted FSEvents cursor to avoid a recovery scan.

The cancellable `preservingOpaqueInventory` phase separates history preservation from file traversal. `preservedPaths` and `processedOpaqueRoots` are cumulative, path-free progress counters; missing fields from old progress files decode as zero. Update GUI and helper together and restart the GUI on upgrade because old binaries do not understand the new phase/fields. Temporary identity counters finalize their statements and close SQLite before deleting their private files.

### Space maintenance

Retirement timestamps and a maintenance record track cleanup eligibility. Retirements are stamped at activation; idle cleanup waits for replacement report publication and absence of running/staging/overlay or pending-report recovery work. Keep the latest retired generation for 24 hours; older ones may be pruned after replacement publication. Preserve active/checkpoint references, historical reports, ledger and samples. Cleanup runs before new work and after report publication, outside activation; expiry does not wake a resident process.

The `reclaimSpace` Control action runs only in DailyDiskAgent. Automatic evaluation uses >1 GB freelist, >25% free pages, and seven days since the last attempt. Manual requests bypass thresholds only. Native VACUUM preflights two database sizes plus 1 GB reserve, uses the existing writer/stable leases, and never swaps database files. Persist a maintenance marker, bracket compaction with integrity/FK/basis checks, and verify interrupted maintenance before further work. A resumed manual request requires explicit retry after verification. Do not alter past overhead/physical sample boundaries.

Cleanup, compression and verification use non-cancellable Control boundaries and truthful phase-only UI; automatic maintenance returns to cancellable scan preparation afterward. `maintenanceCompleted` has zero completed domains and no report IDs. Upgrade GUI/helper together and restart the GUI for the new action, phases and categories. Settings reads allocation/freelist explicitly; normal GUI polling must not run dbstat, table counts or integrity scans.

### Compact inventory

Production inventory now uses integer generation/volume keys, immutable parent/name nodes and a generation-local full raw-path ordering table. The three legacy inventory names are read-only compatibility views; write compact tables directly with batch-scoped prepared statements. Preserve statement reset on error and discard cached IDs across rollback. Full sealing audits ordering completeness/equivalence; incremental sealing audits candidate identities only. Explicit verification and maintenance audit retained inventory. Idle node collection uses a bounded leaf queue, not repeated full-tree sweeps. See Docs/Database.md.

Incremental attribution must join `hybrid_generations` and `hybrid_objects` directly using the integer generation key plus `(device_id, inode)`. A LEFT JOIN against the `inventory_objects` compatibility view can materialize the complete generation for every surviving candidate. Preserve outer-join behavior for newly created objects. Both per-identity and streamed overlay attribution use this rule. Path-mutation accounting likewise joins compact ordering/path/volume tables by the candidate path, avoiding a generation-wide materialization of `inventory_paths`. The million-row workload must include surviving modifications, new objects, renames and hard links; deletion-only increments bypass the expensive branch and cannot validate its performance.

### Daily full persistence

Changed old values are retained in recovery tables without copying the complete inventory. Subsequent daily full scans compare 1,024-record batches with 256-path prefetches against the current baseline plus run overlay; unchanged objects/paths/order/canonical are reused. Metadata-only changes stage/apply object values without path mutations or live canonical rewrites. Preserve hard-link observation order across batches. Exact sparse seen bits mark existing node IDs, never every row's last_seen; payload is capped at 64 MiB plus map overhead. Incomplete/failed comparisons cannot seal and must restart.

Deletion detection pages by generation/path ID and excludes opaque raw-byte subtrees. `comparingInventory` is a new cancellable Control phase, requiring GUI/helper upgrades together. E0–E1 compensation updates the same difference overlay. Full ordering auditing reads the base; canonical/ledger work is identity-bounded. Preserve the explicit mutation object index/range in canonicalOverlayPath: high-churn testing found target-prefix scans became quadratic.

Commit atomically stores changed old values, applies candidate mutations/canonical rows, writes signed ledger/samples and advances the checkpoint while retaining the generation ID. All in-place incremental commits also preserve old values so retained history stays reconstructable. Retention removes only expired published version prefixes and pins referenced generations; version order must remain safe across clock reversal. Do not delete historical reports, reset inventory, weaken durability or retain long-lived WAL readers as a write optimization. See Docs/Database.md and Docs/Testing.md for design and regression gates.

## Repository hygiene

Keep current architecture, operational instructions and reproducible synthetic tests in Git. Keep machine-specific measurements, investigation timelines, installation transcripts and optimization working plans under ignored `.local-notes/`. That directory is optional local context, never a required build/test dependency. Do not publish private runtime data. Keep reusable production probes and regression fixtures even when their names include “probe” or “prototype”.

## Remaining validation

- Observe natural cross-day history expiry and cleanup; synthetic timing is not a device-wear guarantee.
- Preserve high-churn, opaque-subtree, hard-link, interruption and disk-full recovery coverage when optimizing writes.
- Keep fresh-Mac/Intel and signed permission/notification acceptance separate from automated test results.

Inventory deletion detection uses an in-memory opaque path index: exact raw-byte roots plus merged descendant intervals, queried by binary search. Preserve slash boundaries and non-UTF-8 bytes; a neighboring name may sort between a root and its descendants, so a predecessor search over root names alone is incorrect. This index changes no persistence or opaque-preservation semantics.

For configured release builds, use Check for Updates; scan blocking and prior task preference restoration are automatic. For manual/source replacement, finish scans, select Settings → General → Advanced → 暂停运行以手动替换应用, quit the GUI and close CLI inspections. Rebuild with the original signing identity, then reopen and select 恢复运行. The installer validates signatures, refuses active/registered workers and restores the previous app on replacement failure. See Docs/Installation.md for interruption recovery and database rollback limits.

### Version metadata and update preparation

Product.json in DailyDiskCore/Resources is the shared version, source build number and minimum OS source. Packaging replaces Info.plist placeholders; embedded CLI build-number reads the enclosing app's build number. RELEASE_BUILD=1 requires explicit BUILD_NUMBER greater than explicit PREVIOUS_BUILD_NUMBER (0 for first release); this local validation does not yet verify remote release history or perform notarization.

Software Update offers Check for Updates and shows recovery/Resume when paused. Manual preparation (暂停运行以手动替换应用) lives under General → Advanced; it is not a necessary step for Sparkle updates. Preparation refuses active helpers/writers or queued/active requests, durably saves the original enabled state, blocks new requests and unregisters the task. Helpers hold a shared update-work lease for their entire invocation; marker publication requires exclusive admission under the Control lock. Update state is fixed-schema, private and atomic. Never expire it on a timer. Restart presents explicit recovery; only restore a task that was previously enabled, and surface required system approval. Restoration and preparation share the source installer's private Control/.installation.lock flock; the source installer also holds the helper's .update-work.lock exclusively. Never unlink these files while held. A legacy application-directory lock still requires inspection, not automatic removal. Upgrade GUI/helper together; older binaries do not enforce this gate.


### Sparkle integration

Explicit ad-hoc development bundles use development-only disable-library-validation entitlements; persistent/distribution bundles keep validation enabled and require an Apple signing identity with a Team ID. Only the foreground app links pinned Sparkle 2.10.0. Packaging embeds the framework, preserves symlinks and signs its nested code inside out. No helper/CLI dependency, automatic checks/downloads or system profiling. Builds leave updates disabled unless DAILYDISK_UPDATES_ENABLED=1 supplies an HTTPS SPARKLE_FEED_URL and 32-byte base64 SPARKLE_PUBLIC_ED_KEY. Never embed private keys. Only application archives are accepted, with pre-extraction signature verification enabled.

The standard user driver gates the Install response before download/extraction: pause scans, unregister the daily task, persist source/target builds, then let Sparkle proceed. Download cancellation before extraction restores the previous task setting. Once extraction starts, or after resuming a persisted installation, retain the gate across errors and exit because the external installer can survive the GUI. Only the expected target build may restore scheduling; old-build manual restoration is disabled. Failed post-extraction installs require retrying the pending update or expert recovery after proving the installer is gone; never infer safety from sessionInProgress, an elapsed timer, or app restart. Source installation rejects a pending Sparkle marker. Keep signed two-version update, permission continuity and install-on-quit acceptance as explicit release gates.


### Installed identity acceptance

Keep rollback/test copies archived rather than leaving multiple runnable bundles with the production identifier registered in Launch Services. Preserve the canonical install path and designated requirements, not merely Team ID. A separate development build also requires separate task identity and runtime data. When investigating permission loss, distinguish a disabled macOS FDA switch from a heuristic probe failure; validate access across actual app restarts. Use per-app permission recovery only with the user's explicit regrant. Verify helper launch and progress after registration; enabled status alone does not prove a usable job. Never globally reset TCC/BTM or weaken signing enforcement to recover one application.

### Update presentation and installation locations

Before starting a manual Sparkle check, dismiss the settings sheet and continue only after SwiftUI's onDismiss callback and AppKit detachment of the captured sheets (observe didEndSheet; no fixed delay). If the check reports no update, restore settings only if it was open before checking, and only after Sparkle's acknowledgement/cycle completion. Menu checks from a closed settings window must not open one. Both initial/resumed Install and the final Install and Relaunch response pass through settings dismissal; prevent reopening settings once final installation is proceeding. Do not force-terminate the GUI or use a fixed delay as proof of sheet dismissal. Test callbacks for exactly-once behavior and settings reopened during download. Signed build 13 → 14 acceptance covered both standard installation locations under the same administrator account, including automatic relaunch, prior task restoration, permission continuity and history retention; this does not prove fresh-Mac or standard-user authorization behavior.

Source installation defaults to /Applications. --debug selects Debug compilation and ~/Applications; --user selects ~/Applications without changing compilation. Explicit INSTALL_DIR is supported but must not conflict with --debug/--user. Sparkle updates the running bundle in place. Preparation/restoration use private Control locks rather than requiring write access beside the app. Sparkle handles authorization for protected application replacement; source installation fails with actionable guidance if the destination is not writable and rejects sudo. Duplicate production apps in the two standard directories are rejected. Runtime data/tasks remain per-user. Update preparation and final install check other user launchd domains conservatively; shared-app updates with other logged-in users are unsupported, and users must not start another login session during installation. Permission authorization/cancellation on a standard-user Mac remains a separate real-machine acceptance gate.


### Public distribution and update maintenance

The canonical source and release repository is `Nu1sance/DailyDisk` (MIT). GitHub Pages serves `https://nu1sance.github.io/DailyDisk/appcast.xml` and `https://nu1sance.github.io/DailyDisk/testing/appcast.xml` from the isolated `gh-pages` branch. Enclosures download from this repository's Releases. Keep existing feed URLs and the Ed25519 key stable so installed clients continue to update. Stable 0.2.1 build 16 is notarized and stapled. Both feed URLs currently publish the same stable-only inventory: released builds through 16 embed the original testing URL, so retain that URL as a compatibility feed and update both atomically in one gh-pages commit. Do not publish experimental releases to this legacy testing feed. Future stable packaging should embed the canonical /appcast.xml URL; a future opt-in preview channel requires a distinct URL. Do not equate a public repository, Developer ID signature, or Sparkle signature with Apple notarization. Homebrew Cask is available from Nu1sance/homebrew-tap starting at 0.2.2 build 17; universal/Intel releases are not yet provided.

When relocating release assets, preserve archive bytes, verify SHA-256 and Sparkle signatures, and test unauthenticated downloads before removing the old hosting repository. Never overwrite an existing build with different bytes. Source commits may be newer than the latest packaged release; document this distinction. Release archives carry public signing information; private signing keys remain outside Git. Local acceptance records, databases, rollback archives and investigation plans belong only in ignored `.local-notes`.

Update coordination explicitly releases the installation lease in each operation's defer block. Do not rely solely on ARC/deinit: async frames may retain the wrapper past the operation and cause the next operation to report installationInProgress. Release is idempotent and regression-tested while retaining the wrapper. The source installer's launchd-domain parser coerces UID strings to numbers before comparing against the human-user threshold; system service users must not be mistaken for concurrent human logins.

Runtime data stays under each user's Application Support directory in either installation location; changing the app location within one account does not require a database migration. Keep backup/rollback work separate from normal updates, and never delete a user's backup merely because installation succeeded. Notarization and local Gatekeeper/stapler validation passed for build 16. Standard-user authorization/cancellation and clean-machine installation acceptance remain separate distribution gates.


Stable release 0.2.1 uses the existing v0.2.1 source tag with packaging BUILD_NUMBER=16 (source commit fb6add0). Keep the previously published build 15 archive immutable; release notes must clearly identify build 16 as the notarized download. Upload and verify final stapled ZIP/DMG bytes before publishing their appcast. Use the ZIP enclosure for Sparkle, retain the established Ed25519 public key, and verify unauthenticated downloads against SHA-256 and the feed signature. Promote the GitHub Release out of prerelease and mark it latest. Never patch the embedded feed URL or any signed bundle contents after notarization; doing so requires a new signed build and notarization.

### Homebrew installation coordination

Native-command integration uses an installer-only Cask generated by Scripts/Homebrew/render-cask.py. Nu1sance/homebrew-tap publishes notarized 0.2.3 build 18; implementation source is included in main. Preserve standard brew commands. No app artifact may mutate the app outside ExternalAppTransaction. Omit auto_updates; receipt-based downloads can be redundant after Sparkle updates, but signed actual-build checks must prevent downgrade. Never write Homebrew receipts manually.

Hold installation and exclusive work leases across all synchronous in-process mutation and recovery. Never delegate copying/removal to children. Durable v2 externalInstalling/externalRecoveryRequired blocks scans, ordinary Resume, Sparkle and source installation. Only validated filesystem recovery under both leases may resolve it; postflight, elapsed time and GUI restart cannot. Restore a signed previous app if replacement did not finish, or retain the verified target and finish cleanup. Preserve original task preference and explicit Resume after replacement; initial installation has no task to restore. Unknown signatures and missing upgrade copies stay blocked.

Homebrew uninstall callbacks during upgrade/reinstall are no-ops; only explicit removal deletes the app. Classify same-user native process ancestry with known standard brew.rb paths/commands, not environment or skip flags. Headless Caskroom modes must not instantiate NSApplication or register a staged GUI. Keep both supported app destinations, duplicate/user-session guards, no sudo runtime, and history-preserving uninstall.

Retain synthetic admission/Resume races, real native Brew lifecycle tests and SIGKILL transaction recovery tests. See Docs/Homebrew.md. Local probes are not notarized releases: do not put them into quarantined downloads or ask users to override Gatekeeper. Separate lifecycle tests from signed/publication acceptance. Never adopt a production receipt, app or database in synthetic tests.

Stable 0.2.3 build 18 is signed, notarized and stapled, with the canonical stable feed embedded. Stable and compatibility feeds publish build 18 while retaining builds 17 and 16. This release separates direct-path rankings from ancestor summaries and adds read-only ledger paging and legacy GUI ranking reconstruction; database schema and accounting remain unchanged. The Tap downloads the same immutable ZIP as Sparkle. Public archive SHA-256, Developer ID integrity, stapled ticket and Gatekeeper assessment are separate from automated tests. No production installation or database is replaced by release validation.
