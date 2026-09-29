# Database and transaction model

DailyDisk stores its inventory in SQLite under:

```text
~/Library/Application Support/DailyDisk/DailyDisk.sqlite
```

The parent directory is mode `0700`; the database and writer lock are mode `0600`. A nonblocking `flock` on `DailyDisk.sqlite.lock` permits only one inventory writer process. Readers use separate SQLite connections. Strict verification also holds a shared database lease and immutable view. Every reader/writer holds a shared stable reset lease outside the replaceable DailyDisk root, so safe reset can acquire exclusive quiescence without a lock-inode rename race.

## SQLite configuration

- Foreign keys enabled on every connection
- WAL journal mode
- `synchronous = FULL` for acknowledged checkpoint durability
- Extended result codes
- Writer page-cache target: 64 MiB; file-backed temporary cache: 8 MiB
- 5-second busy timeout
- One Swift actor owns the writer connection

The app may replay already delivered FSEvents after a power loss, so inventory operations remain idempotent even with durable commits.

## Schema migration

The current application schema is version 6. First launch prepares the local database and applies bundled migrations automatically; source-build users do not install a database server or run SQL setup scripts. The system SQLite library is linked through `CSQLite`.

`schema_metadata` records every applied migration version and stable name. `PRAGMA user_version` must exactly match the latest contiguous metadata row before any migration runs. DailyDisk rejects:

- a newer database version
- a missing metadata table with nonzero `user_version`
- gaps or duplicate history
- changed migration names
- disagreement between metadata and `user_version`

Migration resources are listed explicitly in `DatabaseMigrator`; filenames are not inferred from a generic pattern. Each schema migration and both version markers commit in one transaction.

## Inventory generations

Each monitored volume has at most one active generation. Full scans write to a staging generation without changing the current checkpoint. On successful reconciliation, one transaction:

1. verifies the previous checkpoint
2. verifies the run owns the staging generation
3. validates the sealed inventory and semantic change ledger
4. applies scan-time overlay mutations
5. installs canonical hard-link attribution
6. retires the prior generation and activates the staging generation
7. inserts changes, storage samples, and snapshot samples
8. updates the exact fenced FSEvent checkpoint
9. marks the run successful

A failure rolls back every item above. The previous active generation and checkpoint remain paired.

Migration 005 records `retired_at` when an active generation is replaced. Existing retired generations receive a fresh 24-hour window at migration time. After the replacement generation has a persisted report, idle helper maintenance retains at most the newest retired generation for 24 hours. Older retired generations can then be removed; the newest can be removed after expiry. Running scans, overlays, staging inventories, pending reports, and checkpoint references block unsafe cleanup. Failed or interrupted scans still remove only their own staging state.

Retired cleanup no longer runs inside the activation transaction. It runs before new work and after successful report publication. If the helper does not run, expiry alone does not wake it. In particular, daily scans started less than 24 hours after retirement may still temporarily hold three generations. Historical reports, ledger rows and samples are retained independently.

## Run-scoped overlays

Incremental mutations are not written directly into active inventory. `run_targets` pins each run to a specific base generation and carries a monotonically increasing revision:

- staging or appending data increments the revision and clears its seal
- canonicalization operates on one revision and seals it
- commit accepts only the exact sealed revision
- staging after canonicalization makes the old result unusable

Object metadata is staged by `(run, target, device, inode)`, independently of paths. Updating one hard-linked path therefore updates the object visible through every link in the overlay. Paths and canonical attribution remain separate.

Streaming canonical and diff callbacks verify the sealed revision after every suspension. Reentrant mutation, failure, recovery, or commit causes the stream to fail instead of returning a partial result as successful.

Canonical output pages use a composite `(device_id, inode)` seek against the primary key. An equivalent disjunction can make SQLite rescan the beginning of the run for every page; the composite bound avoids quadratic work on full inventories. Pagination retains the database's signed identity ordering, including stored UInt64 boundary values.

## Semantic ledger validation

Before advancing a checkpoint, the store derives the expected ledger from the sealed before/after inventory views. It compares a multiset containing:

- object identity
- exact change kind and source
- classification
- before/after paths
- object-transition footprints
- path-only link/move effects
- canonical attribution debit/credit effects

A fabricated creation with the same net bytes as a real modification is rejected. Balanced but unrelated records are also rejected. This is stricter than comparing aggregate byte totals.

The first generation is an opening balance and intentionally has an empty change ledger: no earlier inventory or physical sample exists, so existing files are not reported as new growth. Later validation inserts the supplied semantic multiset into a file-backed SQLite temporary table and consumes it with ordered before/after canonical-object cursors. Reconciliation memory therefore scales with the bounded cursor and actual change set, not with multiple copies of the complete inventory.

