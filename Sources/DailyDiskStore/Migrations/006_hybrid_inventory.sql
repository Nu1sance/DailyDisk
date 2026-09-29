-- Applied only to an empty inventory. Published migrations 001-005 are unchanged.
DROP TRIGGER inventory_generation_cleanup;
DROP TABLE canonical_attributions;
DROP TABLE inventory_paths;
DROP TABLE inventory_objects;
CREATE TABLE hybrid_volumes (
    id INTEGER PRIMARY KEY CHECK(id > 0),
    external_id TEXT NOT NULL UNIQUE REFERENCES volumes(id) ON DELETE CASCADE
) STRICT;
CREATE TABLE hybrid_generations (
    id INTEGER PRIMARY KEY CHECK(id > 0),
    external_id TEXT NOT NULL UNIQUE REFERENCES inventory_generations(id) ON DELETE CASCADE,
    volume_id INTEGER NOT NULL REFERENCES hybrid_volumes(id),
    UNIQUE(id,volume_id)
) STRICT;
INSERT INTO hybrid_volumes(external_id) SELECT id FROM volumes;
CREATE TRIGGER hybrid_volume_insert AFTER INSERT ON volumes BEGIN
    INSERT INTO hybrid_volumes(external_id) VALUES(NEW.id);
END;
CREATE TRIGGER hybrid_generation_insert AFTER INSERT ON inventory_generations BEGIN
    INSERT INTO hybrid_generations(external_id,volume_id)
      SELECT NEW.id,id FROM hybrid_volumes WHERE external_id=NEW.volume_id;
END;
CREATE TABLE hybrid_nodes (
    id INTEGER PRIMARY KEY CHECK(id > 0),
    parent_id INTEGER REFERENCES hybrid_nodes(id) ON DELETE RESTRICT,
    name BLOB NOT NULL CHECK(instr(name,x'2f')=0 AND instr(name,x'00')=0),
    CHECK(length(name)>0 OR parent_id IS NULL)
) STRICT;
CREATE UNIQUE INDEX hybrid_node_name ON hybrid_nodes(COALESCE(parent_id,0),name);
CREATE INDEX hybrid_node_parent ON hybrid_nodes(parent_id);
CREATE TRIGGER hybrid_node_immutable BEFORE UPDATE ON hybrid_nodes BEGIN
    SELECT RAISE(ABORT,'Hybrid path nodes are immutable');
