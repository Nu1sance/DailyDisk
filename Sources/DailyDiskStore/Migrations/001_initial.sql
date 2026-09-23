CREATE TABLE storage_domains (
    id TEXT PRIMARY KEY NOT NULL,
    container_identifier TEXT NOT NULL,
    display_name TEXT NOT NULL,
    is_internal INTEGER NOT NULL CHECK (is_internal IN (0, 1))
) STRICT;

CREATE TABLE volumes (
    id TEXT PRIMARY KEY NOT NULL,
    storage_domain_id TEXT NOT NULL REFERENCES storage_domains(id) ON DELETE CASCADE,
    filesystem_uuid TEXT,
    volume_group_uuid TEXT,
    event_store_uuid TEXT,
    device_id INTEGER NOT NULL,
    mount_path TEXT,
    display_name TEXT NOT NULL,
    role TEXT NOT NULL,
    is_internal INTEGER NOT NULL CHECK (is_internal IN (0, 1)),
    is_removable INTEGER NOT NULL CHECK (is_removable IN (0, 1)),
    is_read_only INTEGER NOT NULL CHECK (is_read_only IN (0, 1)),
    supports_persistent_events INTEGER NOT NULL CHECK (supports_persistent_events IN (0, 1)),
    topology_fingerprint TEXT NOT NULL,
    inventory_mode TEXT NOT NULL CHECK (inventory_mode IN ('full', 'metricsOnly'))
) STRICT;
CREATE INDEX volumes_domain_idx ON volumes(storage_domain_id);

CREATE TABLE scan_runs (
    id TEXT PRIMARY KEY NOT NULL,
    kind TEXT NOT NULL,
    reason TEXT NOT NULL,
    status TEXT NOT NULL,
    started_at REAL NOT NULL,
    finished_at REAL,
    error_count INTEGER NOT NULL DEFAULT 0 CHECK (error_count >= 0)
) STRICT;
CREATE INDEX scan_runs_started_idx ON scan_runs(started_at DESC);

CREATE TABLE scan_summaries (
    run_id TEXT PRIMARY KEY NOT NULL REFERENCES scan_runs(id) ON DELETE CASCADE,
    visited_path_count INTEGER NOT NULL,
    indexed_object_count INTEGER NOT NULL,
    unreadable_path_count INTEGER NOT NULL,
    transient_error_count INTEGER NOT NULL
) STRICT, WITHOUT ROWID;

CREATE TABLE inventory_generations (
    id TEXT PRIMARY KEY NOT NULL,
    volume_id TEXT NOT NULL REFERENCES volumes(id) ON DELETE CASCADE,
    created_by_run_id TEXT NOT NULL REFERENCES scan_runs(id) ON DELETE RESTRICT,
    state TEXT NOT NULL CHECK (state IN ('staging', 'active', 'retired')),
    created_at REAL NOT NULL,
    UNIQUE (id, volume_id)
) STRICT;
CREATE UNIQUE INDEX one_active_generation_per_volume
    ON inventory_generations(volume_id) WHERE state = 'active';
CREATE INDEX inventory_generations_run_idx ON inventory_generations(created_by_run_id);

