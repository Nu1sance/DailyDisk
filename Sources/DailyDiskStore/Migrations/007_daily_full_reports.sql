-- Existing payloads keep their original accounting meaning. Old publication
-- times are unavailable; generated_at is the historical approximation only.
ALTER TABLE daily_reports ADD COLUMN snapshot_compared_delta INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_reports ADD COLUMN published_at REAL;
UPDATE daily_reports SET published_at = generated_at;
CREATE INDEX daily_reports_publication_idx ON daily_reports(storage_domain_id, published_at DESC);

-- Unlike finished_at (the sample/proposed-commit time), new completion markers
-- are written only AFTER the inventory transaction has actually committed.
ALTER TABLE scan_runs ADD COLUMN inventory_completed_at REAL;
UPDATE scan_runs SET inventory_completed_at = finished_at
WHERE kind IN ('full','recovery') AND status = 'succeeded';
