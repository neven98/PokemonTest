extends Node

signal db_ready()
signal import_progress(msg: String, done: int, total: int, inserted: int, updated: int, skipped: int, errors: int)
signal import_finished(status: String, inserted: int, updated: int, skipped: int, errors: int, total: int)

@export var db_path: String = "user://poke/poke.sqlite"
@export var cache_root: String = ""  # vide => auto depuis PokeCacheSync

var _db = null
var _is_ready := false

func _ready() -> void:
	_ensure_dir(db_path.get_base_dir())

	if cache_root.is_empty():
		var sync := get_node_or_null("/root/PokeCacheSync")
		if sync != null:
			cache_root = sync.cache_root

	if not _open_db():
		push_error("[PokeDb] Impossible d'ouvrir la DB. Plugin SQLite activé ?")
		return

	_apply_migrations()

	_is_ready = true
	emit_signal("db_ready")

func is_ready() -> bool:
	return _is_ready

# -----------------------
# Open + SQL helpers
# -----------------------

func _open_db() -> bool:
	if not ClassDB.class_exists("SQLite"):
		push_error("[PokeDb] Classe SQLite introuvable (plugin non activé ?).")
		return false

	_db = SQLite.new()
	_db.path = db_path
	_db.verbosity_level = 0  # mets 0 quand tout est stable

	var ok: bool = _db.open_db()
	if not ok:
		push_error("[PokeDb] open_db() a échoué: %s" % String(_db.error_message))
		return false

	return true

func _exec(sql: String) -> bool:
	if _db == null:
		return false
	var ok: bool = _db.query(sql)
	if not ok:
		push_error("[PokeDb] SQL error: %s\nSQL=%s" % [String(_db.error_message), sql])
	return ok

func _query(sql: String) -> Array:
	if _db == null:
		return []
	var ok: bool = _db.query(sql)
	if not ok:
		push_error("[PokeDb] SQL error: %s\nSQL=%s" % [String(_db.error_message), sql])
		return []
	return _db.query_result

func _exec_bind(sql: String, bindings: Array) -> bool:
	if _db == null:
		return false
	var ok: bool = _db.query_with_bindings(sql, bindings)
	if not ok:
		push_error("[PokeDb] SQL bind error: %s\nSQL=%s\nBIND=%s" % [
			String(_db.error_message), sql, JSON.stringify(bindings)
		])
	return ok

func _query_bind(sql: String, bindings: Array) -> Array:
	if _db == null:
		return []
	var ok: bool = _db.query_with_bindings(sql, bindings)
	if not ok:
		push_error("[PokeDb] SQL bind error: %s\nSQL=%s\nBIND=%s" % [
			String(_db.error_message), sql, JSON.stringify(bindings)
		])
		return []
	return _db.query_result

# -----------------------
# Migrations (schema v2)
# -----------------------

