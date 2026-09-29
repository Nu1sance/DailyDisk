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

### Overlay paging performance regression

Regular coverage includes multi-page base/overlay merging with dense deletions, replacements, additions, overlapping roots and adjacent path names; cancellation between preservation batches; and persisted progress with fractional timestamps and legacy counter decoding. The opt-in million-row test now also copies the surviving inventory through opaque preservation and performs a full zero-difference comparison. Local measurements were 12.4 seconds for approximately one million preserved records and 10.8 seconds for the full diff, with the active checkpoint unchanged. These are synthetic measurements, not a promise of whole-disk scan duration. Test budgets are 120 seconds and 60 seconds respectively.

Installed recovery validation after the paging repair completed successfully across approximately 2.4 million visited paths in 32 minutes 16 seconds. The 214 opaque roots were processed in approximately one second (no historical paths needed copying). The remaining major full-scan costs were traversal, canonical/index preparation and atomic persistence; the fix does not make full recovery instantaneous. Reports were published and the helper exited normally. Post-run inspection found no active runs, an empty WAL, and a checkpoint journal UUID matching the current device. The pre-run full integrity/foreign-key/invariant/report verification was healthy. Regular coverage passed all 208 enabled tests, the million-row stress test passed separately, and GitHub CI passed. Final synthetic preservation/diff timings were 13.6/9.8 seconds.

## Space maintenance regression gates

Schema 5 tests reconstruct the published v4 schema, migrate at a fractional timestamp and preserve the active checkpoint while granting old retired inventory a fresh recovery window. Synthetic fixtures cover expiry boundaries, pending reports, running scans, rollback of cascaded cleanup, long paths, non-UTF-8 hard-link aliases, space preflight failure, writer contention, and report/checkpoint preservation through real VACUUM. A subprocess test kills `/usr/bin/sqlite3` during VACUUM WAL writes and verifies reopened inventory/report integrity; it uses only a temporary synthetic database.

Platform/App coverage exercises the distinct `reclaimSpace` request, persisted fractional-time progress, cancellation closure, GUI reconnect, zero-domain `maintenanceCompleted`, explicit insufficient-space errors, and interrupted manual maintenance without automatic re-compression. Normal overview polling still does not run storage analysis or full verification.

The opt-in million-row test now uses long shared path prefixes. It retains its 10-second incremental lookup and commit budgets, then commits two authoritative generations, publishes reports, expires retired inventories and performs compaction twice. It records staged/retained/compacted allocated bytes and activation/maintenance time. A 50 ms sampler measures database/WAL/SHM allocation peaks by phase; this is not a measurement of all OS temporary files or a production scanner peak. All fixtures are synthetic and removed afterward.

Local validation on 2026-09-28 passed the million-row test in 477.4 seconds. Measurements use allocated bytes and decimal GB:

| Cycle | After activation/report | After retirement cleanup + VACUUM | Activation | Maintenance |
| --- | ---: | ---: | ---: | ---: |
| 1 | 2,720,239,616 | 1,012,027,392 | 57.57 s | 37.88 s |
| 2 | 2,605,862,912 | 1,012,027,392 | 60.03 s | 33.15 s |

The largest sampled database/WAL/SHM allocation was 3,743,653,888 bytes during maintenance. Thus compaction reduces the final footprint but itself needs transient space and I/O. After the second VACUUM, 32 narrow incremental subtree lookups took 0.056 seconds and their commit took 0.012 seconds, both below the existing 10-second budgets. Opaque preservation/full diff took 26.89/30.84 seconds. These figures cover synthetic store operations, not whole-disk traversal or SQLite's complete OS temporary-file footprint.

During synthetic validation, the development package was built separately with explicit ad-hoc signing; deep strict signature verification and the packaged helper dry-run passed. That validation did not replace the installed app or migrate/compact a real inventory database. Subsequent authorized local maintenance is recorded below. Full installed UI acceptance and multi-day space/scan observations remain outstanding. At the start of a daily scan, a retirement may still be less than 24 hours old; this round does not guarantee that active, retired and staging never coexist.

