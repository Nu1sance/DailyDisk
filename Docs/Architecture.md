# Architecture

DailyDisk is split into four layers:

1. **DailyDiskCore** — domain models, accounting rules, and scan state machines.
2. **DailyDiskStore** — SQLite migrations, inventory generations, checkpoints, and reports.
3. **DailyDiskPlatform** — APFS discovery, file metadata, FSEvents, launchd, and notifications.
4. **DailyDiskApp / DailyDiskAgent / dailydiskctl** — foreground UI, windowless scan worker, and read-only diagnostics.

The dependency direction is App/CLI → Platform/Store → Core. Platform code may depend on Store for orchestration adapters; Core does not import macOS frameworks or SQLite.

The user LaunchAgent is not a daemon. It runs a due scheduled scan or a claimed GUI manual request and exits. The foreground app never performs inventory traversal or owns the SQLite writer lease; permission probes and report inspection remain read-only. The legacy GUI `--scheduled` entry point is removed.

## GUI/helper control plane

Scheduled and manual workers share progress and cancellation; the scheduled worker claims its control identity after acquiring the writer lease. The persisted progress trigger routes interrupted scheduled work back through the due gate/report recovery. The GUI writes versioned fixed-schema JSON under the private `Application Support/DailyDisk/Control` directory (0700; files 0600). `DailyDiskAgent` atomically claims pending requests, binds them to a SQLite run UUID, and publishes path-free snapshots containing only trigger/mode/phase/time/domain ordinal and counters. Atomic temp-file/fsync/rename writes and a cross-process flock prevent half JSON.

Automatic work performs one successful daily full at 05:00; manual work performs full if none completed today with a published report, otherwise attempts incremental with full fallback. Completion day is the inventory post-commit day, with report publication required; delayed publication does not shift it. `DueTimeGate` and `ScanPolicy` use the same local calendar. Daily success is derived from published reports joined to successful full/recovery runs, so later incremental or failed runs cannot erase it. The GUI starts launchd with `kickstart` **without `-k`**, attaches to an existing helper/writer, and reconstructs running/cancelling/finishing state after restart. A PID-scoped idle handshake prevents requests arriving during helper shutdown from being stranded.

Cancellation is cooperative through a throttled `ScanWorkObserving` tracker at FSEvents, directory chunks, record batches, SQLite pages, canonicalization, and reconciliation. Before commit, the control store atomically checks cancellation and publishes `.committing`. SQLite generation/checkpoint commit then runs without cancellation points. Interrupted runs delete overlays/staging while retaining the old active generation/checkpoint.

## Internal APFS discovery

`APFSVolumeProvider` combines three sources:

1. `diskutil apfs list -plist` for containers, physical stores, volumes, roles, and shared capacity.
2. `diskutil apfs listVolumeGroups -plist` for stable System/Data pairing.
3. Disk Arbitration plus the kernel mount table (`getfsstat`) for physical-media trust and actual mount roots.

The mount table is authoritative for hidden startup mounts such as `/System/Volumes/Data`; Finder-oriented mounted-volume enumeration is not used. Disk Arbitration resolves each physical-store partition to its whole disk and fails closed unless the device is internal, non-removable, non-ejectable, non-virtual, and has an I/O device path. External USB storage and disk images are excluded even if they contain APFS.

Container UUID is the physical accounting domain. Capacity is sampled once from `CapacityCeiling - CapacityFree`; per-volume `CapacityInUse` values are never summed as physical usage because APFS volumes share container blocks.

## System/Data namespace policy

Modern macOS boots `/` from a sealed System snapshot and joins it with the writable Data volume through firmlinks. System and Data can share `st_dev`, so a device-boundary check alone cannot prevent duplicate traversal.

DailyDisk records the shared APFS volume-group UUID and assigns an explicit inventory mode:

- active writable Data: `full`
- sealed System snapshot: `metricsOnly`
- all special-role or secondary Data volumes: `metricsOnly`
- unmounted or read-only volumes: `metricsOnly`

This makes `/System/Volumes/Data` the writable startup scan root and prevents a second recursive scan of `/` from rediscovering Data content. System, Recovery, Preboot, Update, VM, and hardware-role volumes remain visible in topology and container diagnostics according to their mount and inventory mode.