func _apply_migrations() -> void:
	_exec("PRAGMA journal_mode=WAL;")
	_exec("PRAGMA synchronous=NORMAL;")

	# tables de base
	_exec("""
	CREATE TABLE IF NOT EXISTS meta(
		key TEXT PRIMARY KEY,
		value TEXT NOT NULL
	);
	""")

	_exec("""
	CREATE TABLE IF NOT EXISTS resource_manifest(
		resource TEXT PRIMARY KEY,
		count INTEGER,
		max_id INTEGER,
		sample_hash TEXT,
		last_sync_utc TEXT
	);
	""")

	# version actuelle
	var v := _get_schema_version()
	if v < 1:
		_set_schema_version(1)
		v = 1

	# --- v1/v2 : entities + hash ---
	_exec("""
	CREATE TABLE IF NOT EXISTS entities(
		resource TEXT NOT NULL,
		id INTEGER NOT NULL,
		name TEXT,
		json TEXT NOT NULL,
		hash TEXT,
		saved_utc TEXT NOT NULL,
		PRIMARY KEY(resource, id)
	);
	""")

	_exec("CREATE INDEX IF NOT EXISTS idx_entities_resource_name ON entities(resource, name);")
	_exec("CREATE INDEX IF NOT EXISTS idx_entities_resource_hash ON entities(resource, hash);")

	# Migration v1 -> v2 : ajouter colonne hash si elle n'existe pas
	if v < 2:
		if not _column_exists("entities", "hash"):
			_exec("ALTER TABLE entities ADD COLUMN hash TEXT;")
		_exec("CREATE INDEX IF NOT EXISTS idx_entities_resource_hash ON entities(resource, hash);")

		_set_schema_version(2)
		v = 2

	# --- v3 : import_state + tables relations Pokemon ---
	if v < 3:
		_exec("""
		CREATE TABLE IF NOT EXISTS import_state(
			resource TEXT PRIMARY KEY,
			cursor INTEGER NOT NULL DEFAULT 0,
			updated_utc TEXT NOT NULL
		);
		""")

		_exec("""
		CREATE TABLE IF NOT EXISTS dex_pokemon_type(
			pokemon_id INTEGER NOT NULL,
			slot INTEGER NOT NULL,
			type_id INTEGER NOT NULL,
			PRIMARY KEY(pokemon_id, slot)
		);
		""")

		_exec("""
		CREATE TABLE IF NOT EXISTS dex_pokemon_stat(
			pokemon_id INTEGER NOT NULL,
			stat_id INTEGER NOT NULL,
			base_stat INTEGER NOT NULL,
			effort INTEGER NOT NULL,
			PRIMARY KEY(pokemon_id, stat_id)
		);
		""")

		_exec("""
		CREATE TABLE IF NOT EXISTS dex_pokemon_ability(
			pokemon_id INTEGER NOT NULL,
			slot INTEGER NOT NULL,
			ability_id INTEGER NOT NULL,
			is_hidden INTEGER NOT NULL,
			PRIMARY KEY(pokemon_id, slot)
		);
		""")

		_exec("""
		CREATE TABLE IF NOT EXISTS dex_pokemon_move(
			pokemon_id INTEGER NOT NULL,
			move_id INTEGER NOT NULL,
			version_group_id INTEGER NOT NULL,
			move_learn_method_id INTEGER NOT NULL,
			level INTEGER NOT NULL,
			order_no INTEGER,
			mastery INTEGER,
			PRIMARY KEY(pokemon_id, move_id, version_group_id, move_learn_method_id, level)
		);
		""")

		_exec("CREATE INDEX IF NOT EXISTS idx_dex_pm_pokemon ON dex_pokemon_move(pokemon_id);")
		_exec("CREATE INDEX IF NOT EXISTS idx_dex_pm_vg ON dex_pokemon_move(version_group_id);")
		_exec("CREATE INDEX IF NOT EXISTS idx_dex_pm_move ON dex_pokemon_move(move_id);")
		_set_schema_version(3)
		v = 3
	if v < 4:
		_exec("""
		CREATE TABLE IF NOT EXISTS dex_pokedex_number(
			pokedex_id INTEGER NOT NULL,
			pokemon_species_id INTEGER NOT NULL,
			pokedex_number INTEGER NOT NULL,
			PRIMARY KEY(pokedex_id, pokemon_species_id)
		);
		""")

		_exec("CREATE INDEX IF NOT EXISTS idx_dex_pokedex_number_pokedex ON dex_pokedex_number(pokedex_id, pokedex_number);")

		_set_schema_version(4)
		v = 4

func upsert_pokedex_number(obj: Dictionary) -> Dictionary:
	var pokedex_id := _i(obj.get("pokedex_id", null))
	var species_id := _i(obj.get("pokemon_species_id", null))
	var number := _i(obj.get("pokedex_number", null))
	if pokedex_id <= 0 or species_id <= 0 or number <= 0:
		return {"inserted": 0, "updated": 0, "skipped": 0, "errors": 1}

	_exec_bind(
		"INSERT INTO dex_pokedex_number(pokedex_id,pokemon_species_id,pokedex_number) VALUES(?,?,?) "
		+ "ON CONFLICT(pokedex_id,pokemon_species_id) DO UPDATE SET pokedex_number=excluded.pokedex_number;",
		[pokedex_id, species_id, number]
	)
	return {"inserted": 1, "updated": 0, "skipped": 0, "errors": 0}

