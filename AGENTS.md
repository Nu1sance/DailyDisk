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

## TODO

### 存储落地前的测试失败排查（2026-09-29）

用户要求先排清两个间歇失败，再落地新结构。详见 `Docs/Testing.md` 的 “Investigation of the two intermittent failures”。`stopFallbackIsRequestScoped` 原先靠 10 ms 等待和 100 ms fallback 推测请求切换顺序；受控延迟实验已复现“旧请求仍可取消时合法发信号，却被测试判错”。测试现用显式异步握手控制切换，生产取消保护未改动。历史日志不足以重建当时确切调度顺序。

`quietSinceNowCursor` 的原始失败为 untrusted fence 和 nil cursor。已定位到没有可用设备游标且没有事件建立游标时的保守拒绝路径，但系统为何当时未返回游标仍未查清；不能宣称只是并发抖动，也不能与每日 journal UUID 变化直接等同。定向测试、六轮并发全套和临时 32 路原生探针均未复现。保留的测试新增 history/flush 原因与 provider 返回值诊断，不增加重试或放宽可信规则。最终默认并发全套 235 项通过（三个 opt-in 跳过），不代表历史偶发问题已解决。

- [x] 消除取消测试依赖毫秒等待的顺序假设，保留跨请求禁止误停断言。
- [ ] 捕获原生 quiet-cursor 失败的完整诊断，查明系统游标不可用原因；不得用串行通过、重试转绿或全局事件 ID 代替证据。
- [ ] 持续记录原生游标问题，不将目前未复现视作修复。按用户最新优先级（2026-09-29），该调查后置，先继续验证混合结构的空间收益和正确性；保留全部可信事件保护。

### 后续修复：游标缺失与跨日全量恢复的关联诊断

- [ ] 分别记录同一设备在卷发现、打开事件流、读取游标、flush 和检查点提交阶段的设备身份、日志 UUID、游标及失败类别。UUID 表示事件日志身份，游标表示日志位置；测试中的“无法取得位置”和每日扫描中的“日志身份变化”是不同的直接触发条件。
- [ ] 对照系统重启、挂载变化及日志重建，验证是否存在共同原因。日志重建或设备匹配错误可能同时影响 UUID 和游标，但目前没有证据确认；不得把两者直接合并为同一 bug。9/27 的硬链接歧义与缓冲溢出仍单独排查。
- [ ] 保留有限、无路径的诊断历史，取得证据后修复实际原因；不以全局游标、忽略 UUID 变化或丢弃事件来避免全量恢复。

当前交付顺序：混合方案补充测试 → 通过正确性和性能门槛后正式接入 → 后续增量可靠性调查。用户已说明仍处内测，不需要旧库存到新结构的数据迁移；采用明确的新建基线流程，不能静默把旧库解释为新格式或沿用旧 checkpoint。此决定不免除新结构的事务、崩溃恢复和逻辑一致性验证。

### 降低数据库空间占用并恢复可靠的日常增量扫描（第一轮已验收；第二轮 2A 已完成）

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
- [ ] 游标缺失、跨日日志 UUID 变化的关联诊断仍后置，继续保留既有可信事件保护。

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
