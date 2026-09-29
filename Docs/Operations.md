# Operations

See [Installation](Installation.md) for source builds, toolchain dependencies, signing, and first-time permissions.

## Process model

DailyDisk has three independently signed executables inside one signed app bundle:

- `Contents/MacOS/DailyDisk` — interactive SwiftUI setup/status application
- `Contents/Helpers/DailyDiskAgent` — windowless scheduled worker
- `Contents/Helpers/dailydiskctl` — strict read-only local diagnostics CLI

The worker is launched by a user-domain SMAppService LaunchAgent. It does not daemonize and does not use `KeepAlive`. The GUI submits manual requests to the same helper and never scans in-process.

## Schedule and due gate

The embedded schedule is 09:00 local time with `RunAtLoad = true`. The database/report due gate handles:

- one successful report per local scheduled day
- login before 09:00 without an unnecessary run when yesterday succeeded
- catch-up when yesterday was missed
- immediate first baseline
- sleep/clock/DST calendar resolution
- recovery of a committed scan whose report was not yet published

Full scans use a rolling 168-hour deadline, not a weekday label. Event loss, journal replacement, topology change, or inventory drift can trigger an earlier recovery full scan.

The task runs in the logged-in user's domain. It is not a power-on/wake scheduler and cannot run while the Mac is shut down or the user is logged out. GUI closure alone does not stop it. Timings observed locally range from 17 seconds for a small incremental check to about 2 minutes 50 seconds for overnight changes; the initial 2.36-million-path baseline took about 23–24 minutes. These are not service-level guarantees.

## GUI-first manual operation

Use **概览 → 立即检查** for an unconditional user-requested run. The app starts or attaches to `DailyDiskAgent` without killing it, displays phase/count/elapsed progress, and can be closed safely. Reopening reads persistent progress from the private Control directory. Manual requests bypass the daily due gate but retain initial/incremental/weekly/recovery policy; **设置 → 通用 → 重新完整检查磁盘** explicitly forces full inventory.

Use **取消检查** before commit. The helper stops FSEvents at a safe boundary, marks the run interrupted, clears staging/overlays, and preserves the prior baseline. During atomic commit/report publication the app displays **正在保存结果，请稍候。此阶段不可取消。**.

All ordinary inspection is in the GUI:

- **概览** — one setup-aware primary action, immediate feedback, scan progress, latest result and growth sources
- **历史** — report selection, session path disclosure, confirmed JSON export; advanced accounting is collapsed
- **设置 → 通用 / 磁盘权限 / 诊断** — schedule, notifications, full recheck, reset, permissions and expert health information

Both scheduled and manual workers persist progress through the same owner-only Control protocol. A scheduled worker claims the channel only after acquiring the database writer lease; a simultaneous manual request takes priority. On restart, the persisted trigger chooses scheduled recovery or manual recovery. The progress protocol keeps its existing schema. Separate database migrations 003/004 improve large-generation cleanup.

The open GUI polls for new scheduled work even while idle. It does not repeatedly kickstart a failed helper. A stale progress snapshot plus a stopped helper and free writer lease produces an interruption message after a 15-second observation grace period. Retry remains explicit. An old result stays visible when report inspection is temporarily unavailable.

Control timestamps are encoded as whole-second ISO8601 values. Start identity comparisons use the same wire precision, so fractional `Date()` values do not reject subsequent progress and commit transitions. Progress age reports the last observed update; an advancing elapsed timer alone is not claimed as proof of work.

The foreground executable no longer implements the legacy `--scheduled` scan entry point. All scan execution belongs to `DailyDiskAgent`.

## Scheduled pipeline

For each internal APFS domain:

1. Register current topology and demote stale full-volume selections.
2. Recover an unreported committed run before starting another scan.
3. Check whether a report is due.
4. Run initial full, scheduled full, or daily incremental policy.
5. Persist inventory, semantic ledger, diagnostics, samples, generation, and FSEvents checkpoint atomically.
6. Build and publish a private report pair, then commit the validated report row.
7. Evaluate alert thresholds and persistent cooldown.
8. Rotate/prune owned logs and report directories.
9. Exit.