func pokedex_number_count(pokedex_id: int) -> int:
	var rows := _query_bind("SELECT COUNT(*) AS c FROM dex_pokedex_number WHERE pokedex_id=?;", [pokedex_id])
	if rows.size() == 0:
		return 0
	return int((rows[0] as Dictionary).get("c", 0))

func _get_schema_version() -> int:
	var rows := _query_bind("SELECT value FROM meta WHERE key=? LIMIT 1;", ["schema_version"])
	if rows.size() == 0:
		return 0
	var v := String((rows[0] as Dictionary).values()[0])
	return int(v)

func _set_schema_version(v: int) -> void:
	_exec_bind("""
	INSERT INTO meta(key,value) VALUES(?,?)
	ON CONFLICT(key) DO UPDATE SET value=excluded.value;
	""", ["schema_version", str(v)])

func _column_exists(table: String, column: String) -> bool:
	var rows := _query("PRAGMA table_info(%s);" % table)
	for r in rows:
		if typeof(r) == TYPE_DICTIONARY:
			var d := r as Dictionary
			# PRAGMA table_info -> "name"
			if String(d.get("name", "")) == column:
				return true
	return false

func _table_exists(table: String) -> bool:
	var rows := _query("SELECT name FROM sqlite_master WHERE type='table' AND name='%s' LIMIT 1;" % table)
	return rows.size() > 0
# -----------------------
# Hash helper
# -----------------------