CREATE TABLE inventory_objects (
    generation_id TEXT NOT NULL REFERENCES inventory_generations(id) ON DELETE CASCADE,
    volume_id TEXT NOT NULL REFERENCES volumes(id) ON DELETE CASCADE,
    device_id INTEGER NOT NULL,
    inode INTEGER NOT NULL,
    kind TEXT NOT NULL,
    logical_bytes INTEGER NOT NULL CHECK (logical_bytes >= 0),
    allocated_bytes INTEGER NOT NULL CHECK (allocated_bytes >= 0),
    link_count INTEGER NOT NULL,
    modified_at REAL,
    metadata_changed_at REAL,
    PRIMARY KEY (generation_id, device_id, inode),
    UNIQUE (generation_id, volume_id, device_id, inode),
    FOREIGN KEY (generation_id, volume_id)
        REFERENCES inventory_generations(id, volume_id) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;

CREATE TABLE inventory_paths (
    generation_id TEXT NOT NULL,
    volume_id TEXT NOT NULL REFERENCES volumes(id) ON DELETE CASCADE,
    path BLOB NOT NULL,
    parent_path BLOB,
    device_id INTEGER NOT NULL,
    inode INTEGER NOT NULL,
    classification TEXT NOT NULL CHECK (classification IN ('ordinary', 'dailyDiskInternal')),
    PRIMARY KEY (generation_id, path),
    UNIQUE (generation_id, volume_id, path, device_id, inode),
    FOREIGN KEY (generation_id, volume_id, device_id, inode)
        REFERENCES inventory_objects(generation_id, volume_id, device_id, inode) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;
CREATE INDEX inventory_paths_object_idx
    ON inventory_paths(generation_id, device_id, inode, path);

CREATE TABLE canonical_attributions (
    generation_id TEXT NOT NULL REFERENCES inventory_generations(id) ON DELETE CASCADE,
    volume_id TEXT NOT NULL REFERENCES volumes(id) ON DELETE CASCADE,
    device_id INTEGER NOT NULL,
    inode INTEGER NOT NULL,
    path BLOB NOT NULL,
    classification TEXT NOT NULL CHECK (classification IN ('ordinary', 'dailyDiskInternal')),
    PRIMARY KEY (generation_id, device_id, inode),
    FOREIGN KEY (generation_id, volume_id, path, device_id, inode)
        REFERENCES inventory_paths(generation_id, volume_id, path, device_id, inode) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;

CREATE TABLE checkpoints (
    volume_id TEXT PRIMARY KEY NOT NULL REFERENCES volumes(id) ON DELETE CASCADE,
    event_store_uuid TEXT,
    last_committed_event_id INTEGER,
    active_generation_id TEXT NOT NULL,
    topology_fingerprint TEXT NOT NULL,
    last_successful_incremental_at REAL,
    last_successful_full_scan_at REAL NOT NULL,
    FOREIGN KEY (active_generation_id, volume_id)
        REFERENCES inventory_generations(id, volume_id) ON DELETE RESTRICT
) STRICT;

CREATE TABLE run_targets (
    run_id TEXT NOT NULL REFERENCES scan_runs(id) ON DELETE CASCADE,
    target_kind TEXT NOT NULL CHECK (target_kind IN ('active', 'generation')),
    target_id TEXT NOT NULL,
    volume_id TEXT NOT NULL REFERENCES volumes(id) ON DELETE CASCADE,
    base_generation_id TEXT NOT NULL,
    revision INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0),
    sealed_revision INTEGER,
    PRIMARY KEY (run_id, target_kind, target_id),
    UNIQUE (run_id, target_kind, target_id, volume_id),
    FOREIGN KEY (base_generation_id, volume_id)
        REFERENCES inventory_generations(id, volume_id) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;

CREATE TABLE run_object_mutations (
    run_id TEXT NOT NULL,
    target_kind TEXT NOT NULL,
    target_id TEXT NOT NULL,
    volume_id TEXT NOT NULL REFERENCES volumes(id) ON DELETE CASCADE,
    device_id INTEGER NOT NULL,
    inode INTEGER NOT NULL,
    kind TEXT NOT NULL,
    logical_bytes INTEGER NOT NULL CHECK (logical_bytes >= 0),
    allocated_bytes INTEGER NOT NULL CHECK (allocated_bytes >= 0),
    link_count INTEGER NOT NULL,
    modified_at REAL,
    metadata_changed_at REAL,
    PRIMARY KEY (run_id, target_kind, target_id, device_id, inode),
    FOREIGN KEY (run_id, target_kind, target_id, volume_id)
        REFERENCES run_targets(run_id, target_kind, target_id, volume_id) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;

CREATE TABLE run_mutations (
    run_id TEXT NOT NULL REFERENCES scan_runs(id) ON DELETE CASCADE,
    target_kind TEXT NOT NULL CHECK (target_kind IN ('active', 'generation')),
    target_id TEXT NOT NULL,
    volume_id TEXT NOT NULL REFERENCES volumes(id) ON DELETE CASCADE,
    path BLOB NOT NULL,
    operation TEXT NOT NULL CHECK (operation IN ('upsert', 'remove')),
    parent_path BLOB,
    device_id INTEGER,
    inode INTEGER,
    kind TEXT,
    logical_bytes INTEGER CHECK (logical_bytes IS NULL OR logical_bytes >= 0),
    allocated_bytes INTEGER CHECK (allocated_bytes IS NULL OR allocated_bytes >= 0),
    link_count INTEGER,
    modified_at REAL,
    metadata_changed_at REAL,
    classification TEXT CHECK (classification IS NULL OR classification IN ('ordinary', 'dailyDiskInternal')),
    PRIMARY KEY (run_id, target_kind, target_id, path),
    FOREIGN KEY (run_id, target_kind, target_id, volume_id)
        REFERENCES run_targets(run_id, target_kind, target_id, volume_id) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;
CREATE INDEX run_mutations_target_idx ON run_mutations(run_id, target_kind, target_id);
CREATE INDEX run_mutations_target_object_path_idx
    ON run_mutations(run_id, target_kind, target_id, device_id, inode, path)
    WHERE operation = 'upsert';

CREATE TABLE run_canonical_attributions (
    run_id TEXT NOT NULL REFERENCES scan_runs(id) ON DELETE CASCADE,
    target_kind TEXT NOT NULL CHECK (target_kind IN ('active', 'generation')),
    target_id TEXT NOT NULL,
    volume_id TEXT NOT NULL REFERENCES volumes(id) ON DELETE CASCADE,
    device_id INTEGER NOT NULL,
    inode INTEGER NOT NULL,
    path BLOB NOT NULL,
    classification TEXT NOT NULL CHECK (classification IN ('ordinary', 'dailyDiskInternal')),
    PRIMARY KEY (run_id, target_kind, target_id, device_id, inode),
    FOREIGN KEY (run_id, target_kind, target_id, volume_id)
        REFERENCES run_targets(run_id, target_kind, target_id, volume_id) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;

CREATE TABLE change_ledger (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT NOT NULL REFERENCES scan_runs(id) ON DELETE CASCADE,
    volume_id TEXT NOT NULL REFERENCES volumes(id) ON DELETE CASCADE,
    kind TEXT NOT NULL,
    source TEXT NOT NULL,
    transfer_id TEXT,
    path_before BLOB,
    path_after BLOB,
    logical_delta INTEGER NOT NULL,
    allocated_delta INTEGER NOT NULL,
    classification TEXT NOT NULL,
    payload_json BLOB NOT NULL
) STRICT;
CREATE INDEX change_ledger_run_idx ON change_ledger(run_id, sequence);
CREATE INDEX change_ledger_volume_idx ON change_ledger(volume_id, sequence);

CREATE TABLE storage_samples (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT NOT NULL REFERENCES scan_runs(id) ON DELETE CASCADE,
    storage_domain_id TEXT NOT NULL REFERENCES storage_domains(id) ON DELETE CASCADE,
    sampled_at REAL NOT NULL,
    capacity_bytes INTEGER NOT NULL CHECK (capacity_bytes >= 0),
    used_bytes INTEGER NOT NULL CHECK (used_bytes >= 0),
    available_bytes INTEGER NOT NULL CHECK (available_bytes >= 0),
    important_available_bytes INTEGER,
    opportunistic_available_bytes INTEGER,
    UNIQUE (run_id, storage_domain_id, sampled_at)
) STRICT;
CREATE INDEX storage_samples_domain_time_idx
    ON storage_samples(storage_domain_id, sampled_at DESC);

CREATE TABLE overhead_samples (
    run_id TEXT PRIMARY KEY NOT NULL REFERENCES scan_runs(id) ON DELETE CASCADE,
    storage_domain_id TEXT NOT NULL REFERENCES storage_domains(id) ON DELETE CASCADE,
    sampled_at REAL NOT NULL,
    allocated_bytes INTEGER NOT NULL CHECK (allocated_bytes >= 0)
) STRICT, WITHOUT ROWID;
CREATE INDEX overhead_samples_domain_time_idx
    ON overhead_samples(storage_domain_id, sampled_at DESC);

CREATE TABLE snapshot_observations (
    run_id TEXT NOT NULL REFERENCES scan_runs(id) ON DELETE CASCADE,
    volume_id TEXT NOT NULL REFERENCES volumes(id) ON DELETE CASCADE,
    observed_at REAL NOT NULL,
    PRIMARY KEY (run_id, volume_id)
) STRICT, WITHOUT ROWID;
CREATE INDEX snapshot_observations_volume_time_idx
    ON snapshot_observations(volume_id, observed_at DESC);

CREATE TABLE snapshot_samples (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT NOT NULL REFERENCES scan_runs(id) ON DELETE CASCADE,
    volume_id TEXT NOT NULL REFERENCES volumes(id) ON DELETE CASCADE,
    sampled_at REAL NOT NULL,
    snapshot_uuid TEXT,
    name TEXT NOT NULL,
    created_at REAL,
    is_purgeable INTEGER,
    allocated_bytes_estimate INTEGER CHECK (allocated_bytes_estimate IS NULL OR allocated_bytes_estimate >= 0)
) STRICT;
CREATE INDEX snapshot_samples_volume_time_idx
    ON snapshot_samples(volume_id, sampled_at DESC);

CREATE TABLE daily_reports (
    run_id TEXT NOT NULL REFERENCES scan_runs(id) ON DELETE CASCADE,
    storage_domain_id TEXT NOT NULL REFERENCES storage_domains(id) ON DELETE CASCADE,
    generated_at REAL NOT NULL,
    event_attributed_delta INTEGER NOT NULL,
    reconciliation_correction INTEGER NOT NULL,
    reconciled_indexed_delta INTEGER NOT NULL,
    dailydisk_overhead_delta INTEGER NOT NULL,
    physical_used_delta INTEGER,
    physical_unattributed_delta INTEGER,
    payload_json BLOB NOT NULL,
    PRIMARY KEY (run_id, storage_domain_id)
) STRICT, WITHOUT ROWID;
CREATE INDEX daily_reports_domain_time_idx
    ON daily_reports(storage_domain_id, generated_at DESC);

CREATE TABLE scan_errors (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT NOT NULL REFERENCES scan_runs(id) ON DELETE CASCADE,
    volume_id TEXT REFERENCES volumes(id) ON DELETE CASCADE,
    kind TEXT NOT NULL,
    path BLOB,
    error_code INTEGER,
    message TEXT NOT NULL
) STRICT;
CREATE INDEX scan_errors_run_idx ON scan_errors(run_id, id);

CREATE TABLE settings (
    key TEXT PRIMARY KEY NOT NULL,
    value BLOB NOT NULL,
    updated_at REAL NOT NULL
) STRICT, WITHOUT ROWID;
