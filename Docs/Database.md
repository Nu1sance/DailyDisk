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

The current application schema is version 4. First launch prepares the local database and applies bundled migrations automatically; source-build users do not install a database server or run SQL setup scripts. The system SQLite library is linked through `CSQLite`.

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

The immediately previous retired generation is retained as a short recovery window. Older retired generations and unused staging generations are deleted after successful activation.

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

Before full-generation orphan cleanup, the writer refreshes inventory-path statistics with `ANALYZE inventory_paths` and a 1,000-row-per-index analysis limit. Without statistics, SQLite can choose a generation-only scan for foreign-key cascades despite the composite identity index. A populated synthetic regression verifies identity-bounded child lookups. Statistics are SQLite-managed metadata; the application schema remains version 4.

Overlay path queries keep the path table first with `CROSS JOIN` before looking up object metadata. This preserves path-range seeks even when only inventory paths have refreshed statistics. The million-row test also performs 32 narrow incremental subtree removals after activation, with a 10-second lookup budget to detect whole-object rescans.

Incremental commit limits orphan cleanup to the sealed run’s candidate identities (both previous path identities and object mutations). Full-generation cleanup remains available for full scans. The million-row regression commits 32 incremental removals with a 10-second commit budget and verifies remaining object/canonical counts and checkpoint activation.

Incremental orphan cleanup reuses full-scan path statistics. It does not rerun ANALYZE: on the system SQLite, counting a WITHOUT ROWID table can still read its pages despite a bounded index sample.
