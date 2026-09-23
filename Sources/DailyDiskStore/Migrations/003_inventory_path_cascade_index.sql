-- SQLite's foreign-key cascade planner must be able to match all parent key
-- columns in order. The path primary key only narrows by generation, making
-- removal of N inventory objects rescan N paths for every object.
CREATE INDEX inventory_paths_parent_object_idx
    ON inventory_paths(generation_id, volume_id, device_id, inode);