A domain failure is logged and does not prevent later domains from being processed. The helper exits nonzero if any domain or retention operation failed.

## Full-scan event boundaries

A full scan does not buffer an entire traversal's live events in memory:

1. Replay existing history and flush a concrete pre-scan cursor `E0`.
2. Stop that session.
3. Traverse into a staging generation.
4. Open a new historical session from `E0`.
5. Replay scan-time events from the durable journal into staging and expected state.
6. Flush a final concrete cursor `E1`.
7. Seal, reconcile, and atomically activate staging with `E1`.

If the journal cannot cover the interval, the staging generation is discarded and a fresh topology/journal recovery is attempted.

## Permission boundaries

The foreground probe attempts actual directory enumeration. It reports likely granted, likely denied, or inconclusive; macOS provides no definitive public FDA preflight API.

During scanning:

- permission-denied paths remain diagnostics
- initial baseline may omit inaccessible opaque regions
- later full scans copy missing opaque subtrees from the merged expected state without overwriting successfully scanned current records
- incremental permission events preserve the previous opaque state and advance with a diagnostic
- dataless/provider-unavailable content remains opaque and is reported in coverage
- other non-permission I/O/metadata failures invalidate authoritative scanning

## Storage and recovery

The helper owns a nonblocking exclusive `flock` on `DailyDisk.sqlite.lock`. Only one helper writer can run; the foreground GUI is never a writer. Scan writes use WAL with `synchronous = FULL`; active inventory and checkpoint switch in one SQLite transaction.

On startup, abandoned `running` rows are marked interrupted and their staging targets are removed. The previous active generation/checkpoint remains intact. The most recent retired generation is retained for up to 24 hours from retirement and pruned on later idle helper work after report publication; earlier retired generations can then be removed.

Read-only CLI inspection acquires a shared process lease and refuses a nonempty WAL before opening an immutable SQLite view.

## Report publication

A report pair lives in a run-UUID directory:

```text
Reports/<run-uuid>/report.json
Reports/<run-uuid>/report.md
```

Both files are written and chmoded in a hidden staging directory before the directory is renamed into place. Existing run artifacts are immutable and validated against the requested report. If the database report is already committed, retry loads that exact payload; if only artifacts exist, their payload is used to complete the validated database commit.

## Alerts

Default conditions include:

- physical growth ≥ 5 GiB
- available space ≤ 20 GiB or 10%
- path growth ≥ 3 GiB
- absolute reconciliation correction ≥ 1 GiB
- absolute physical unattributed change ≥ 2 GiB
- deleted-open files
- unreadable/error diagnostics

Identical reason sets are suppressed for 24 hours using private persisted alert state. Notifications contain aggregate values only. Notification denial/failure never invalidates a scan or report.

## Logs

Unified Logging receives validated event identifiers only. Local JSONL logs accept closed typed public scalars/identifiers; arbitrary strings must use sensitive metadata and are SHA-256 hashed. Default rotation is 5 MiB × 5 files.

## Diagnostics

Use the app's **诊断** screen for normal health checks. While a writer is active it shows “等待扫描完成” instead of attempting immutable verification. `dailydiskctl status/history/report/verify/diagnostics` remains available for automation, machine exit codes, and expert troubleshooting.

`verify` checks integrity, foreign keys, exact migration history, generation/checkpoint invariants, abandoned runs, and report payload/index consistency. Exit status:

- `0` healthy/success
- `2` verification found an unhealthy database
- `64` CLI usage error
- `65` corrupt/invalid data
- `66` missing database/report

## Reset

Use **设置 → 重置历史与基线**. After explicit confirmation, DailyDisk requires the LaunchAgent to be unregistered, proves helper and writer quiescence, acquires an exclusive stable reset lease, clears inactive control state, atomically detaches the fixed `Application Support/DailyDisk` root, preserves the control handshake, and deletes the database, baseline, reports, logs, and alert state. It never accepts an arbitrary path or follows a symlink.

