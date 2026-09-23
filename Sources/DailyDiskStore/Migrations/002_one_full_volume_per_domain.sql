-- Normalize any pre-constraint duplicate selections deterministically. A later
-- topology registration promotes the currently selected live volume again.
UPDATE volumes
SET inventory_mode = 'metricsOnly',
    supports_persistent_events = 0,
    event_store_uuid = NULL
WHERE inventory_mode = 'full'
  AND id NOT IN (
      SELECT MIN(id)
      FROM volumes
      WHERE inventory_mode = 'full'
      GROUP BY storage_domain_id
  );

CREATE UNIQUE INDEX one_full_volume_per_domain
    ON volumes(storage_domain_id)
    WHERE inventory_mode = 'full';