func _sha256(text: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(text.to_utf8_buffer())
	return ctx.finish().hex_encode()

# -----------------------
# Upserts V2 (skip si hash identique)
# -----------------------

func upsert_entity(resource: String, obj: Dictionary) -> Dictionary:
	# return {"inserted":int, "updated":int, "skipped":int, "errors":int}
	if not _is_ready:
		return {"inserted": 0, "updated": 0, "skipped": 0, "errors": 1}

	var id := int(obj.get("id", -1))
	if id <= 0:
		return {"inserted": 0, "updated": 0, "skipped": 1, "errors": 0}

	var name := String(obj.get("name", "")) if obj.has("name") else ""
	var json_txt := JSON.stringify(obj)
	var hash_txt := _sha256(json_txt)
	var utc := Time.get_datetime_string_from_system(true)

	# check hash existant
	var rows := _query_bind("SELECT hash FROM entities WHERE resource=? AND id=? LIMIT 1;", [resource, id])
	var existed := rows.size() > 0

	if existed:
		var old_hash := ""
		var row0: Dictionary = rows[0] as Dictionary

		# row0 devrait contenir la clé "hash"
		var v = row0.get("hash", null)
		if v != null:
			old_hash = str(v) # ✅ conversion sûre

		if old_hash == hash_txt and old_hash != "":
			return {"inserted": 0, "updated": 0, "skipped": 1, "errors": 0}
	# upsert
	var ok := _exec_bind("""
	INSERT INTO entities(resource,id,name,json,hash,saved_utc)
	VALUES(?,?,?,?,?,?)
	ON CONFLICT(resource,id) DO UPDATE SET
		name=excluded.name,
		json=excluded.json,
		hash=excluded.hash,
		saved_utc=excluded.saved_utc;
	""", [resource, id, name, json_txt, hash_txt, utc])

	if not ok:
		return {"inserted": 0, "updated": 0, "skipped": 0, "errors": 1}

	return {"inserted": 0, "updated": 1, "skipped": 0, "errors": 0} if existed else {"inserted": 1, "updated": 0, "skipped": 0, "errors": 0}

func upsert_manifest(resource: String, manifest: Dictionary) -> bool:
	if not _is_ready:
		return false
	var fp: Dictionary = manifest.get("fingerprint", {}) as Dictionary
	var count := int(fp.get("count", -1))
	var max_id := int(fp.get("max_id", -1))
	var sample_hash := String(fp.get("sample_hash", ""))
	var last_sync := String(manifest.get("last_sync_utc", Time.get_datetime_string_from_system(true)))

	return _exec_bind("""
	INSERT INTO resource_manifest(resource,count,max_id,sample_hash,last_sync_utc)
	VALUES(?,?,?,?,?)
	ON CONFLICT(resource) DO UPDATE SET
		count=excluded.count,
		max_id=excluded.max_id,
		sample_hash=excluded.sample_hash,
		last_sync_utc=excluded.last_sync_utc;
	""", [resource, count, max_id, sample_hash, last_sync])

# -----------------------
# Import cache -> DB (0 API)
# -----------------------

func import_from_cache(yield_every: int = 300) -> void:
	if not _is_ready:
		emit_signal("import_finished", "DB_NOT_READY", 0, 0, 0, 1, 0)
		return

	if cache_root.is_empty():
		emit_signal("import_finished", "NO_CACHE_ROOT", 0, 0, 0, 1, 0)
		return

	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(cache_root)):
		emit_signal("import_finished", "CACHE_NOT_FOUND", 0, 0, 0, 1, 0)
		return

	var total_files := _count_detail_files(cache_root)
	if total_files <= 0:
		emit_signal("import_finished", "NO_DETAILS_FOUND", 0, 0, 0, 0, 0)
		return

	var inserted := 0
	var updated := 0
	var skipped := 0
	var errors := 0
	var done := 0

	_exec("BEGIN;")

	var da := DirAccess.open(cache_root)
	if da == null:
		_exec("ROLLBACK;")
		emit_signal("import_finished", "OPEN_CACHE_FAILED", 0, 0, 0, 1, total_files)
		return

	da.list_dir_begin()
	while true:
		var res := da.get_next()
		if res == "":
			break
		if res.begins_with("."):
			continue
		if not da.current_is_dir():
			continue

		var resource := res
		var details_dir := "%s/%s/details" % [cache_root, resource]
		if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(details_dir)):
			continue

		# manifest -> resource_manifest
		var manifest_path := "%s/%s/manifest.json" % [cache_root, resource]
		var manifest_local := _read_json(manifest_path)
		if not manifest_local.is_empty():
			upsert_manifest(resource, manifest_local)

		var dd := DirAccess.open(details_dir)
		if dd == null:
			continue

		dd.list_dir_begin()
		while true:
			var f := dd.get_next()
			if f == "":
				break
			if dd.current_is_dir():
				continue
			if not f.ends_with(".json"):
				continue

			var path := "%s/%s" % [details_dir, f]
			var obj := _read_json(path)

			if obj.is_empty():
				errors += 1
			else:
				var r: Dictionary
				match resource:
					"pokemon_type":
						r = upsert_pokemon_type(obj)
					"pokemon_stat":
						r = upsert_pokemon_stat(obj)
					"pokemon_ability":
						r = upsert_pokemon_ability(obj)
					"pokedex_number":
						r = upsert_pokedex_number(obj)
					"pokemon_move":
						r = upsert_pokemon_move(obj)
					_:
						r = upsert_entity(resource, obj)
				inserted += int(r.get("inserted", 0))
				updated += int(r.get("updated", 0))
				skipped += int(r.get("skipped", 0))
				errors += int(r.get("errors", 0))

			done += 1
			if (done % yield_every) == 0:
				emit_signal("import_progress", "Import DB…", done, total_files, inserted, updated, skipped, errors)
				await get_tree().process_frame

		dd.list_dir_end()

	da.list_dir_end()

	_exec("COMMIT;")
	emit_signal("import_finished", "DONE", inserted, updated, skipped, errors, total_files)

func _count_detail_files(root: String) -> int:
	var total := 0
	var da := DirAccess.open(root)
	if da == null:
		return 0

	da.list_dir_begin()
	while true:
		var res := da.get_next()
		if res == "":
			break
		if res.begins_with("."):
			continue
		if not da.current_is_dir():
			continue

		var details := "%s/%s/details" % [root, res]
		var dd := DirAccess.open(details)
		if dd == null:
			continue

		dd.list_dir_begin()
		while true:
			var f := dd.get_next()
			if f == "":
				break
			if dd.current_is_dir():
				continue
			if f.ends_with(".json"):
				total += 1
		dd.list_dir_end()

	da.list_dir_end()
	return total

func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}

func _ensure_dir(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path))

# -----------------------
# Debug utiles
# -----------------------

func debug_db_count() -> int:
	var rows := _query("SELECT COUNT(*) AS cnt FROM entities;")
	if rows.size() == 0:
		return -1
	var row: Dictionary = rows[0] as Dictionary
	if row.has("cnt"):
		return int(row["cnt"])
	if row.size() > 0:
		return int(row.values()[0])
	return -1