## Hard-link integrity

The schema enforces one canonical row per `(generation, device, inode)`. Composite foreign keys tie:

- generations to their volume
- objects and paths to the same generation/volume/identity
- canonical attribution to the same path and identity
- checkpoints to an active generation on the same volume
- run targets and every overlay row to the same volume

This prevents a valid-looking row from referencing another volume's object or generation.

## Reports

Reports are committed idempotently after the scan transaction. `ReportCommit` recomputes accounting from its domain scope, exact ledger, DailyDisk overhead, and physical samples. The store additionally verifies:

- the referenced run succeeded
- the supplied ledger equals the persisted run ledger
- the current sample was persisted by that run
- the previous sample is the latest strictly earlier sample for the domain

An existing byte-different but semantically equal JSON encoding is accepted after decoding; a genuinely different report for the same run/domain is rejected.

## Recovery and cancellation

After the helper obtains the exclusive writer lease, startup recovery marks abandoned `running` scans as interrupted and removes their run targets, path/object/canonical overlays, and unreferenced staging generations. Cooperative GUI cancellation performs the same cleanup transaction for the specific run. Active generations and committed checkpoints are never changed.

Once the progress control plane atomically publishes `committing`, cancellation is closed. Commit-time ledger validation, generation activation, samples, and checkpoint advancement run to completion or roll back as one SQLite transaction. If report publication is interrupted afterward, the request-to-run binding and `latestUnreportedBasis` recover that exact report without launching a duplicate scan.

### Generation cleanup (schema 4)

Migration 003 adds a composite path/object lookup index. Migration 004 adds a generation-delete trigger that removes canonical rows and paths in sets before removing objects. SQLite can otherwise prefer a generation-only lookup even when a more selective index exists; deleting a large failed/staging generation then repeatedly scans its entire path set. The trigger keeps foreign keys and transaction rollback intact, including protection of the active checkpoint. Regression coverage upgrades a v2 schema and cancels a 10,000-record staging generation while preserving the active baseline.

Before full-generation orphan cleanup, the writer refreshes inventory-path statistics with `ANALYZE inventory_paths` and a 1,000-row-per-index analysis limit. Without statistics, SQLite can choose a generation-only scan for foreign-key cascades despite the composite identity index. A populated synthetic regression verifies identity-bounded child lookups. Statistics are SQLite-managed metadata; their refresh does not require a schema migration.

Overlay path queries keep the path table first with `CROSS JOIN` before looking up object metadata. This preserves path-range seeks even when only inventory paths have refreshed statistics. The million-row test also performs 32 narrow incremental subtree removals after activation, with a 10-second lookup budget to detect whole-object rescans.

Incremental commit limits orphan cleanup to the sealed run’s candidate identities (both previous path identities and object mutations). Full-generation cleanup remains available for full scans. The million-row regression commits 32 incremental removals with a 10-second commit budget and verifies remaining object/canonical counts and checkpoint activation.

Incremental orphan cleanup reuses full-scan path statistics. It does not rerun ANALYZE: on the system SQLite, counting a WITHOUT ROWID table can still read its pages despite a bounded index sample.

### Bounded overlay paging and opaque preservation

Full reconciliation pages the base inventory and run overlay independently by raw path bytes before merging at most two bounded candidate pages. Keep subtree bounds, tombstone exclusion, and object-overlay resolution inside the appropriate branch; an outer LIMIT over an unbounded UNION can repeatedly scan/sort the entire remaining inventory. Both opaque preservation and full inventory diff depend on this pager. Mutation paths drive object lookups with CROSS JOIN.

Opaque roots are deduplicated and reduced to disjoint subtrees before reading. Only those path ranges are copied, in transactions of at most 1,024 records. Each transaction invalidates the destination seal before publishing progress; cancellation between batches leaves the active baseline/checkpoint unchanged. Do not skip unreadable history or advance an untrusted FSEvents cursor to avoid a recovery scan.

The cancellable `preservingOpaqueInventory` phase separates history preservation from file traversal. `preservedPaths` and `processedOpaqueRoots` are cumulative, path-free progress counters; missing fields from old progress files decode as zero. Update GUI and helper together and restart the GUI on upgrade because old binaries do not understand the new phase/fields. Temporary identity counters finalize their statements and close SQLite before deleting their private files.


## Space maintenance (schema 5)

The GUI requests `reclaimSpace` through the fixed private Control schema; `DailyDiskAgent` executes it without starting inventory traversal. Normal helper runs also evaluate maintenance before scanning. Both paths hold the existing exclusive writer lease; the stable data lease excludes reset, and native SQLite locking coordinates WAL-aware readers. There is no file replacement or second writer.