Final format lint, `swift build`, LaunchAgent lint and the ordinary suite passed (runner reported 222 tests, with the opt-in stress case skipped). One preceding ordinary run had transient failures in the existing `stopFallbackIsRequestScoped` timing test and the native `quietSinceNowCursor` integration test; an immediate complete rerun passed without changes. This is not evidence that the separately deferred incremental-scan reliability issue is resolved.

### Installed maintenance acceptance, 2026-09-28

At the user's explicit request, the app was rebuilt and installed with its original persistent signing identity, bundle ID and installation path. Before replacement and maintenance, an idle writer lease protected a private copy of the runtime data; the database copy passed byte-for-byte SHA-256 verification and the previous app was retained. The existing Control API enqueued a `reclaimSpace` request for the registered signed helper. The new GUI was reopened, and the helper completed successfully with exit status 0; no inventory scan was started.

| Database metric | Before | After |
| --- | ---: | ---: |
| Logical bytes | 12,978,671,616 | 7,183,630,336 |
| Allocated bytes | 12,985,589,760 | 7,183,630,336 |
| Reusable bytes | 4,997,627,904 | 0 |
| Schema | 4 | 5 |

The allocated database footprint decreased by 5,801,959,424 bytes (5.80 decimal GB, 44.7%). Helper maintenance, including its before/after validation, took 1,072 seconds (17 minutes 52 seconds). A read-only stack sample during the long phase confirmed native `sqlite3RunVacuum` page I/O. This real run was substantially slower than the synthetic fixture; neither timing is a general guarantee.

Independent validation hashed all original business-table columns in primary-key order and compared them with the backup, including all inventory generations, paths, objects, canonical attributions, checkpoint, ledger and historical samples. All matched; all report artifact hashes also matched. Migration metadata, the added retirement timestamp and maintenance state were the intended new data. The two inventories and ten reports were retained. Strict CLI verification before and after returned healthy, with integrity `ok` and zero foreign-key, generation/checkpoint, report-payload and abandoned-run violations. WAL was empty and the installed signature passed deep strict verification. Only after these checks passed were the temporary data and old-app backups deleted, as authorized by the user. This acceptance does not establish multi-day incremental reliability or full UI visual acceptance.

## Second-round storage layout experiments

Run the isolated million-row layout comparison with:

```bash
DAILYDISK_RUN_LAYOUT_STRESS=1 swift test --filter millionRecordLayoutComparison
```

This opt-in test complements the existing `millionRecordInventory` end-to-end store test; it does not replace it. Five layouts use identical long raw paths, UUID-length external IDs and hot inventory metadata. Each builds one million rows in batches of 1,024, adds ten non-UTF-8 hard-link aliases, seals canonical attribution, activates a checkpoint, then repeats with 10% renamed paths and selected replaced identities; classification changes are covered separately by ordinary tests. Measurements cover compacted one-/two-generation pages, generation build/seal, narrow lookups, 32 candidate-bounded incremental deletions, full path paging (except the deliberately rejected pure-tree reconstruction pager), retired cleanup and dictionary GC. Million-row paging verifies the surviving count; the ordinary 4,096-row fixture compares every returned page with its expected records. A separate sparse generation measures first-page VM steps and the query plan. A second full replacement returns to the original path set after GC, verifying re-interning, activation, cleanup and final object/path/canonical counts. A 50 ms sampler records database/WAL/SHM allocation by phase, excluding SQLite's other OS temporary files.

Ordinary tests cover raw non-UTF-8 aliases, signed inode boundaries, canonical path selection independent of insertion order, generation/classification isolation, adjacent directory names, multi-page seeks, checkpoint-protected deletion rollback, and overlay/parent references during dictionary GC. A 4,096-row sparse-generation regression proves that an indexed dictionary range query can do over 100 times the work of generation-local paging despite the same LIMIT. This negative test is intentional: it prevents an unsafe layout from being approved solely on size or a superficial EXPLAIN plan.

Only hot inventory tables and simplified catalogs are compared; full production overlays, history, scanner traversal and migration are not benchmarked by this fixture. UUID layout catalogs also carry explicit external-ID mapping columns for a uniform harness, so these totals are not an exact whole-schema-5 database measurement. Timings use a fixed layout order on one machine, not repeated cold-cache trials. All input is synthetic, temporary databases are removed, and no installed database is read or modified.

### Layout measurements, 2026-09-29