func debug_counts_by_resource(limit: int = 20) -> Array:
	return _query("SELECT resource, COUNT(*) AS c FROM entities GROUP BY resource ORDER BY c DESC LIMIT %d;" % limit)

func debug_find_by_name(resource: String, name: String) -> Array:
	return _query_bind("SELECT id, name, hash, saved_utc FROM entities WHERE resource=? AND name=? LIMIT 10;", [resource, name])

func debug_get_entity(resource: String, id: int) -> Dictionary:
	var rows := _query_bind("SELECT json, hash FROM entities WHERE resource=? AND id=? LIMIT 1;", [resource, id])
	if rows.size() == 0:
		return {}
	var row: Dictionary = rows[0] as Dictionary
	var json_txt := str(row.get("json", ""))
	var parsed = JSON.parse_string(json_txt)
	if typeof(parsed) == TYPE_DICTIONARY:
		return parsed
	return {}

func get_entity(resource: String, id: int) -> Dictionary:
	if not _is_ready:
		return {}
	var rows := _query_bind("SELECT json FROM entities WHERE resource=? AND id=? LIMIT 1;", [resource, id])
	if rows.size() == 0:
		return {}
	var row: Dictionary = rows[0] as Dictionary
	var json_txt := str(row.get("json", ""))
	var parsed = JSON.parse_string(json_txt)
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}

func list_entities(resource: String, limit: int = 50, offset: int = 0) -> Array[Dictionary]:
	if not _is_ready:
		return []
	var rows := _query_bind(
		"SELECT id, name FROM entities WHERE resource=? ORDER BY id ASC LIMIT ? OFFSET ?;",
		[resource, limit, offset]
	)
	var out: Array[Dictionary] = []
	for r in rows:
		var d := r as Dictionary
		out.append({
			"id": int(d.get("id", -1)),
			"name": str(d.get("name", ""))
		})
	return out

func find_by_name(resource: String, name: String, limit: int = 10) -> Array[Dictionary]:
	if not _is_ready:
		return []
	var rows := _query_bind(
		"SELECT id, name FROM entities WHERE resource=? AND name=? LIMIT ?;",
		[resource, name, limit]
	)
	var out: Array[Dictionary] = []
	for r in rows:
		var d := r as Dictionary
		out.append({"id": int(d.get("id", -1)), "name": str(d.get("name", ""))})
	return out

func search_name_contains(resource: String, fragment: String, limit: int = 50, offset: int = 0) -> Array[Dictionary]:
	if not _is_ready:
		return []
	var pattern := "%" + fragment + "%"
	var rows := _query_bind(
		"SELECT id, name FROM entities WHERE resource=? AND name LIKE ? ORDER BY id ASC LIMIT ? OFFSET ?;",
		[resource, pattern, limit, offset]
	)
	var out: Array[Dictionary] = []
	for r in rows:
		var d := r as Dictionary
		out.append({"id": int(d.get("id", -1)), "name": str(d.get("name", ""))})
	return out

func get_entity_by_name(resource: String, name: String) -> Dictionary:
	if not _is_ready:
		return {}
	var rows := _query_bind("SELECT json FROM entities WHERE resource=? AND name=? LIMIT 1;", [resource, name])
	if rows.size() == 0:
		return {}
	var row: Dictionary = rows[0] as Dictionary
	var json_txt := str(row.get("json", ""))
	var parsed = JSON.parse_string(json_txt)
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}

func search_ids_by_name_contains(resource: String, fragment: String, limit: int = 50, offset: int = 0) -> Array[int]:
	if not _is_ready:
		return []
	var pattern := "%" + fragment + "%"
	var rows := _query_bind(
		"SELECT id FROM entities WHERE resource=? AND name LIKE ? ORDER BY id ASC LIMIT ? OFFSET ?;",
		[resource, pattern, limit, offset]
	)
	var out: Array[int] = []
	for r in rows:
		var d := r as Dictionary
		out.append(int(d.get("id", -1)))
	return out

