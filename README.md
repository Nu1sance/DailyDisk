# DailyDisk

DailyDisk is a GUI-first, source-built macOS disk-growth monitor. Click **立即检查** to start a background scan, follow phase/count progress, close and reopen the window without stopping work, browse history and diagnostics, or keep the automatic daily run. DailyDisk compares the current internal APFS inventory with its previous state, attributes file growth, records signed reconciliation corrections, and keeps physical APFS differences separate when they cannot safely be assigned to a path.

## Current storage design

Full scans read all file metadata and persist only differences from the previous inventory. Unchanged records are reused; changed old values are retained briefly for recovery. Initial scans build the complete opening inventory.

Updates preserve supported existing inventories, checkpoints and reports. Update GUI, helper and CLI together; do not reset history as a routine update step.

## What it monitors

- The internal APFS container and its System/Data/VM/Preboot/Recovery/Update roles
- `/System/Volumes/Data` as the single full startup inventory root
- Historical file changes from the persistent FSEvents journal
- New, removed, moved, hard-linked, and resized files
- Authoritative full inventories, with a daily 05:00 default
- APFS snapshot membership and container capacity
- Deleted files still held open by processes
- DailyDisk's own database/report/log overhead

The sealed System volume and other non-inventory roles remain visible as volume-level metrics. External, removable, network, and disk-image storage is excluded by default.

## Requirements and installation

- macOS 15+ with an internal APFS startup disk.
- Apple Command Line Tools (or full Xcode) supplying Swift 6+ and a matching macOS 15+ SDK. These developer tools are **not assumed to be installed on a stock Mac**.
- Initial Internet access for SwiftPM dependencies (`swift-testing` and transitive `swift-syntax`, pinned in `Package.resolved`).
- A stable local signing identity for persistent installed use, plus manually granted Full Disk Access.

No Homebrew, Python, Node.js, Docker, or separate SQLite server is needed. System libraries/frameworks and utilities supply the runtime dependencies. DailyDisk does not use a root helper, `sudo`, a LaunchDaemon, cloud storage, or telemetry.

For a new Mac, first install Apple's tools:

```bash
xcode-select --install
```

After the installer finishes, check `swift --version` and `xcrun --sdk macosx --show-sdk-version`. From the cloned repository, a **one-time development trial** is:

```bash
ALLOW_ADHOC_SIGNING=1 Scripts/build-app.sh --install
open "/Applications/DailyDisk.app"
```

The script builds all three executables, packages resources, signs, verifies, and installs the app. Ad-hoc signing is an explicit trial exception: rebuilding may invalidate privacy grants. For persistent installation, first obtain a valid local Code Signing identity with its private key, then use the same identity on every update:

```bash
security find-identity -v -p codesigning
CODE_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" \
  Scripts/build-app.sh --install
open "/Applications/DailyDisk.app"
```

The identity above is a placeholder, not a certificate supplied by this repository. See **[the complete GitHub source installation guide](Docs/Installation.md)** for cloning, toolchain checks, local self-signed identities, signing options, permissions, updates, and troubleshooting. Full Xcode is optional with compatible Command Line Tools. A paid developer membership is not needed merely to compile or run the ad-hoc trial.

This is a source distribution with host-architecture builds, not a notarized download-and-open installer. Intel and fresh-Mac installation are not yet fully validated. There is no automatic updater or universal-binary release pipeline.

## First-time setup

1. Open the installed app. **概览** shows one primary action appropriate to the current setup state.
2. If shown, click **允许读取磁盘** and enable the installed DailyDisk bundle in **Privacy & Security → Full Disk Access** (normally `/Applications/DailyDisk.app`). Quit and reopen the app after granting access.
3. Click **启用每日检查**. This enables the background helper and starts a check. If macOS requires approval, the primary action becomes **允许后台检查** and opens Login Items & Extensions.
4. Once enabled, use **开始首次检查** or **立即检查**. Manual and scheduled runs both show their phase, real counters, elapsed time and the age of the last progress update. No estimated percentage is invented.
5. You can close the window and reopen it to reconnect, or **取消检查** before saving begins. A stopped helper produces an actionable interruption message instead of an endless spinner; recovery is requested explicitly with **重试检查**.
6. Notifications are optional under **设置 → 通用**. Permission instructions and diagnostics live in the settings sheet; full rechecks and reset are advanced settings.

The overview presents the latest disk delta and more specific growth sources from the stored ranking. **历史** contains report details; accounting and diagnostics are collapsed by default. Paths remain hidden until explicit session disclosure.