The final comparison passed in 359.7 seconds. Every full generation contains one million objects and ten additional non-UTF-8 hard-link paths. Compacted figures below are `page_count × page_size` after VACUUM/checkpoint; peaks are sampled allocated database/WAL/SHM bytes and exclude other SQLite temporary files.

| Layout | One generation | Two generations | After second replacement/cleanup | Sampled peak |
| --- | ---: | ---: | ---: | ---: |
| UUID + raw paths | 1,240,322,048 | 2,480,533,504 | 1,240,326,144 | 5,070,839,808 |
| Integer + raw paths | 744,034,304 | 1,508,061,184 | 753,082,368 | 3,129,614,336 |
| Integer + shared paths | 400,027,648 | 589,516,800 | 408,203,264 | 1,241,055,232 |

| Operation (seconds unless stated) | UUID | Integer | Shared paths |
| --- | ---: | ---: | ---: |
| First-generation build | 10.61 | 8.96 | 29.17 |
| First-generation seal | 4.28 | 6.14 | 2.76 |
| Second-generation build | 13.22 | 10.96 | 25.52 |
| Second-generation seal | 10.33 | 7.02 | 1.93 |
| 32 narrow lookups | 0.0165 | 0.0034 | 0.0039 |
| 32 candidate-bounded incremental removals | 0.0134 | 0.0080 | 0.0059 |
| Full-generation path paging | 0.897 | 0.489 | 0.659 |
| Retired-generation cleanup | 11.65 | 7.63 | 5.58 |
| Dictionary GC after first cleanup | n/a | n/a | 4.68 |
| Sparse first page: SQLite VM steps | 32 | 32 | 6,606,108 |

The integer candidate reduces two-generation pages by 39.2% and preserves generation-local range seeks. It is selected for the next production adaptation experiment, not declared ready to migrate users. Individual timings vary: the integer candidate's first seal was slower in this run. The shared dictionary saves 76.2%, but additional construction work and the unbounded sparse-generation pager disqualify this version from production integration. Its sparse query took only 0.063 seconds on this warm synthetic fixture; VM steps, rather than that absolute time, reveal the scaling problem. Both builds reuse prepared SQL statements. Dictionary GC removed 100,034 and 99,968 entries across the two replacements, and the final check found no unreferenced dictionary leaves.

The fixture uses small integer surrogate keys and largely path-correlated inode ordering. Production key distributions, random identity lookups, metadata sizes and path lengths can change the result. The command-level `/usr/bin/time -l` maximum resident-set report was 315,244,544 bytes; this is not a per-layout memory profile or proof of a universal bound.

The ordinary suite passed with 227 tests reported (both opt-in stress cases skipped). The existing `millionRecordInventory` chain passed separately in 477.6 seconds: opaque preservation/full diff 26.42/30.12 seconds, post-compaction incremental lookups/commit 0.063/0.012 seconds. Format lint, build, LaunchAgent lint, a separate explicitly ad-hoc development package, deep strict signature verification and packaged helper dry-run passed. No schema 006, production storage adapter or installed-data migration was introduced.

### Tree-node comparison protocol, 2026-09-29

The supplement adds treePaths (parent/name only) and treeOrdered (parent/name plus generation-local full-path ordering). Run all five in the same Release invocation:

```bash
DAILYDISK_RUN_LAYOUT_STRESS=1 swift test -c release --filter millionRecordLayoutComparison
```

For targeted reproduction, set DAILYDISK_LAYOUT_ONLY=treePaths or treeOrdered in addition; omit it for the full comparison. These are opt-in synthetic tests, never installed-data migrations.

The pure-tree pager is a measured negative candidate: a 1,024/4,096-record test measures work for an identical 128-row page. It reconstructs and sorts all members of the selected generation on every request. At a million rows the harness measures one narrow lookup (the legacy metric key is narrowLookups) and one 1,024-row first page (firstPageOnly), explicitly skipping the quadratic full traversal and the 32-lookup budget for this rejected algorithm. All other layouts run all 32 lookups and full pagination with the existing budgets. Pure-tree sparse paging remains cheap because reconstruction begins at generation membership rather than at the global dictionary. Do not mistake that sparse success for bounded dense-generation paging.

