extends Node

signal import_progress(msg: String, done: int, total: int)
signal import_finished(status: String, inserted: int, updated: int, skipped: int, errors: int)

@export var max_files_per_run := 5000

func import_step(max_files: int = -1) -> void:
	if max_files < 0:
		max_files = max_files_per_run

	if not PokeDb.is_ready():
		emit_signal("import_finished", "DB_NOT_READY", 0, 0, 0, 1)
		return

	var cache_root := PokeCacheSync.cache_root
	var resources: Array[String] = PokeCacheSync.REGISTRY

	var done := 0
	var ins := 0
	var upd := 0
	var skp := 0
	var err := 0

	for resource in resources:
		if done >= max_files:
			break

		var index_path := "%s/%s/index.json" % [cache_root, resource]
		if not FileAccess.file_exists(index_path):
			continue

		var idx := _read_json(index_path)
		var results: Array = idx.get("results", [])
		if results.is_empty():
			continue

		var cursor :Variant= PokeDb.import_cursor_get(resource)
		if cursor < 0:
			cursor = 0
		if cursor >= results.size():
			continue

		emit_signal("import_progress", "Import %s…" % resource, done, max_files)

		# import par lot sur cette ressource
		while cursor < results.size() and done < max_files:
			var row :Variant= results[cursor]
			var key := _index_key(row)
			if key == "":
				cursor += 1
				continue

			var detail_path := "%s/%s/details/%s.json" % [cache_root, resource, key]
			var obj := _read_json(detail_path)
			if obj.is_empty():
				cursor += 1
				continue

			var r := _import_one(resource, obj)
			ins += int(r.get("inserted", 0))
			upd += int(r.get("updated", 0))
			skp += int(r.get("skipped", 0))
			err += int(r.get("errors", 0))

			cursor += 1
			done += 1

			# évite de freeze l'UI
			if (done % 200) == 0:
				emit_signal("import_progress", "Import %s (%d/%d)" % [resource, done, max_files], done, max_files)
				await get_tree().process_frame

		PokeDb.import_cursor_set(resource, cursor)

	var status := "DONE" if done < max_files else "PARTIAL"
	emit_signal("import_finished", status, ins, upd, skp, err)

func _import_one(resource: String, obj: Dictionary) -> Dictionary:
	# Relations Pokémon -> tables dédiées
	match resource:
		"pokemon_type":
			return PokeDb.upsert_pokemon_type(obj)
		"pokemon_stat":
			return PokeDb.upsert_pokemon_stat(obj)
		"pokemon_ability":
			return PokeDb.upsert_pokemon_ability(obj)
		"pokemon_move":
			return PokeDb.upsert_pokemon_move(obj)
		"pokemondexnumber":
			return PokeDb.upsert_pokedex_number(obj)
	# Tout le reste -> table entities (id obligatoire)
	return PokeDb.upsert_entity_obj(resource, obj)

func _index_key(row: Variant) -> String:
	# index parfois = [{"id":1}, ...] ou [{"key":"..."}] ou [1,2,3] ou ["1","2"...]
	if typeof(row) == TYPE_INT or typeof(row) == TYPE_FLOAT:
		var n := int(row)
		return str(n) if n > 0 else ""

	if typeof(row) == TYPE_STRING:
		var s := String(row).strip_edges()
		return s if s.is_valid_int() else ""

	if typeof(row) != TYPE_DICTIONARY:
		return ""

	var d := row as Dictionary

	if d.has("key"):
		var k := str(d["key"]).strip_edges()
		if k != "":
			return k

	if d.has("id"):
		var id := int(d.get("id", 0))
		if id > 0:
			return str(id)

	return ""

func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed :Variant= JSON.parse_string(f.get_as_text())
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}

func rebuild_index_from_details(resource: String) -> Dictionary:
	var cache_root := PokeCacheSync.cache_root
	var details_dir := "%s/%s/details" % [cache_root, resource]
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(details_dir)):
		return {"status":"NO_DETAILS"}

	var dd := DirAccess.open(details_dir)
	if dd == null:
		return {"status":"OPEN_FAIL"}

	var files: Array[String] = []
	dd.list_dir_begin()
	while true:
		var f := dd.get_next()
		if f == "":
			break
		if dd.current_is_dir():
			continue
		if f.ends_with(".json"):
			files.append(f)
	dd.list_dir_end()

	# tri numérique si c'est du "123.json"
	files.sort_custom(func(a, b):
		return int(a.get_basename()) < int(b.get_basename())
	)

	var results: Array = []
	for f in files:
		var base := f.get_basename()
		if base.is_valid_int():
			results.append({"id": int(base)})
		else:
			# cas composite : "pokemon_id=1,slot=2" etc
			results.append({"key": base})

	var index_path := "%s/%s/index.json" % [cache_root, resource]
	var out := {"resource": resource, "count": results.size(), "results": results}
	_write_json(index_path, out)

	print("[Index rebuilt] ", resource, " count=", results.size())
	return {"status":"OK", "count": results.size()}

func _write_json(path: String, data: Variant) -> void:
	# crée les dossiers si besoin
	var dir := path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))

	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("[PokeImport] cannot write: %s" % path)
		return
	f.store_string(JSON.stringify(data, "\t"))
