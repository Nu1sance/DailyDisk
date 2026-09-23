-- Delete descendants in sets before SQLite's per-object FK cascades run.
-- Even with an index, SQLite can prefer the generation prefix of the path
-- primary key when it lacks statistics, causing quadratic cleanup.
CREATE TRIGGER inventory_generation_cleanup
BEFORE DELETE ON inventory_generations
BEGIN
    DELETE FROM canonical_attributions WHERE generation_id = OLD.id;
    DELETE FROM inventory_paths WHERE generation_id = OLD.id;
    DELETE FROM inventory_objects WHERE generation_id = OLD.id;
END;