All five still execute both million-row builds/seals, candidate removals, activation, two replacement/cleanup cycles, compaction and integrity/FK checks. Tree-specific ordinary tests compare every returned record across deep/wide renamed trees and verify canonical alias selection plus old/new generation isolation. Counts in the million test are supplemented by exact-record tests at smaller scale.

Results below distinguish Release measurements from the earlier debug invocation. Allocation samples exclude SQLite OS temporary files; recursive reconstruction/sorting may consume those files, so sampled DB/WAL/SHM is not total disk peak. Fixed-order single-machine timings are comparative evidence, not confidence intervals or an end-to-end scan speedup.

The initial Release run was stopped during hybrid sealing after EXPLAIN confirmed a generation-wide correlated lookup. Its incomplete execution is not an acceptance result. After enforcing candidate-first join order and adding layoutTreeCanonicalPlan, all seven ordinary layout test functions passed; the complete Release comparison was restarted. Intermediate synthetic databases from the interrupted run were removed.

### Final five-layout Release results, 2026-09-29

The corrected comparison passed in 589.4 seconds (596.7 seconds for the command including incremental compilation). Decimal byte counts below include every persistent auxiliary index. This was a single fixed-order run; differences in elapsed time are not statistical guarantees.

| Layout | One generation | Two generations | After second replacement/cleanup | Sampled DB/WAL/SHM peak |
| --- | ---: | ---: | ---: | ---: |
| UUID + raw paths | 1,240,322,048 | 2,480,533,504 | 1,240,326,144 | 5,070,839,808 |
| Integer + raw paths | 744,034,304 | 1,508,061,184 | 753,082,368 | 3,129,614,336 |
| Shared full paths | 400,027,648 | 589,516,800 | 408,203,264 | 1,241,055,232 |
| Parent/name only | 219,025,408 | 390,815,744 | 227,205,120 | 823,795,712 |
| Parent/name + ordered paths | 446,771,200 | 847,151,104 | 455,139,328 | 1,757,560,832 |

| Operation (seconds unless stated) | UUID | Integer | Shared | Pure tree | Hybrid tree |
| --- | ---: | ---: | ---: | ---: | ---: |
| First build | 9.6761 | 8.0586 | 22.4836 | 22.1546 | 29.8954 |
| First seal | 9.6366 | 2.8980 | 1.2163 | 4.4807 | 1.6097 |
| Second build | 11.5739 | 10.2502 | 22.7829 | 21.8812 | 30.8318 |
| Second seal | 10.0376 | 3.5331 | 1.7041 | 5.4678 | 3.4152 |
| 32 narrow lookups | 0.0167 | 0.0030 | 0.0039 | 2.9882 (one query only) | 0.0034 |
| 32 candidate removals | 0.0141 | 0.0080 | 0.0049 | 0.0179 | 0.0103 |
| Full paging | 0.9805 | 0.4443 | 0.6395 | not run; first page 3.4716 | 0.6218 |
| Retired cleanup | 15.3371 | 7.4789 | 5.4454 | 5.4788 | 6.9660 |
| Dictionary/node GC | 0.0000 | 0.0000 | 4.8185 | 3.1218 | 2.0960 |
| Replacement build + seal | 21.1289 | 13.5143 | 26.8133 | 30.4646 | 37.7680 |
| Replacement cleanup + GC | 17.3277 | 8.1668 | 7.8285 | 7.1360 | 8.9512 |
| Sparse first page, VM steps | 32 | 32 | 6,606,108 | 324 | 38 |

Pure parent/name storage saves 84.2% of UUID two-generation space, but this reconstruction pager is rejected: its first 1,024 rows cost 3.47 seconds, versus 0.44 seconds to page the complete million-row integer fixture. The small dense-generation scaling test records 292,507 / 1,164,955 VM steps for the same 128-row page at 1,024 / 4,096 members. This rejects this CTE paging algorithm, not every possible tree traversal implementation.

The hybrid saves 65.8% versus UUID and a further 43.8% versus integer/raw paths. Dense page work stays at 2,831 VM steps in both small fixtures; a sparse generation takes 38 steps rather than the shared full-path dictionary's 6,606,108. Narrow queries, incremental removals and full paging pass the existing 10/10/60-second budgets. Construction is a real tradeoff: first build is 29.90 versus 8.06 seconds, and replacement build/seal is 37.77 versus 13.51 seconds. The hybrid is the next space-focused integration candidate; integer/raw remains the simpler, faster-building alternative. Neither is a production migration yet.