END;
CREATE TABLE hybrid_objects (
    generation_id INTEGER NOT NULL, volume_id INTEGER NOT NULL,
    device_id INTEGER NOT NULL,inode INTEGER NOT NULL,kind TEXT NOT NULL,
    logical_bytes INTEGER NOT NULL CHECK(logical_bytes>=0),
    allocated_bytes INTEGER NOT NULL CHECK(allocated_bytes>=0),link_count INTEGER NOT NULL,
    modified_at REAL,metadata_changed_at REAL,
    PRIMARY KEY(generation_id,device_id,inode),
    UNIQUE(generation_id,volume_id,device_id,inode),
    FOREIGN KEY(generation_id,volume_id) REFERENCES hybrid_generations(id,volume_id) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;
CREATE TABLE hybrid_paths (
    generation_id INTEGER NOT NULL,volume_id INTEGER NOT NULL,
    path_id INTEGER NOT NULL REFERENCES hybrid_nodes(id) ON DELETE RESTRICT,
    device_id INTEGER NOT NULL,inode INTEGER NOT NULL,
    classification TEXT NOT NULL CHECK(classification IN ('ordinary','dailyDiskInternal')),
    PRIMARY KEY(generation_id,path_id),
    UNIQUE(generation_id,volume_id,path_id,device_id,inode),
    FOREIGN KEY(generation_id,volume_id,device_id,inode)
      REFERENCES hybrid_objects(generation_id,volume_id,device_id,inode) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;
CREATE INDEX hybrid_paths_object ON hybrid_paths(generation_id,device_id,inode,path_id);
CREATE INDEX hybrid_paths_parent_object ON hybrid_paths(generation_id,volume_id,device_id,inode);
CREATE INDEX hybrid_paths_node ON hybrid_paths(path_id);
CREATE TABLE hybrid_order (
    generation_id INTEGER NOT NULL,path BLOB NOT NULL,path_id INTEGER NOT NULL,
    PRIMARY KEY(generation_id,path),UNIQUE(generation_id,path_id),
    FOREIGN KEY(generation_id,path_id) REFERENCES hybrid_paths(generation_id,path_id) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;
CREATE TABLE hybrid_canonical (
    generation_id INTEGER NOT NULL,volume_id INTEGER NOT NULL,device_id INTEGER NOT NULL,inode INTEGER NOT NULL,
    path_id INTEGER NOT NULL,classification TEXT NOT NULL,
    PRIMARY KEY(generation_id,device_id,inode),
    FOREIGN KEY(generation_id,volume_id,path_id,device_id,inode)
      REFERENCES hybrid_paths(generation_id,volume_id,path_id,device_id,inode) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;
CREATE TRIGGER inventory_generation_cleanup BEFORE DELETE ON inventory_generations BEGIN
    DELETE FROM hybrid_canonical WHERE generation_id=(SELECT id FROM hybrid_generations WHERE external_id=OLD.id);
    DELETE FROM hybrid_paths WHERE generation_id=(SELECT id FROM hybrid_generations WHERE external_id=OLD.id);
    DELETE FROM hybrid_objects WHERE generation_id=(SELECT id FROM hybrid_generations WHERE external_id=OLD.id);
END;
-- Read-only projections keep external UUIDs and raw-path semantics stable.
-- Writes target compact tables directly, never per-row INSTEAD OF triggers.
CREATE VIEW inventory_objects AS
    SELECT g.external_id AS generation_id,v.external_id AS volume_id,o.device_id,o.inode,o.kind,
      o.logical_bytes,o.allocated_bytes,o.link_count,o.modified_at,o.metadata_changed_at
    FROM hybrid_generations g JOIN hybrid_objects o ON o.generation_id=g.id
    JOIN hybrid_volumes v ON v.id=o.volume_id;
CREATE VIEW inventory_paths AS
    SELECT g.external_id AS generation_id,v.external_id AS volume_id,d.path,
      CASE WHEN length(d.path)=0 THEN NULL WHEN n.parent_id IS NULL THEN x''
        ELSE substr(d.path,1,length(d.path)-length(n.name)-1) END AS parent_path,
      p.device_id,p.inode,p.classification
    FROM hybrid_generations g JOIN hybrid_order d ON d.generation_id=g.id
    JOIN hybrid_paths p ON p.generation_id=d.generation_id AND p.path_id=d.path_id
    JOIN hybrid_nodes n ON n.id=p.path_id JOIN hybrid_volumes v ON v.id=p.volume_id;
CREATE VIEW canonical_attributions AS
    SELECT g.external_id AS generation_id,v.external_id AS volume_id,c.device_id,c.inode,d.path,c.classification
    FROM hybrid_generations g JOIN hybrid_canonical c ON c.generation_id=g.id
    JOIN hybrid_order d ON d.generation_id=c.generation_id AND d.path_id=c.path_id
    JOIN hybrid_volumes v ON v.id=c.volume_id;
CREATE TRIGGER hybrid_volume_mapping_immutable BEFORE UPDATE ON hybrid_volumes BEGIN
    SELECT RAISE(ABORT,'Hybrid volume keys are immutable');
END;
CREATE TRIGGER hybrid_generation_mapping_immutable BEFORE UPDATE ON hybrid_generations BEGIN
    SELECT RAISE(ABORT,'Hybrid generation keys are immutable');
END;