Idle maintenance first prunes eligible retired inventory. Automatic compaction requires more than 1,000,000,000 free bytes, a free-page fraction above 25%, and at least seven days since the last attempt. Recording unsuccessful attempts prevents repeated automatic compression attempts on every launch. Manual requests bypass these thresholds, but never the recovery or space checks. Pending reports are recovered by the normal scan workflow before manual maintenance is retried.

Before native `VACUUM`, available filesystem space must cover twice the database logical size plus 1 GB reserve. This is a conservative preflight, not a guarantee against concurrent external disk usage; SQLite failures still roll back. Expired inventory deletion may already have completed when compaction is declined. The maintenance marker records the attempt before compression. Full integrity and foreign-key checks, checkpoint identity comparisons, inventory/ledger/sample counts, and report payload digests bracket compaction. Allocation samples and the last successful reduction are stored separately from report accounting. Native SQLite handles crash rollback; on restart a running/failed maintenance is verified before further work. A resumed manual request reports interruption and requires explicit retry, rather than automatically repeating compression.

Cleanup, compression and verification are non-cancellable once their Control boundary is atomically published. Before that boundary a cancellation is honored. Automatic maintenance returns to normal cancellable scan preparation afterward. Maintenance publishes phases, not fabricated file counters or a percentage. GUI and helper must be upgraded together because old binaries cannot decode the new action, phases, error categories and `maintenanceCompleted` terminal state.

`spaceUsage` is an explicit lightweight settings read: page/freelist pragmas plus allocated blocks of managed files; it does not run `dbstat` or full verification. The normal overview poll does not request these statistics. History and report sampling boundaries remain unchanged. Shrinkage is measured on completion and is not substituted into earlier physical or overhead samples.

## Storage layout experiments (not a migration)

`Tests/DailyDiskPerformanceTests/StorageLayoutPrototype.swift` implements five isolated hot-inventory layouts: UUID keys with raw paths, integer generation/volume keys with raw paths, integer keys with a shared raw-path dictionary, parent/name nodes, and parent/name nodes with a generation-local full-path ordering table. These fixtures retain object metadata, path classification, canonical attribution, composite identity constraints and ordered generation cleanup. Their minimal catalogs/checkpoint and overlay-reference table are experimental scaffolding, not replacements for production run overlays, revision seals, reports or trusted event fences. That experiment used application schema 5; the production integration below supersedes this historical status.

The dictionary stores raw BLOB paths and stable integer IDs, with parent IDs and explicit indexes for membership, identity and garbage-collection lookups. Its UNIQUE path index also stores path bytes, so logical deduplication does not mean that SQLite stores each path physically just once. In the shared-full-path candidate, parent paths are stored as complete dictionary entries. The separate tree candidates instead store raw BLOB names and parent IDs with a unique expression index on (COALESCE(parent_id,0),name); generated IDs are positive and zero denotes the absent parent for uniqueness. Generation members carry identity/classification separately so a new generation cannot alter an old view through a shared dictionary row.

The first candidate orders subtree pages through the global dictionary and probes membership for a selected generation. Its plan can show only indexed SEARCH operations yet still examine every dictionary path in the range before finding a sparse generation's first page. A deterministic VM-step regression makes this limitation visible. Such a pager is not suitable for production merely because it saves space or returns a bounded number of rows. A production dictionary design needs generation-local ordered access without repeatedly storing full keys or scanning unrelated generations.

Experimental GC scans dictionary IDs in bounded primary-key batches, checks member/overlay/child references and repeats passes for newly unreferenced ancestors. Full production overlay integration, cooperative cancellation, migration preflight and interruption recovery remain separate implementation gates. No 006 migration or installed-data conversion is introduced by these experiments.

The pure tree candidate reconstructs paths upward from the selected generation's members with a recursive CTE. Concatenations are explicitly cast back to BLOB, preserving non-UTF-8 bytes and byte ordering. This avoids unrelated-generation work, but reconstructs the selected generation before range filtering/sorting and LIMIT. Its negative scaling test must remain: returned page size alone does not bound query work. Canonical selection reconstructs paths and orders aliases by raw bytes.

The hybrid tree candidate adds a WITHOUT ROWID path_order table, keyed by (generation_id,path), with UNIQUE(generation_id,path_id) and a composite FK to membership. Its full paths and secondary-index copies are included in measurements. Page queries seek the generation/path range and then look up membership/object identity; canonical selection uses the same path ordering. This is explicitly a hybrid, not evidence that pure parent/name storage provides fast raw-path paging for free.