All node/dictionary layouts reclaimed 100,034 and 99,968 entries in the two cleanup cycles and passed final no-unreferenced-leaf, object/path/canonical count, checkpoint, integrity and FK checks. Deep/whole-directory renames are covered by the smaller exact-record tests, not by a million-deep-tree benchmark. Full production overlays, trusted fences, crash-safe migration and end-to-end scanning remain separate gates. The command-level maximum RSS was 814,055,424 bytes; it is not a per-layout memory bound and includes the test/build command. Other SQLite OS temporary files are excluded from disk sampling.

Final validation: swift format lint --recursive Sources App Tests, swift build, swift test (230 tests reported; both opt-in million-row cases skipped), Scripts/lint-launch-agent.sh and git diff --check passed. The five-layout Release million-row case passed separately as recorded above. No production source or schema changed in this supplement, so the previously passing independent millionRecordInventory chain was not rerun. No app was installed and no real database was read, compacted or migrated.

### Further hybrid operational validation

Run the isolated additional million-row workload with:

```bash
DAILYDISK_RUN_HYBRID_STRESS=1 swift test -c release --filter millionRecordHybridValidation
```

It uses one million raw paths and a deterministic bijective multiplication of inode bit patterns, making identity order unrelated to path order (including negative stored Int64 values). It stages 32 metadata updates and 32 tombstones, checks narrow subtree results, pages the complete overlay, copies a deduplicated opaque subtree, diffs the base against the overlay, commits only candidate identities, audits ordering/node equivalence, cleans staging and compacts. It retains 10-second narrow-query/commit and 60-second full-page/diff budgets. This is a storage adapter experiment rather than a production end-to-end run; do not compare its build/size directly with the earlier path-correlated fixture as if only the algorithm changed.

Ordinary tests use an independent raw-record oracle to check every overlay and diff result, old-generation isolation, tombstones, same-path identity replacement, create-then-remove, shared-object metadata across aliases, canonical alias/classification changes, non-UTF-8 bytes, root paths and adjacent directory names. Fault injection checks failed ordering inserts, missing/wrong ordering rows, reachable node cycles, inactive-checkpoint rejection, per-run/per-generation isolation, pre-checkpoint transaction rollback and opaque-copy interruption. These are exception/transaction tests, not process-kill or crash-safe migration tests.

The added full order audit is explicit diagnostic work; its timing is reported separately from candidate commit. Allocation sampling covers database/WAL/SHM, excluding other SQLite OS temporary files. All data is synthetic and automatically removed; production schema and installed data remain unchanged.

The Release hybrid workload passed in 115.2 seconds (125.95 seconds including compilation). Measurements:

| Operation | Seconds |
| --- | ---: |
| Million-record build and seal, non-path-ordered identities | 98.0607 |
| 32 narrow overlay queries | 0.0379 |
| Full overlay pagination | 2.3646 |
| Opaque copy, 999 surviving rows | 0.0143 |
| Two-view diff, 32 updates + 32 removals | 4.7098 |
| Candidate commit | 0.0360 |
| Explicit order/node audit | 3.6208 |

Final compacted pages occupied 374,464,512 bytes. Sampled database/WAL/SHM peak was 823,468,032 bytes; other SQLite temporary files are excluded. Command-level maximum RSS was 884,899,840 bytes (including compilation/test helper, not a per-operation memory bound). All budgets, final counts, checkpoint, integrity and FK checks passed. The empty-root and additional repeated alias-switch cases were added afterward and passed ordinary tests; they do not change the nonempty-root workload or its SQL semantics. This result supports further production adaptation, not installation or migration approval.

Final checks: four new ordinary hybrid test functions passed, and swift test --no-parallel reported 235 passing tests (three opt-in stress tests skipped) in 10.53 seconds. Format lint, build, LaunchAgent lint and diff whitespace checks passed. Two default concurrent suite runs failed in existing integration/timing tests: quietSinceNowCursor returned an untrusted/nil cursor in one, and stopFallbackIsRequestScoped observed a signal in the other. The cursor test passed standalone; both passed in the serial full suite. Their concurrent timing stability remains unresolved; no production trust or cancellation checks were changed. Do not report this as a passing default concurrent suite. The original production million-row and five-layout comparison were not rerun: this supplement has no production changes, and the new adapter workload is recorded separately.