## Daily full scans

The source implements **one automatic full scan per local day at 05:00**. If a successful full scan already completed that day, automatic work is skipped. A manual **立即检查** performs full scanning when today's full scan is missing; subsequent manual requests try incremental scanning and fall back to full if trusted event history is unavailable. An in-progress scan is reused. Failed/cancelled work does not count as successful completion. Explicit full rechecks remain available.

The [daily-full design](Docs/DailyFullScan.md) separates source tests from installed acceptance. Update the GUI, helper and registered LaunchAgent together; an older installed copy retains its previous schedule. No history reset is needed. Daily success uses the full inventory’s actual post-commit completion date and requires a published report. Delayed publication cannot turn yesterday’s inventory into today’s full check.

The first full scan remains an opening balance. The daily full path compares successive inventories and uses FSEvents only to catch changes during traversal; it must not depend on yesterday's journal surviving. The helper exits after work. A powered-off/logged-out Mac cannot execute its user task; catch-up depends on an eligible login/wake invocation, not a guaranteed wake-up feature.

## Performance and storage

Scan duration depends on file count, change volume, permissions, storage speed and concurrent activity. Full scanning reads metadata; daily inventory reuse reduces inventory writes by persisting changes. Runtime data for a multi-million-file inventory can occupy several GB, with free pages reused between scans. Database size is not cumulative writes or SSD wear. See [the design](Docs/DailyFullScan.md) and [reproducible tests](Docs/Testing.md).

## Reports

Use **历史** to select reports by date/run/domain and inspect accounting, coverage, physical diagnosis, rankings, and errors. Paths are hidden by default. Showing them is a session-only explicit disclosure; exporting complete JSON requires a second confirmation because it contains reversible paths.

Reports are stored as atomic JSON/Markdown pairs under:

```text
~/Library/Application Support/DailyDisk/Reports/<run-uuid>/
```

The accounting fields are intentionally separate:

```text
eventAttributedDelta
reconciliationCorrection
reconciledIndexedDelta
dailyDiskOverheadDelta
physicalUsedDelta
physicalUnattributedDelta
```

A positive correction means the full scan found allocated bytes missed by event maintenance. A negative correction means the incremental index retained bytes no longer present. Physical unattributed space is never forced into a fabricated directory.

## CLI (automation and expert diagnostics)

Normal scanning, history, reports, health checks, helper controls, data access, and safe reset are available in the app. `dailydiskctl` remains for automation, strict read-only inspection, machine exit codes, and expert troubleshooting:

```bash
.build/debug/dailydiskctl status
.build/debug/dailydiskctl history --limit 14
.build/debug/dailydiskctl report
.build/debug/dailydiskctl verify
.build/debug/dailydiskctl diagnostics
```

The installed copy is at:

```bash
"/Applications/DailyDisk.app/Contents/Helpers/dailydiskctl" status
```

Paths are omitted by default. Printing reversible JSON or path rankings requires explicit consent:

```bash
dailydiskctl report --include-paths
dailydiskctl report --include-paths --json
dailydiskctl report --run <uuid> --domain <container-uuid>
```

Strict CLI inspection holds a shared process lease, refuses any nonempty WAL file, and does not modify the database or create sidecars.

## Data and privacy

DailyDisk stores locally:

```text
~/Library/Application Support/DailyDisk/DailyDisk.sqlite
~/Library/Application Support/DailyDisk/Reports/
~/Library/Application Support/DailyDisk/Logs/
~/Library/Application Support/DailyDisk/AlertState.json
~/Library/Application Support/DailyDisk/Control/   # private request/progress/cancel state
```

Operational logs use typed public values and hash sensitive strings. Notifications contain aggregate byte counts, never full paths. Detailed paths are stored in the private SQLite inventory and private JSON/Markdown reports. The GUI hides paths until session disclosure and confirms full JSON export; CLI display/export requires explicit `--include-paths` consent. Control/progress JSON contains phases, IDs, times, and counters only—never paths or arbitrary commands.

## Uninstall

1. Open DailyDisk → **设置** → **移除每日任务**.
2. Quit DailyDisk.
3. To remove local history safely before deleting the app, use **设置 → 重置历史与基线**. It unregisters the helper, verifies writer quiescence, and deletes only DailyDisk's fixed private data root while preserving the control handshake.
4. Remove the installed app (normally `/Applications/DailyDisk.app`; older/user installs may be in `~/Applications`).
5. Remove DailyDisk from Full Disk Access and Notifications in System Settings if entries remain.

