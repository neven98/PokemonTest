extends Node


signal import_progress(msg: String, done: int, total: int, inserted: int, updated: int, skipped: int, errors: int)
signal import_finished(status: String, inserted: int, updated: int, skipped: int, errors: int, total: int)

@export var max_files_per_run := 5000

const PROGRESS_EVERY := 5000
@export var yield_every := 5000
const YIELD_EVERY := 800  # juste pour éviter un freeze trop violent (pas obligé)
const NO_CAP := 1 << 30
var _t0_ms := 0
var _last_tick_ms := 0
var _last_tick_done := 0

func reset_cursor(resource: String) -> void:
	PokeDb.import_cursor_set(resource, 0)

func import_only(resource: String, max_files: int = -1) -> void:
	await _import_resources([resource], max_files)

func import_step(max_files: int = 0) -> void:
	# 0 => comportement "par défaut" (5000)
	# -1 => illimité
	await _import_resources(PokeCacheSync.REGISTRY, max_files)

func _import_resources(resources: Array[String], max_files: int) -> void:
	if not PokeDb.is_ready():
		emit_signal("import_finished", "DB_NOT_READY", 0, 0, 0, 1, 0)
		return

	var cap := NO_CAP
	if max_files == 0:
		cap = max_files_per_run
	elif max_files > 0:
		cap = max_files
	# max_files < 0 => NO_CAP

	var cache_root := PokeCacheSync.cache_root

	# total "réel" = nombre d’éléments restants à importer (ça règle ton %)
	var total_to_do := 0
	for res in resources:
		var index_path := "%s/%s/index.json" % [cache_root, res]
		if not FileAccess.file_exists(index_path):
			continue
		var idx := _read_json(index_path)
		var results: Array = idx.get("results", [])
		if results.is_empty():
			continue
		var cursor := int(PokeDb.import_cursor_get(res))
		total_to_do += max(0, results.size() - cursor)

	total_to_do = min(total_to_do, cap)

	if total_to_do <= 0:
		emit_signal("import_finished", "NOTHING_TO_IMPORT", 0, 0, 0, 0, 0)
		return

	var done := 0
	var ins := 0
	var upd := 0
	var skp := 0
	var err := 0

	PokeDb._exec("BEGIN;")

	for res in resources:
		if done >= cap:
			break

		var index_path := "%s/%s/index.json" % [cache_root, res]
		if not FileAccess.file_exists(index_path):
			continue

		var idx := _read_json(index_path)
		var results: Array = idx.get("results", [])
		if results.is_empty():
			continue

		var cursor := int(PokeDb.import_cursor_get(res))
		if cursor < 0: cursor = 0
		if cursor >= results.size():
			continue

		emit_signal("import_progress", "Import %s…" % res, done, total_to_do, ins, upd, skp, err)

		while cursor < results.size() and done < cap:
			var row = results[cursor]
			var key := _index_key(row)
			if key == "":
				cursor += 1
				continue

			var detail_path := "%s/%s/details/%s.json" % [cache_root, res, key]
			var obj := _read_json(detail_path)
			if obj.is_empty():
				cursor += 1
				continue

			var r := _import_one(res, obj)
			ins += int(r.get("inserted", 0))
			upd += int(r.get("updated", 0))
			skp += int(r.get("skipped", 0))
			err += int(r.get("errors", 0))

			cursor += 1
			done += 1

			if (done % yield_every) == 0:
				emit_signal("import_progress", "Import %s (%d/%d)" % [res, done, total_to_do], done, total_to_do, ins, upd, skp, err)
				await get_tree().process_frame

		PokeDb.import_cursor_set(res, cursor)

	PokeDb._exec("COMMIT;")

	var status := "DONE" if done >= total_to_do else "PARTIAL"
	emit_signal("import_finished", status, ins, upd, skp, err, total_to_do)

func _import_one(resource: String, obj: Dictionary) -> Dictionary:
	match resource:
		"pokemon_type":
			return PokeDb.upsert_pokemon_type(obj)
		"pokemon_stat":
			return PokeDb.upsert_pokemon_stat(obj)
		"pokemon_ability":
			return PokeDb.upsert_pokemon_ability(obj)
		"pokemon_move":
			return PokeDb.upsert_pokemon_move(obj)
		"pokedex_number", "pokemondexnumber":
			return PokeDb.upsert_pokedex_number(obj)
	return PokeDb.upsert_entity_obj(resource, obj)

func _compute_total_remaining(cache_root: String, resources: Array[String]) -> int:
	var total := 0
	for resource in resources:
		var index_path := "%s/%s/index.json" % [cache_root, resource]
		if not FileAccess.file_exists(index_path):
			continue
		var idx := _read_json(index_path)
		var results: Array = idx.get("results", [])
		if results.is_empty():
			continue
		var cursor :Variant= max(0, PokeDb.import_cursor_get(resource))
		total += max(0, results.size() - cursor)
	return total

func _compute_global_totals(resources: Array[String], cache_root: String) -> Dictionary:
	var total := 0
	var done := 0
	var remaining := 0

	for resource in resources:
		var index_path := "%s/%s/index.json" % [cache_root, resource]
		if not FileAccess.file_exists(index_path):
			continue

		var idx := _read_json(index_path)
		var results: Array = idx.get("results", [])
		if results.is_empty():
			continue

		var cursor := PokeDb.import_cursor_get(resource)
		if cursor < 0: cursor = 0
		if cursor > results.size(): cursor = results.size()

		total += results.size()
		done += cursor
		remaining += (results.size() - cursor)

	return {"total": total, "done": done, "remaining": remaining}

func _format_eta(sec: float) -> String:
	if sec <= 0.0:
		return "?"
	var s := int(sec)
	var h := s / 3600
	s -= h * 3600
	var m := s / 60
	s -= m * 60
	if h > 0:
		return "%dh%02dm%02ds" % [h, m, s]
	if m > 0:
		return "%dm%02ds" % [m, s]
	return "%ds" % s


func rebuild_all_indexes() -> void:
	for res in PokeCacheSync.REGISTRY:
		rebuild_index_from_details(res)

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