### Investigation of the two intermittent failures, 2026-09-29

The original local logs were retained and inspected. The failures were two assertions in `quietSinceNowCursor` (fullScanRequired and nil cursor) in one run, and one assertion in `stopFallbackIsRequestScoped` (the mock signaler recorded PID 987) in another. They were not failures in the hybrid storage tests. This distinction does not establish that production event handling is healthy.

The stop test had an unsynchronized timing assumption: it launched a stop with a 100 ms fallback, slept 10 ms, then performed several asynchronous/persistent operations to complete the first request and claim the second. Neither the sleep nor those operations guaranteed turnover before the fallback. If the first request remained cancellable, sending its signal was valid, but the test required the signal list to be empty. A controlled experiment changing the initial sleep to 150 ms reproduced the exact `[987]` assertion in a standalone run. This proves the test can fail without terminating a later request; the old logs do not timestamp the original turnover sufficiently to reconstruct its exact interleaving.

The regression now gates the fake runtime-status response using explicit asynchronous handshakes: the fallback is reached, the first request completes and the second is claimed, then the response is released. It still asserts that the old request cannot signal the new one. The production cancellation guard remains unchanged: it checks the active request ID and cancellable progress under the same filesystem lock used for completion/claim, and dispatches the signal inside that lock. The existing positive fallback test still checks that a cancellable request can receive a signal. No real process is signalled by these tests.

The native cursor failure is **not yet root-caused**. Code tracing narrows the observed nil cursor to a SinceNow session with no initial ID, no delivered event establishing an ID, and no usable pre-flush per-device ID. The system provider returns nil when its native time-based lookups return zero (a device-conversion failure also returns nil, but the active session validates that conversion before opening). `makeFence` then deliberately adds `FSEvents could not establish a durable event cursor` and requires recovery. The old log omitted the fence diagnostic, so additional simultaneous trust reasons cannot be excluded. There is no evidence yet that this is the same cause as the installed app's cross-day UUID changes, nor proof that concurrency caused it.

Before the stop-test synchronization change, the two targeted tests and six default concurrent full-suite runs passed. A temporary 32-case concurrent native quiet-cursor probe also passed; the parameterization was then removed. The retained cursor test now reports history/flush diagnostics and records the actual provider calls' journal availability and per-device cursor without adding extra system probes, retries, skips or trust relaxation. A future failure must retain that evidence and correlate the device/time-based cursor lookup with native stream delivery before deciding on a production repair. Do not replace a missing cursor with a global cursor or advance a checkpoint to make this test pass.

After the final test changes, the default concurrent suite reported 235 tests passed (three opt-in million-row workloads skipped) in 3.988 seconds. Format lint, `swift build`, LaunchAgent lint and `git diff --check` passed. The earlier failing observations remain valid; current passing repetitions do not close the unresolved native-cursor investigation. No production source, storage schema, installed app or real database was changed in this investigation, and the storage rollout remains deferred. Million-row storage experiments were not rerun because their implementation was unchanged.

### Hybrid adversarial validation and repairs, 2026-09-29

The user deferred the missing-cursor/cross-day journal investigation and prioritized storage reduction. New adversarial tests found two previously uncovered defects in the **test storage prototype**, before production integration:

1. A failed node insertion rolled back its transaction but left the cached insertion statement in an error state. Retrying on the same connection raised SQLite error 21 (`SQLITE_MISUSE`). `hybridNodeInsertionRecovery` reproduced this using an aborting node trigger, then removing the trigger and retrying. Cached lookup/insertion statements now reset on error as well as success; cleanup preserves the original exception, and batch path caches are discarded. The rollback leaves the original nodes, ordering and checkpoint intact.
2. The old dictionary collector swept all surviving nodes again for each newly exposed ancestor. For the same 65-node obsolete chain, 1,024 versus 8,192 unrelated live paths required 132 versus 594 bounded scan batches. A new leaf queue seeds eligible leaves once, rechecks inventory/overlay/child references inside each transaction, then queues only parents of deleted nodes. Both fixtures now require 65 candidate batches. This does not make total work independent of live inventory: the initial leaf discovery still scans the dictionary once. Temporary candidate tables avoid an inventory-sized Swift collection, and each deletion batch is limited to 1,024 candidates.

