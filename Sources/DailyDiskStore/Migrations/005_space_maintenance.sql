-- Existing retired rows receive a full recovery window from migration time.
ALTER TABLE inventory_generations ADD COLUMN retired_at REAL;
CREATE INDEX inventory_generations_retirement_idx
    ON inventory_generations(state, retired_at);
CREATE TABLE space_maintenance (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    status TEXT NOT NULL CHECK (status IN ('running', 'completed', 'interrupted', 'failed', 'insufficientSpace')),
    attempted_at REAL NOT NULL,
    completed_at REAL,
    before_bytes INTEGER,
    after_bytes INTEGER,
    last_success_at REAL,
    last_reclaimed_bytes INTEGER
) STRICT;
