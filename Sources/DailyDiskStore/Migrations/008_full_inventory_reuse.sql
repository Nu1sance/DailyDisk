-- W6 keeps the current compact inventory and journals only old values of changed keys.
-- Existing inventories, checkpoints and historical reports are preserved.
CREATE TABLE inventory_reuse_history (
    version INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT NOT NULL UNIQUE REFERENCES scan_runs(id),
    generation_id TEXT NOT NULL REFERENCES inventory_generations(id) ON DELETE RESTRICT,
    retired_at REAL NOT NULL,
    checkpoint BLOB NOT NULL
) STRICT;
CREATE TABLE inventory_reuse_old_objects (
    run_id TEXT NOT NULL REFERENCES inventory_reuse_history(run_id) ON DELETE CASCADE,
    device_id INTEGER NOT NULL, inode INTEGER NOT NULL,
    kind TEXT, logical_bytes INTEGER, allocated_bytes INTEGER, link_count INTEGER,
    modified_at REAL, metadata_changed_at REAL,
    PRIMARY KEY(run_id,device_id,inode)
) STRICT, WITHOUT ROWID;
CREATE TABLE inventory_reuse_old_paths (
    run_id TEXT NOT NULL REFERENCES inventory_reuse_history(run_id) ON DELETE CASCADE,
    path BLOB NOT NULL, device_id INTEGER, inode INTEGER, classification TEXT,
    PRIMARY KEY(run_id,path)
) STRICT, WITHOUT ROWID;