`HybridTreeAdversarialTests.swift` adds four ordinary tests: failed insertion/retry, deep-GC scaling, GC interruption/restart with overlay/ancestor protection, and deterministic multi-cycle state comparisons. The latter applies 2,304 mutations over four seeds and 48 committed cycles; an independent raw-path oracle checks multi-device identities, hard links, classifications, non-UTF-8 paths, the empty root, metadata propagation, replacements, tombstones, rollback/retry, retained generation isolation, canonical selection and GC between staging and commit. This is still a test adapter, not the complete production run-revision, trusted-fence or ledger/report protocol.

The updated isolated Release million-row hybrid workload passed in 118.34 seconds. It uses the same non-path-ordered identity fixture as the earlier 115.2-second workload; these are individual runs, not evidence of statistically significant timing changes.

| Operation | Seconds |
| --- | ---: |
| Build and seal | 101.202 |
| 32 narrow overlay queries | 0.0345 |
| Full overlay pagination | 2.787 |
| Opaque copy, 999 rows | 0.0123 |
| Two-view diff | 4.125 |
| Candidate commit | 0.0220 |
| Explicit order/node audit | 3.851 |

Compacted pages remain 374,464,512 bytes. Sampled DB/WAL/SHM peak was 823,050,240 bytes; other SQLite temporary files are excluded. Existing 10-second narrow-query/commit and 60-second pagination/diff budgets passed. No new whole-app disk-size or scan-duration guarantee follows from these numbers.

Final default concurrent `swift test` reported 239 tests passed in 6.431 seconds (three opt-in million-row tests skipped); the hybrid million-row workload passed separately. Format lint, `swift build`, LaunchAgent lint and diff whitespace checks passed. The independent production million-row chain and full five-layout comparison were not rerun: production storage is unchanged, while the modified hybrid path/GC behavior was tested with the targeted workload and ordinary cross-layout tests. Existing native event protections were not relaxed.

This round repairs the prototype; it does not publish schema 006 or switch the installed database. Production integration must carry over statement-error cleanup and bounded ancestor reclamation, then validate the complete run/ledger/report and crash-recovery chain. Under the user's internal-testing decision, old-inventory conversion is no longer a release requirement: use an explicit fresh-baseline transition, reject accidental use of old data as the new format, and never reuse an old checkpoint with an empty new inventory. This replaces the earlier requirement to implement an old-inventory migration, not the requirement for a coherent new baseline and safe initialization.

## Production hybrid integration (2026-09-29)

Schema 006 now runs through the production inventory store, rather than only the isolated adapter. Existing full/incremental revision seals, hard-link accounting, opaque preservation, report recovery, cancellation, generation activation and checkpoint tests therefore execute against compact tables and read-only compatibility views. Published migrations 001–005 are unchanged; historic migration tests target their original versions explicitly. Populated old-format initialization is rejected before migration, preserving the prior schema and checkpoint.

`HybridInventoryTests.swift` adds production checks for exact empty/root/non-UTF-8 path projection, integer keys and immutable nodes/mappings, failed prepared-statement insertion followed by retry, missing or incorrect ordering rows rejected by full sealing and explicit verification, and killing an uncommitted SQLite subprocess after changing compact membership and checkpoint. Reopening verifies the original baseline, canonical rows, ordering and checkpoint. The subprocess test proves SQLite transaction recovery for the new layout; it is not a simulated crash at every helper instruction. `appBaselineResetRequired` checks persisted failure classification and the GUI reset explanation.

An incremental build after extending the Control error enum produced ten invalid-snapshot/summary failures, including a repeatable isolated failure. A clean rebuild without changing validation logic passed all 243 tests in 6.306 seconds; the four new store cases also passed in the earlier build. These failures are retained here as evidence, rather than hidden by removing validation or serializing tests. Final acceptance below includes the added GUI case.