func import_cursor_get(resource: String) -> int:
	if not _table_exists("import_state"):
		return 0
	var rows := _query_bind("SELECT cursor FROM import_state WHERE resource=? LIMIT 1;", [resource])
	if rows.size() == 0:
		return 0
	return int((rows[0] as Dictionary).get("cursor", 0))

func import_cursor_set(resource: String, cursor: int) -> void:
	if not _table_exists("import_state"):
		return
	_exec_bind(
		"INSERT INTO import_state(resource,cursor,updated_utc) VALUES(?,?,?) "
		+ "ON CONFLICT(resource) DO UPDATE SET cursor=excluded.cursor, updated_utc=excluded.updated_utc;",
		[resource, cursor, Time.get_datetime_string_from_system(true)]
	)

func upsert_entity_obj(resource: String, obj: Dictionary) -> Dictionary:
	if not obj.has("id"):
		return {"inserted": 0, "updated": 0, "skipped": 0, "errors": 1}

	var id := int(obj.get("id", -1))
	if id <= 0:
		return {"inserted": 0, "updated": 0, "skipped": 0, "errors": 1}

	var name := ""
	if obj.has("name"):
		name = String(obj.get("name", ""))

	var json_txt := JSON.stringify(obj)
	var hash_txt := _sha256(json_txt)
	var saved := Time.get_datetime_string_from_system(true)

	# skip si hash identique
	var old := _query_bind("SELECT hash FROM entities WHERE resource=? AND id=? LIMIT 1;", [resource, id])
	if old.size() > 0:
		var old_hash := str(old[0].get("hash", ""))
		if old_hash != "" and old_hash == hash_txt:
			return {"inserted": 0, "updated": 0, "skipped": 1, "errors": 0}

	var exists := _query_bind("SELECT 1 AS x FROM entities WHERE resource=? AND id=? LIMIT 1;", [resource, id]).size() > 0

	_exec_bind(
		"INSERT INTO entities(resource,id,name,json,hash,saved_utc) VALUES(?,?,?,?,?,?) "
		+ "ON CONFLICT(resource,id) DO UPDATE SET "
		+ "name=excluded.name, json=excluded.json, hash=excluded.hash, saved_utc=excluded.saved_utc;",
		[resource, id, name, json_txt, hash_txt, saved]
	)

	if exists:
		return {"inserted": 0, "updated": 1, "skipped": 0, "errors": 0}
	return {"inserted": 1, "updated": 0, "skipped": 0, "errors": 0}

func _i(v: Variant) -> int:
	if v == null: return -1
	if typeof(v) == TYPE_FLOAT: return int(v)
	return int(v)

func _b(v: Variant) -> int:
	return 1 if bool(v) else 0

func upsert_pokemon_type(obj: Dictionary) -> Dictionary:
	var pokemon_id := _i(obj.get("pokemon_id", null))
	var slot := _i(obj.get("slot", null))
	var type_id := _i(obj.get("type_id", null))
	if pokemon_id <= 0 or slot <= 0 or type_id <= 0:
		return {"inserted": 0, "updated": 0, "skipped": 0, "errors": 1}

	_exec_bind(
		"INSERT INTO dex_pokemon_type(pokemon_id,slot,type_id) VALUES(?,?,?) "
		+ "ON CONFLICT(pokemon_id,slot) DO UPDATE SET type_id=excluded.type_id;",
		[pokemon_id, slot, type_id]
	)
	return {"inserted": 1, "updated": 0, "skipped": 0, "errors": 0}

func upsert_pokemon_stat(obj: Dictionary) -> Dictionary:
	var pokemon_id := _i(obj.get("pokemon_id", null))
	var stat_id := _i(obj.get("stat_id", null))
	var base_stat := _i(obj.get("base_stat", null))
	var effort := _i(obj.get("effort", 0))
	if pokemon_id <= 0 or stat_id <= 0:
		return {"inserted": 0, "updated": 0, "skipped": 0, "errors": 1}

	_exec_bind(
		"INSERT INTO dex_pokemon_stat(pokemon_id,stat_id,base_stat,effort) VALUES(?,?,?,?) "
		+ "ON CONFLICT(pokemon_id,stat_id) DO UPDATE SET base_stat=excluded.base_stat, effort=excluded.effort;",
		[pokemon_id, stat_id, base_stat, effort]
	)
	return {"inserted": 1, "updated": 0, "skipped": 0, "errors": 0}