## Important limitations

- Full Disk Access does not bypass POSIX permissions, ACLs, SIP, or the Signed System Volume. Opaque unreadable subtrees are reported and preserved from the previous inventory rather than treated as deletions.
- FSEvents is a coalescing change journal, not an audit log. Dropped/wrapped journals trigger authoritative recovery.
- Files created and deleted entirely between runs cannot be reconstructed unless they still consume space through an open file descriptor or snapshot.
- APFS clones, shared extents, snapshots, metadata, and purgeable space prevent exact per-file physical allocation. DailyDisk reports the residual explicitly.
- Deleted-open-file size is logical evidence and may not equal unique APFS blocks.
- The initial full scan is an opening balance, not a synthetic day of positive growth.
- Snapshot size fields are optional and are never blindly summed.

## Development

```bash
swift format lint --recursive Sources App Tests
swift build
swift test
Scripts/lint-launch-agent.sh
ALLOW_ADHOC_SIGNING=1 Scripts/build-app.sh
DAILYDISK_DRY_RUN=1 build/DailyDisk.app/Contents/Helpers/DailyDiskAgent
```

The opt-in million-row test is available locally and through the manual GitHub stress workflow:

```bash
DAILYDISK_RUN_STRESS=1 swift test --filter millionRecordInventory
```

See:

- [`Docs/Installation.md`](Docs/Installation.md)
- [`Docs/Architecture.md`](Docs/Architecture.md)
- [`Docs/Accounting.md`](Docs/Accounting.md)
- [`Docs/Database.md`](Docs/Database.md)
- [`Docs/Operations.md`](Docs/Operations.md)
- [`Docs/Testing.md`](Docs/Testing.md)

DailyDisk is available under the [MIT License](LICENSE).

### Growth chart interpretation

Overview and report details list up to five non-overlapping growth entries and up to five non-overlapping release entries from the stored ranking. Ancestors and duplicate paths are excluded first; each row's bar is relative only to the largest displayed entry, not to all file growth or the physical disk delta. Unattributed APFS space never becomes a source row. A "space composition" card shows `physical delta = net file delta + unattributed delta + DailyDisk overhead`; its proportional bar appears only when all non-zero parts share one sign, and the explanation of unattributed space lives in the card's info popover. The complete stored ranking (including overlapping ancestors, allocated and logical bytes) remains under the report's collapsed details. Fixed system-directory descriptions (for example diagnostics logs below `private/var/db/diagnostics`) appear only after session path disclosure; hidden paths remain hidden in every list.

全量检查完成文件遍历后，如有无法读取的目录，会显示“正在保留无法读取目录的历史记录”，并展示处理数量；这一步可取消，之前的报告和基线会保留。事件日志身份改变时会自动进行全量恢复，因此并非每次例行检查都能使用增量扫描。

### 回收 DailyDisk 自身占用

在 **设置 → 诊断 → 数据占用** 查看当前占用、数据库可复用空间和上次维护结果，选择 **回收数据库空间** 让后台 helper 整理数据库。当前基线和历史报告会保留；需要每日任务已安装并获批准，也需要足够的临时空间。维护开始后不可取消，可以关闭窗口等待完成。

旧库存有 24 小时恢复窗口，后续后台运行时清理。自动压缩有空间阈值和七天冷却期，不会每天无条件执行。全量扫描仍需要临时空间；详情见 [运行维护](Docs/Operations.md#reclaiming-dailydisk-data-space)。升级后请重新打开 GUI，使其与 helper 使用同一版本。

Before updating an existing installation, finish scans, remove the daily task in Settings, quit the GUI and close CLI inspections. Rebuild with the original signing identity, then reopen the app and enable the daily task again. The installer validates signatures, refuses active/registered workers and restores the previous app on replacement failure. See Docs/Installation.md for interruption recovery and database rollback limits.

### Installation locations and updates

Source installation now defaults to /Applications. Use --debug --install for a Debug build in ~/Applications, or --user --install for a Release build there. Existing installations update in place; do not keep production copies in both folders. Explicit INSTALL_DIR remains supported, but conflicts with --debug/--user are rejected. Never run the build script with sudo.

Configured builds offer manual Sparkle updates. Update preparation uses private Control files; Sparkle may request administrator authorization when replacing a protected app. Log out other users before updating a shared installation. Source builds leave updates disabled unless feed and public key are explicitly supplied. See Docs/Installation.md for signing, recovery and acceptance limitations.