Both tree candidates intern immutable path components: directory renames insert a new ancestor chain/membership rather than changing the view of retained generations. Nodes are paths, not inodes; hard-link identity remains in object tables. Cache lifetime is one bounded input batch (including ancestors). A synthetic 80-level tree, wide siblings, absolute paths, non-UTF-8 names, reversed insertion and whole-directory renames exercise reconstruction and generation isolation. Ancestor GC can require multiple passes proportional to orphan depth; full runtime overlay/cancellation and migration gates still apply.

The first hybrid seal experiment exposed a planner regression: an ordinary JOIN could drive the correlated alias query from the generation-only path_order range to avoid sorting, repeatedly scanning that range for each object. The corrected candidate uses CROSS JOIN to keep identity-bounded inventory_paths candidates first, then probes UNIQUE(generation_id,path_id); sorting is limited to an object's aliases. A dedicated EXPLAIN regression checks both bounds. This fix belongs to the test prototype only.

### Hybrid operational validation adapter (test-only)

HybridTreeExperiment exercises the candidate through raw-byte, run/generation-scoped mutation and object overlays. Base and mutation branches each apply range bounds and LIMIT before their ordered merge. Object metadata overlays affect all surviving aliases, while classification stays attached to a path. Raw overlay paths do not intern dictionary nodes until commit, so uncommitted inserts do not require node-reference GC pins in this adapter.

Candidate commit collects previous path identities and mutated object identities, removes/reinserts changed memberships and ordering rows, applies object metadata, deletes only candidate orphans, and recomputes only candidate canonical attributions before updating the checkpoint. The test hook throws immediately before checkpoint publication to verify transaction rollback; inactive-generation updates are rejected. This is not a production ScanCommit: run revision seals, trusted FSEvents fences, accounting ledger, recovery references and reports still need integration.

Explicit auditTreeOrder diagnostics page members in batches of 512 and reconstruct reachable ancestors iteratively, with a per-batch cache and cycle detection. The order-to-membership FK alone does not prove that every member has an ordering row, that its raw path matches its node chain, or that a node has no cycle. Corruption tests demonstrate that these faults can pass foreign_key_check. A production migration/seal needs completeness and path-equivalence validation, immutable node updates and transactional maintenance of the redundant ordering table; FK success is insufficient. The full audit must not run in ordinary GUI polling or on every incremental commit.

Opaque-copy experiments reduce roots to disjoint raw-byte subtrees and copy at most 1,024 records per transaction. The empty relative path denotes the whole volume. An injected interruption leaves partial staging batches, preserving the active checkpoint; later staging deletion and node GC preserve the baseline. The diff helper merges two independent 512-row cursors and emits changed record pairs without collecting an inventory-sized result. These helpers validate storage access patterns, not filesystem permission discovery or production cancellation delivery.

## Production hybrid inventory (schema 6, 2026-09-29)

Migration 006 replaces the three physical inventory tables with `hybrid_objects`, `hybrid_paths`, `hybrid_canonical`, immutable `hybrid_nodes`, and `hybrid_order`. Integer volume/generation mappings retain external UUIDs. The old inventory names are read-only views, preserving raw BLOB path and identity semantics for accounting, overlays, reports and inspection. Production writes use reused prepared statements directly against compact tables. The generation-local ordering table preserves bounded raw-path seeks without reconstructing the complete tree for each page.

Full generation sealing validates ordering completeness and exact node/path equivalence; incremental sealing checks affected baseline identities only. Explicit verification and maintenance audit all retained generations. SQLite foreign keys alone cannot detect a missing ordering row. Nodes and mappings reject updates; rename creates new nodes. Idle cleanup uses a leaf queue in batches of 1,024, rechecks references and queues only removed nodes' parents. Run overlays retain raw paths and do not hold node IDs. Full scans retain bounded path statistics; incremental orphan removal remains candidate-scoped.

This internal-beta release uses a fresh baseline and has no old-inventory conversion or compatibility UI. Empty databases initialize normally. A generic migration precondition prevents destructive inventory replacement beneath old generations/checkpoints. Published migrations 001–005 remain unchanged; an empty new inventory must never inherit an old checkpoint.

The transactional scan, revision seal, ledger, report recovery and checkpoint protocols remain in place. This reduces persistent inventory duplication; WAL, staging generations, overlays, retained recovery generations and native VACUUM still need temporary disk space. See Testing for measured production-chain costs, not a guaranteed real-disk scan duration.

### Installed transition update (2026-09-29)

The user authorized deletion of old inventory and installation with a fresh baseline. The dedicated `InventoryFormatError`, `baselineResetRequired` Control category, GUI message and manual/scheduled compatibility branches have been removed. Earlier reset-prompt descriptions are historical. No conversion or old-checkpoint reuse is implemented. The migration retains only its generic empty-database consistency precondition to prevent destructive table replacement beneath an existing checkpoint.