func upsert_pokemon_ability(obj: Dictionary) -> Dictionary:
	var pokemon_id := _i(obj.get("pokemon_id", null))
	var slot := _i(obj.get("slot", null))
	var ability_id := _i(obj.get("ability_id", null))
	var is_hidden := _b(obj.get("is_hidden", false))
	if pokemon_id <= 0 or slot <= 0 or ability_id <= 0:
		return {"inserted": 0, "updated": 0, "skipped": 0, "errors": 1}

	_exec_bind(
		"INSERT INTO dex_pokemon_ability(pokemon_id,slot,ability_id,is_hidden) VALUES(?,?,?,?) "
		+ "ON CONFLICT(pokemon_id,slot) DO UPDATE SET ability_id=excluded.ability_id, is_hidden=excluded.is_hidden;",
		[pokemon_id, slot, ability_id, is_hidden]
	)
	return {"inserted": 1, "updated": 0, "skipped": 0, "errors": 0}

func upsert_pokemon_move(obj: Dictionary) -> Dictionary:
	var pokemon_id := _i(obj.get("pokemon_id", null))
	var move_id := _i(obj.get("move_id", null))
	var version_group_id := _i(obj.get("version_group_id", null))
	var method_id := _i(obj.get("move_learn_method_id", null))
	var level := _i(obj.get("level", null))
	var order_no := _i(obj.get("order", null))
	var mastery := _i(obj.get("mastery", null))

	if pokemon_id <= 0 or move_id <= 0 or version_group_id <= 0 or method_id <= 0 or level < 0:
		return {"inserted": 0, "updated": 0, "skipped": 0, "errors": 1}

	_exec_bind(
		"INSERT INTO dex_pokemon_move(pokemon_id,move_id,version_group_id,move_learn_method_id,level,order_no,mastery) "
		+ "VALUES(?,?,?,?,?,?,?) "
		+ "ON CONFLICT(pokemon_id,move_id,version_group_id,move_learn_method_id,level) DO UPDATE SET "
		+ "order_no=excluded.order_no, mastery=excluded.mastery;",
		[pokemon_id, move_id, version_group_id, method_id, level, order_no, mastery]
	)
	return {"inserted": 1, "updated": 0, "skipped": 0, "errors": 0}


func get_entity_json(resource: String, id: int) -> Dictionary:
	var rows := _query_bind("SELECT json FROM entities WHERE resource=? AND id=? LIMIT 1;", [resource, id])
	if rows.size() == 0:
		return {}
	return JSON.parse_string(String(rows[0].get("json",""))) as Dictionary

func pokemon_types_ids(pokemon_id: int) -> Array[int]:
	var rows := _query_bind("SELECT type_id FROM dex_pokemon_type WHERE pokemon_id=? ORDER BY slot;", [pokemon_id])
	var out: Array[int] = []
	for r in rows:
		out.append(int(r.get("type_id", 0)))
	return out

func pokemon_stats_rows(pokemon_id: int) -> Array[Dictionary]:
	return _query_bind("SELECT stat_id, base_stat, effort FROM dex_pokemon_stat WHERE pokemon_id=? ORDER BY stat_id;", [pokemon_id])

func pokemon_moves_rows(pokemon_id: int, version_group_id: int, learn_method_id: int) -> Array[Dictionary]:
	return _query_bind(
		"SELECT move_id, level FROM dex_pokemon_move "
		+ "WHERE pokemon_id=? AND version_group_id=? AND move_learn_method_id=? "
		+ "ORDER BY level ASC, move_id ASC;",
		[pokemon_id, version_group_id, learn_method_id]
	)

func pokemon_moves_upto_level(pokemon_id: int, version_group_id: int, learn_method_id: int, level: int) -> Array[Dictionary]:
	return _query_bind(
		"SELECT move_id, level FROM dex_pokemon_move "
		+ "WHERE pokemon_id=? AND version_group_id=? AND move_learn_method_id=? AND level<=? "
		+ "ORDER BY level ASC, move_id ASC;",
		[pokemon_id, version_group_id, learn_method_id, level]
	)