## Stable and transient identity

The topology fingerprint contains only stable APFS container, volume, volume-group, role, and policy identity. BSD names, `dev_t`, mount paths, and FSEvents database UUIDs are transient observations and are tracked separately. Reboot-time disk renumbering therefore does not look like an APFS topology replacement.

Only full-inventory mounted volumes retain an FSEvents UUID. Metrics-only System volumes deliberately store no event UUID, so their non-event baseline path cannot be mistaken for an event-checkpoint advance.

## Command execution

External system commands are invoked by absolute path without a shell. `SystemProcessRunner` captures output in private temporary files, executes blocking process work on a dedicated OS thread, enforces a per-request timeout, propagates task cancellation, sends graceful termination first, and escalates to `SIGKILL` after a bounded grace period.

## Daily-full refactor boundaries

The daily-full path starts from a trusted current-journal E0, traverses staging, applies E0–E1 changes and compares final staging with previous committed inventory. It neither replays yesterday’s history nor builds/seals an event-maintained expected inventory. Opaque preservation reads the unchanged baseline through the existing bounded pager; its empty target descriptor does not imply an event-maintained overlay. Final topology/device/journal identity is rechecked before activation. Legacy scheduled reconciliation and incremental-recovery diagnostics retain their old path for compatibility; they are not the default daily policy.

## Full inventory scanning

`FileInventoryScanner` traverses only volumes designated `full`. Before opening a root it revalidates the mount-table/Disk Arbitration identity, APFS kind, internal status, volume UUID, and `dev_t` against discovery. It also builds explicit nested-mount exclusions, because `st_dev` alone cannot describe every modern macOS firmlink and volume-group boundary.

Traversal uses descriptor-relative POSIX operations:

- `fstatat(..., AT_SYMLINK_NOFOLLOW)` reads entry metadata.
- `openat(..., O_DIRECTORY | O_NOFOLLOW)` opens directories without following a replacement symlink.
- `fstat` plus a second `fstatat` binds the traversed directory descriptor to the current path identity before recursion.
- directory entries are copied in bounded chunks before asynchronous batch delivery.
- symlinks are indexed as links and never traversed.

Logical size comes from `st_size`; allocated size uses checked `st_blocks × 512`. Paths are assembled from raw `d_name` bytes and kept volume-relative. Inventory records stream in bounded batches directly to the staging generation, providing backpressure rather than retaining file records in the scanner.

Nested filesystems are skipped even when encountered below a selected root. The sealed System volume remains metrics-only, while `/System/Volumes/Data` is the sole startup writable namespace root.

DailyDisk's own Application Support directory is excluded from ordinary inventory rather than scanned while SQLite is actively changing it. Its database, WAL, SHM, lock, logs, and reports are measured separately as known tool overhead during physical attribution.

Permission-denied paths are subject to independent absolute and fractional completeness limits. On the initial baseline they remain explicitly opaque; on later full scans their merged expected subtrees are copied only into missing staging paths, so successfully scanned current records are never overwritten and opaque data is not reported as deleted. Incremental permission events preserve the previous path state. Provider-unavailable/dataless content is also retained as opaque with coverage diagnostics. Other non-disappearance metadata, directory-read, descriptor, memory, or I/O failures make the scan non-authoritative. `ENOENT`/`ESTALE` races are retained as transient diagnostics for journal replay. Tolerated errors are attached to successful scan commits and stored with the run.

The first full scan is an opening balance and writes no synthetic positive change per existing object. Later ledger validation uses SQLite file-backed temporary tables and ordered canonical-object cursors, so full reconciliation does not materialize multiple complete inventory copies in Swift memory.

## Historical FSEvents sessions

DailyDisk uses one `FSEventStreamCreateRelativeToDevice` session per full-inventory volume. The app persists both the journal UUID and event ID; a newly discovered journal UUID is never substituted for the committed UUID during catch-up validation.

A session starts immediately and has two explicit phases:

1. `replayHistoricalEvents` drains bounded batches through `HistoryDone`.
2. `flushLiveEvents` performs a synchronous FSEvents flush on a utility dispatch queue, waits for the callback queue to drain, captures a complete-callback mailbox sequence boundary, and consumes every event at or below that boundary. Cancellation is checked around the native flush and during delivery.