The next manual/scheduled run creates a new opening baseline. Full Disk Access and notification authorization are intentionally not revoked automatically.

## Progress, cleanup, and performance details

Overview refresh uses lightweight WAL-aware read-only queries. Complete database verification and table-size diagnostics run only via **设置 → 诊断 → 验证数据库** (or the strict CLI); opening the app must not trigger a full integrity scan or prevent recovery of a nonempty WAL. An unverified overview is never labeled healthy.

Failed full scans publish `cleaningUpFailedRun` before deleting staging data. The UI must show safe cleanup, not stale file traversal or report publication, while that transaction completes.

Metadata operations retry `EINTR` with a bounded retry budget. Dataless directories are not materialized for inventory. Provider `EDEADLK` failures are recorded as `contentUnavailable`, included in unreadable coverage, and preserve prior opaque inventory just like permission-denied paths. Other I/O failures remain fatal rather than silently removing indexed content.

FSEvents callbacks are accepted as whole batches under one mailbox lock. Historical file-event IDs can arrive unsorted: consume every callback through HistoryDone and a synchronous native flush before sealing a cursor, rather than treating callback arrival order as journal loss. Flush work runs off the main/cooperative executor. HistoryDone is a control sentinel, not a filesystem event ID. UUID changes, dropped/wrapped events, buffer overflow, and IDs below the committed cursor still require recovery. Coalesced create/remove flags reconcile missing endpoints, distinct observed identities, and single-link replacements from current metadata; ambiguous shared inode aliases still require recovery. Regression coverage includes unsorted batches, a burst of real FSEvents, and single-link versus hard-link replacement.

Observed inode reuse may proceed only when the run overlay contains no surviving paths for the old identity; surviving aliases still force recovery. Subtree paging uses explicit lower/upper path bounds plus an exact descendant predicate so SQLite seeks into the path index rather than rescanning an entire generation for every changed directory. Tests retain adjacent names such as `cache-neighbor`, `cache.more`, and `cache0`.

Cancellation cleanup can take several minutes for a large staging inventory. The GUI explicitly displays that it is waiting for temporary-index cleanup, including after reconnecting, instead of treating the absence of per-file updates as a stale scan. The stopped-helper watchdog remains active.

During atomic commit and report publication, the GUI shows that it is waiting for saving to finish. These phases do not produce per-file progress updates; a large first inventory may take several minutes to save, and cancellation remains unavailable.

On restart, a persisted committing phase with a still-running SQLite scan is treated as an interrupted transaction, not committed-report recovery. The helper publishes non-cancellable failure cleanup, removes abandoned staging, and only then resumes inventory work for that request. Progress counters remain cumulative across recovery attempts. Ordinary cancellation remains forbidden during commit; cleanup is entered only after rollback or after the new helper owns the writer lease.

Incremental accounting treats an object created and removed during the same replay as no net transition. A synthetic regression covers candidates with neither a baseline nor a final attribution, avoiding an optional-unwrapping crash. GUI polling preserves the immediate requesting state while a manual launch is still being submitted.

### Notification process isolation

Scheduled notification delivery runs in a short-lived process of the enclosing signed `Contents/MacOS/DailyDisk` executable. The internal `--deliver-notification` mode accepts a bounded encoded aggregate-only message, uses a prohibited activation policy, creates no SwiftUI scene or inventory writer, never requests authorization, and exits after delivery. The scan helper waits at most 15 seconds; denial, launch failure, timeout, or a child framework crash is caught as notification-unavailable and cannot prevent report/task completion. Alert cooldown is persisted only after successful delivery. The internal `--notification-status` mode reads authorization without sending or requesting permission. The GUI bundle identifier/signature/install path remain unchanged.

Do not instantiate the system notification center from the bare `DailyDiskAgent` helper: macOS can raise an Objective-C assertion that Swift `catch` cannot handle. `NotificationManager` lazily checks for an app bundle before accessing the center; unsupported processes return an error.

### Growth chart interpretation