func debug_pokemon_types_rows(pokemon_id: int) -> Array[Dictionary]:
	return _query_bind(
		"SELECT slot, type_id FROM dex_pokemon_type WHERE pokemon_id=? ORDER BY slot;",
		[pokemon_id]
	)

func debug_table_count(table: String) -> int:
	var rows := _query("SELECT COUNT(*) AS c FROM %s;" % table)
	if rows.size() == 0:
		return -1
	return int((rows[0] as Dictionary).get("c", -1))

func meta_get(key: String, default_value: String = "") -> String:
	var rows := _query_bind("SELECT value FROM meta WHERE key=? LIMIT 1;", [key])
	if rows.size() == 0:
		return default_value
	return str((rows[0] as Dictionary).get("value", default_value))

func meta_set(key: String, value: String) -> void:
	_exec_bind(
		"INSERT INTO meta(key,value) VALUES(?,?) "
		+ "ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
		[key, value]
	)
func pokemon_moves_upto_level_methods(pokemon_id: int, version_group_id: int, method_ids: Array[int], level: int) -> Array[Dictionary]:
	if method_ids.is_empty():
		return []

	# construit "?, ?, ?" dynamiquement
	var qs := []
	var binds: Array = [pokemon_id, version_group_id]
	for _m in method_ids:
		qs.append("?")
		binds.append(int(_m))
	binds.append(level)

	var sql := "SELECT move_id, level, move_learn_method_id, version_group_id FROM dex_pokemon_move " \
		+ "WHERE pokemon_id=? AND version_group_id=? AND move_learn_method_id IN (" + ",".join(qs) + ") AND level<=? " \
		+ "ORDER BY level ASC, move_id ASC;"

	return _query_bind(sql, binds)

# ---------------------------------------------------
# Fast import wrapper (PRAGMA + transaction + restore)
# ---------------------------------------------------
@export var fast_import_enabled := true
@export var fast_import_use_memory_journal := true # plus rapide, un peu plus risqué
@export var fast_import_sync_off := true           # plus rapide, plus risqué

func run_fast_import(work: Callable) -> Variant:
	if _db == null:
		push_error("[PokeDb] run_fast_import: DB not open")
		return null

	# Si tu veux pouvoir désactiver en 1 clic
	if not fast_import_enabled:
		return work.call()

	# Sauvegarde quelques PRAGMAs pour restaurer après
	var prev_journal := _pragma_get_str("journal_mode", "WAL")
	var prev_sync := _pragma_get_str("synchronous", "NORMAL")
	var prev_temp := _pragma_get_str("temp_store", "DEFAULT")

	# Active mode rapide
	if fast_import_use_memory_journal:
		_exec("PRAGMA journal_mode=MEMORY;") # très rapide
	else:
		_exec("PRAGMA journal_mode=WAL;")    # safe-ish

	if fast_import_sync_off:
		_exec("PRAGMA synchronous=OFF;")     # très rapide
	else:
		_exec("PRAGMA synchronous=NORMAL;")

	_exec("PRAGMA temp_store=MEMORY;")

	# Transaction globale (le plus gros gain)
	_exec("BEGIN IMMEDIATE;")

	var result: Variant = await work.call()
	var ok := true


	if typeof(result) == TYPE_BOOL and result == false:
		ok = false
	elif typeof(result) == TYPE_DICTIONARY and (result as Dictionary).get("ok", true) == false:
		ok = false

	if ok:
		_exec("COMMIT;")
	else:
		_exec("ROLLBACK;")

	# Restore settings
	_exec("PRAGMA journal_mode=%s;" % prev_journal)
	_exec("PRAGMA synchronous=%s;" % prev_sync)
	_exec("PRAGMA temp_store=%s;" % prev_temp)

	return result


func _pragma_get_str(name: String, default_value: String) -> String:
	var rows := _query("PRAGMA %s;" % name)
	if rows.size() == 0:
		return default_value

	var r0 :Variant= rows[0]
	# Suivant plugin SQLite, ça peut être un dict ou autre
	if typeof(r0) == TYPE_DICTIONARY:
		var d := r0 as Dictionary
		# on prend la première value
		if d.size() > 0:
			return str(d.values()[0])
	return default_value