`SinceNow` sessions install a synthetic sequence-zero history boundary before callbacks can arrive, so their first events are live. Event IDs advance only after the consumer successfully processes a batch. Consumer failure, cancellation, timeout, stop/flush races, stream loss, UUID replacement, event IDs below the committed cursor, root replacement, unmount, invalid paths, or internal buffer overflow cannot produce a trusted fence.

The session actor uses a non-reentrant state machine (`idle → replaying → historyReady → flushing → finished`). Overlapping replay, flush, or stop operations interrupt the active operation instead of splitting batches between consumers. A `HistoryDone` timeout permanently stops and poisons that session; recovery must open a fresh `SinceNow` session around the authoritative full scan.

Historical and live trust are accumulated separately. A repaired historical `MustScanSubDirs` condition does not poison the later post-scan live fence, while dropped/wrapped/root-change history requires abandoning the session. Diagnostics are sticky per phase rather than unbounded per event.

The stream requests file-level events, root-change detection, and immediate delivery. It does not use `IgnoreSelf`: DailyDisk's own paths are excluded by inventory policy, and retaining self events avoids advancing past an unproven ordinary-namespace mutation. Callback paths are decoded as C strings because `UseCFTypes` is intentionally not enabled, stripped only of device-root separators, validated as raw volume-relative bytes, and tested against exact APFS-relative paths.

Metadata operations retry `EINTR` with a bounded retry budget. Dataless directories are not materialized for inventory. Provider `EDEADLK` failures are recorded as `contentUnavailable`, included in unreadable coverage, and preserve prior opaque inventory just like permission-denied paths. Other I/O failures remain fatal rather than silently removing indexed content.

FSEvents callbacks are accepted as whole batches under one mailbox lock. Historical file-event IDs can arrive unsorted: consume every callback through HistoryDone and a synchronous native flush before sealing a cursor, rather than treating callback arrival order as journal loss. Flush work runs off the main/cooperative executor. HistoryDone is a control sentinel, not a filesystem event ID. UUID changes, dropped/wrapped events, buffer overflow, and IDs below the committed cursor still require recovery. Coalesced create/remove flags reconcile missing endpoints, distinct observed identities, and single-link replacements from current metadata; ambiguous shared inode aliases still require recovery. Regression coverage includes unsorted batches, a burst of real FSEvents, and single-link versus hard-link replacement.

Observed inode reuse may proceed only when the run overlay contains no surviving paths for the old identity; surviving aliases still force recovery. Subtree paging uses explicit lower/upper path bounds plus an exact descendant predicate so SQLite seeks into the path index rather than rescanning an entire generation for every changed directory. Tests retain adjacent names such as `cache-neighbor`, `cache.more`, and `cache0`.

### Notification process isolation

Scheduled notification delivery runs in a short-lived process of the enclosing signed `Contents/MacOS/DailyDisk` executable. The internal `--deliver-notification` mode accepts a bounded encoded aggregate-only message, uses a prohibited activation policy, creates no SwiftUI scene or inventory writer, never requests authorization, and exits after delivery. The scan helper waits at most 15 seconds; denial, launch failure, timeout, or a child framework crash is caught as notification-unavailable and cannot prevent report/task completion. Alert cooldown is persisted only after successful delivery. The internal `--notification-status` mode reads authorization without sending or requesting permission. The GUI bundle identifier/signature/install path remain unchanged.

Do not instantiate the system notification center from the bare `DailyDiskAgent` helper: macOS can raise an Objective-C assertion that Swift `catch` cannot handle. `NotificationManager` lazily checks for an app bundle before accessing the center; unsupported processes return an error.

Darwin `dev_t` is a signed 32-bit bit pattern. Persist device identities by zero-extending `UInt32(bitPattern: st_dev)` and reconstruct native FSEvents device IDs using the same bit pattern. Direct `UInt64(st_dev)` conversion can trap on mounted volumes with negative device IDs, including hosted macOS runners. Positive stored identities are unchanged; regression coverage includes both signed boundaries and rejects values wider than 32 bits.