Overview and report details list up to five non-overlapping growth entries and up to five non-overlapping release entries from the stored ranking. Ancestors and duplicate paths are excluded first; each row's bar is relative only to the largest displayed entry, not to all file growth or the physical disk delta. Unattributed APFS space never becomes a source row. A "space composition" card shows `physical delta = net file delta + unattributed delta + DailyDisk overhead`; its proportional bar appears only when all non-zero parts share one sign, and the explanation of unattributed space lives in the card's info popover. The complete stored ranking (including overlapping ancestors, allocated and logical bytes) remains under the report's collapsed details. Fixed system-directory descriptions (for example diagnostics logs below `private/var/db/diagnostics`) appear only after session path disclosure; hidden paths remain hidden in every list.

### Full recovery after a journal change

A changed FSEvents journal UUID invalidates the saved cursor and requires full recovery. File traversal is followed by the separate cancellable `preservingOpaqueInventory` phase when previous unreadable content must be retained. Its counters report completed disjoint roots and newly preserved paths. The GUI must show this work distinctly from traversal. A bounded pager is also required during the subsequent full diff; do not diagnose unchanged traversal counters alone as a stopped helper.


## Reclaiming DailyDisk data space

Open **设置 → 诊断 → 数据占用**. **刷新占用** reads allocated managed-file space, internal reusable database space, and the last successful maintenance result. **回收数据库空间** sends a helper request; it preserves the active baseline and historical reports and does not scan files. The daily helper must be installed and approved, as for manual checks.

Temporary free disk space is required (conservative check: twice the database logical size plus 1 GB). If insufficient, compaction is declined with an explicit message. Do not manually delete the SQLite/WAL files to free space. If a scan or report needs recovery, first run a normal check, then retry maintenance. Cleanup/compaction/verification can take minutes and cannot be cancelled after their boundary; the window can be closed and reopened safely. After a helper crash, the next invocation validates SQLite recovery; a manual maintenance request reports interruption rather than automatically repeating VACUUM.

Automatic compaction is limited by the 1 GB / 25% / seven-day thresholds. This does not make the helper resident. Until incremental failures are resolved, full recovery scans still need staging/overlay/WAL space and may reuse or regrow free pages. “本轮自身增长” and “当前数据占用” refer to different times; maintenance never rewrites past accounting. Historical ledger retention and path-dictionary optimization remain future work.

Upgrade the GUI and helper together and restart the GUI. Schema 5 is not readable by an older writer; keep the signing identity, bundle ID and installed path stable. This source change does not itself migrate or compact an installed user's database.

## Switching to schema 6 during internal testing

Use a fresh database when switching this internal-beta installation to schema 6. Old history and checkpoints are discarded explicitly during installation, not converted. Update the GUI/helper together and restart the GUI. The first new report is an opening balance; the next successful report begins growth comparisons.

### Installed transition update (2026-09-29)

The user authorized deletion of old inventory and installation with a fresh baseline. The dedicated `InventoryFormatError`, `baselineResetRequired` Control category, GUI message and manual/scheduled compatibility branches have been removed. Earlier reset-prompt descriptions are historical. No conversion or old-checkpoint reuse is implemented. The migration retains only its generic empty-database consistency precondition to prevent destructive table replacement beneath an existing checkpoint.

### Missing helper after reinstall

After replacing or reinstalling the app, SMAppService can still report enabled while `launchctl print` reports that the helper job is missing. A manual request then remains queued with zero progress, and the GUI eventually shows “检查未完成 / 后台任务没有继续运行”; retrying kickstart alone cannot recreate the job. On a start request, DailyDisk now distinguishes a missing job from a loaded, stopped job and repairs only the enabled-but-missing case with one SMAppService unregister/register cycle. It preserves the queued request, rechecks approval and runtime state, and attaches if RunAtLoad has already started the helper. Unknown inspection errors, registration failures and a still-missing job stop recovery; polling does not become a persistent repair loop. Existing running/idle jobs are not re-registered. No history reset is needed.