The first production Release million-row chain passed in 247.132 seconds before the final sealing audit was added: compacted database 396,824,576 bytes, sampled DB/WAL/SHM peak 1,780,121,600 bytes. A second run validates the final code including full/candidate sealing audits. Unlike the isolated adapter, this workload retains real run/ledger/report protocols and two replacement/maintenance cycles. Peaks exclude other SQLite temporary files. Do not compare its absolute bytes with a different prototype fixture or treat one timing run as a real-disk guarantee.

Final acceptance: default concurrent `swift test` reported 244 tests passed in 6.947 seconds (three opt-in workloads skipped), including both missing/wrong-order corruption cases and persisted GUI reset guidance. The original production Release `millionRecordInventory` passed separately in 242.388 seconds with sealing audits enabled:

| Metric | Final production hybrid result |
| --- | ---: |
| Opaque preservation, approximately one million records | 34.104 s |
| Full inventory diff | 10.096 s |
| Cycle 1 / 2 activation | 14.382 / 13.301 s |
| Cycle 1 / 2 cleanup, audit and compaction | 21.232 / 20.833 s |
| Compacted database after either cycle | 396,828,672 bytes |
| Largest sampled DB/WAL/SHM allocation | 1,779,724,288 bytes |
| Post-compaction 32 narrow lookups | 0.0583 s |
| Post-compaction incremental commit | 0.7536 s |

The same production fixture previously recorded a compacted 1,012,027,392-byte schema-5 database: the new final footprint is approximately 60.8% smaller. Historical timings are not a controlled statistical comparison. In particular, post-compaction commit is slower than the previous 0.012-second measurement and opaque copying exceeds the previous 26.89 seconds, although both remain within the established 10-second commit / 120-second opaque budgets. The new layout is a space/performance tradeoff, not a claim that every operation is faster. Full-disk traversal, multi-day real workloads and installed visual acceptance remain outstanding. No native FSEvents trust rule was relaxed and the deferred cursor investigation is still open.

Format lint, `swift build`, LaunchAgent lint and `git diff --check` passed. An explicitly ad-hoc development bundle built successfully; `codesign --verify --deep --strict` passed and its helper dry-run exited 0. This bundle was not installed and does not replace the user's persistent signing identity. Manual and scheduled entry points both preserve the new reset-required error category when opening an old database fails before coordinator setup.

### Installed fresh-baseline rollout (2026-09-29)

The user explicitly authorized deleting old inventory. Removed the dedicated old-format error type, Control category, GUI reset message and manual/scheduled compatibility branches. Retained the generic migration consistency precondition against dropping inventory beneath old checkpoints. A clean concurrent suite passed 243 tests (three opt-in workloads skipped); format, LaunchAgent, diff checks, persistent-signed package verification and helper dry-run passed. Inventory algorithms did not change; the accepted production million-row workload was not repeated.

After confirming the helper was idle, deleted the old runtime database, reports, logs and Control files under stable reset/writer leases, without an inventory backup. Replaced the app at its original install path with the same signing identity; all three executable designated requirements matched. Daily 09:00 registration remains intact. The registered helper started a fresh manual baseline: schema 6, seven hybrid tables, zero inherited checkpoints, one running full scan and increasing initialFull/scanningFiles counters. The new GUI was reopened, but computer-use access was unavailable. Execution was verified through persisted progress and read-only schema inspection. Initial report completion, visual acceptance and subsequent incremental acceptance remain pending; startup is not full end-to-end acceptance.

These installed results supersede the earlier not-installed and compatibility-UI status statements.

### Graphite frontend integration (2026-09-29)

PR #3 supplies the sidebar, theme, trend chart and growth/release bars. Integration keeps its visual design while preserving schema-6 space-maintenance controls, phase-only maintenance progress, cancellation boundaries and maintenance completion feedback. The sole textual conflict was the progress counter block: preserve the maintenance conditional and apply the incoming semibold typography/card styling. No inventory/accounting or database-format change is part of this frontend integration.

The integrated default concurrent suite passed 243 tests in 7.228 seconds (three opt-in workloads skipped). Format, build, LaunchAgent and whitespace checks passed. The million-row storage workload was not repeated because the storage algorithm was unchanged. Visual acceptance remains separate from compilation and automated tests.
