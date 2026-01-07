extends Node

signal offline_progress(msg: String, calls_used: int, remaining_resources: int)
signal offline_finished(status: String, calls_used: int, remaining_resources: int)

@export var cache_root := "user://poke_cache/v1beta2"
@export var page_size := 200
@export var sample_size := 25
@onready var api: PokeApiClient = PokeApiClient.new()

# type_name -> { field_name -> { "kind": "...", "name": "..." } }
var _type_field_to_named: Dictionary = {}

# ids langue (pokeapi classique) : fr=5, en=9
const KEEP_LANG_IDS := [5, 9]

var _type_to_all_fields: Dictionary = {}  # type_name -> Array[String]
var _resolved_field_for_key: Dictionary = {} # key -> real_field_name
var KEY_FIELD_OVERRIDES := {
	"move_ailment": "movemetaailment",
	"move_category": "movemetacategory",

	# Pokémon relations (root fields du schéma)
	"pokemon_type": "pokemontype",
	"pokemon_stat": "pokemonstat",
	"pokemon_ability": "pokemonability",
	"pokemon_move": "pokemonmove",
}

var COMPOSITE_KEY_FIELDS := {
	# pokemontype: pokemon_id + slot (unique)
	"pokemon_type": ["pokemon_id", "slot"],

	# pokemonstat: pokemon_id + stat_id (unique)
	"pokemon_stat": ["pokemon_id", "stat_id"],

	# pokemonability: pokemon_id + slot (unique)
	"pokemon_ability": ["pokemon_id", "slot"],

	# pokemonmove: plusieurs lignes par pokemon/move/version/method/level
	"pokemon_move": ["pokemon_id", "move_id", "version_group_id", "move_learn_method_id", "level"],
}

var CUSTOM_SELECTION := {}

# Ressources “menu v2” -> nom GraphQL supposé (underscore)
# Si une ressource échoue (gql_error), tu ajustes juste ici.
var REGISTRY: Array[String] = [
	# Berries
	"berry", "berry_firmness", "berry_flavor",
	# Contests
	"contest_type", "contest_effect", "super_contest_effect",
	# Encounters
	"encounter_method", "encounter_condition", "encounter_condition_value",
	# Evolution
	"evolution_chain", "evolution_trigger",
	# Games
	"generation", "pokedex", "version", "version_group",
	# Items
	"item", "item_attribute", "item_category", "item_fling_effect", "item_pocket",
	# Locations
	"location", "location_area", "pal_park_area", "region",
	# Machines
	"machine",
	# Moves
	"move", "move_ailment", "move_battle_style", "move_category", "move_damage_class", "move_learn_method", "move_target",
	# Pokemon
	"ability", "characteristic", "egg_group", "gender", "growth_rate", "nature", "pokeathlon_stat",
	"pokemon", "pokemon_color", "pokemon_form", "pokemon_habitat", "pokemon_shape", "pokemon_species",
	"stat", "type",
	"pokemon_type",
	"pokemon_stat",
	"pokemon_ability",
	"pokemon_move",
	# Utility
	"language"
]

# -------- Schema cache (introspection) --------
var _schema_loaded := false
var _root_field_to_type: Dictionary = {}     # field_name -> type_name (object)
var _type_to_scalar_fields: Dictionary = {}  # type_name -> Array[String]

func _ready() -> void:
	add_child(api)
	_ensure_dir(cache_root)

# =========================
# PUBLIC: bouton Update
# =========================

# Update offline “safe”: avance par lots, reprend si relancé.
# max_calls_this_run : mets 60-80 (marge sous 100/h)
func update_offline_all(max_calls_this_run: int = 80) -> void:
	var calls_used := 0

	# 1) Charge schema (1 appel si pas en cache)
	var schema_res := await _ensure_schema_cached()
	calls_used += int(schema_res.get("calls", 0))
	if schema_res.get("status", "") == "RATE_LIMIT":
		_emit_finish("RATE_LIMIT", calls_used)
		return
	if schema_res.get("status", "") != "OK":
		_emit_finish("SCHEMA_ERROR", calls_used)
		return
	if calls_used >= max_calls_this_run:
		_emit_finish("PARTIAL", calls_used)
		return

	# 2) Pending queue
	var pending: Array[String] = _load_pending()
	if pending.is_empty():
		pending = REGISTRY.duplicate()
		pending.sort()
		_save_pending(pending)

	var total_remaining := pending.size()
	emit_signal("offline_progress", "Update: démarrage…", calls_used, total_remaining)

	# 3) Traite ressource par ressource dans le budget
	while not pending.is_empty() and calls_used < max_calls_this_run:
		var key := pending[0]
		emit_signal("offline_progress", "Offline: %s" % key, calls_used, pending.size())

		var budget_left := max_calls_this_run - calls_used
		var r := await _sync_resource_offline(key, budget_left)
		calls_used += int(r.get("calls", 0))

		var status := String(r.get("status", "ERROR"))

		if status == "DONE":
			pending.pop_front()
			_save_pending(pending)
			continue

		if status == "PARTIAL":
			_save_pending(pending)
			_emit_finish("PARTIAL", calls_used)
			return

		if status == "RATE_LIMIT":
			_save_pending(pending)
			_emit_finish("RATE_LIMIT", calls_used)
			return

		# ERROR -> on stop (à toi de décider si tu préfères continuer)
		_save_pending(pending)
		_emit_finish("ERROR_%s" % key, calls_used)
		return

	# 4) Fini
	if pending.is_empty():
		_delete_file(_pending_path())
		_emit_finish("DONE", calls_used)
	else:
		_emit_finish("PARTIAL", calls_used)

# =========================
# Optionnel: lecture offline
# =========================

func read_detail(resource: String, id: int) -> Dictionary:
	var path := "%s/%s/details/%d.json" % [cache_root, resource, id]
	var d: Dictionary = _read_json(path)
	return d

# =========================
# INTERNAL: sync 1 ressource
# =========================

func _sync_resource_offline(resource: String, max_calls: int) -> Dictionary:
	var calls := 0

	# 1) Résout root field + scalars
	var scalars: Array[String] = _get_scalar_fields_for_key(resource)
	var field := _resolve_root_field_for_key(resource)
	var has_custom := CUSTOM_SELECTION.has(resource)

	# ✅ si custom selection -> on n'exige pas scalars
	if field.is_empty() or (scalars.is_empty() and not has_custom):
		print("key=", resource, " field=", field, " scalars=", scalars, " custom=", has_custom)
		return {"status":"ERROR", "calls": 0}

	# ✅ si custom et scalars vides, on force au moins "id" pour fichier + fingerprint
	if scalars.is_empty() and has_custom:
		scalars = ["id"]

	var has_id := scalars.has("id")
	var has_name := scalars.has("name")
	var key_fields: Array = []
	if COMPOSITE_KEY_FIELDS.has(resource):
		key_fields = COMPOSITE_KEY_FIELDS[resource]

	if (not has_id) and key_fields.is_empty():
		# Ni id, ni clé composite -> impossible d’écrire des fichiers stables
		return {"status":"ERROR", "calls": calls}

	# 2) Dossiers
	_ensure_dir("%s/%s/details" % [cache_root, resource])

	var manifest_path := _manifest_path(resource)
	var state_path := _state_path(resource)
	var index_path := _index_path(resource)

	var local_manifest: Dictionary = _read_json(manifest_path)
	var local_fp: Dictionary = (local_manifest.get("fingerprint", {}) as Dictionary)

	var state: Dictionary = _read_json(state_path)
	var complete: bool = bool(state.get("complete", false))
	var mode: String = String(state.get("mode", "full"))
	var offset: int = int(state.get("offset", 0))
	var gt_id: int = int(state.get("gt_id", 0))

	# 3) Fingerprint remote
	if calls >= max_calls:
		return {"status":"PARTIAL", "calls": calls}

	var fp_res := await _fetch_fingerprint(resource, has_name)
	calls += int(fp_res.get("calls", 0))
	if fp_res.get("status", "") != "OK":
		return {"status": fp_res.get("status", "ERROR"), "calls": calls}

	var remote_fp: Dictionary = fp_res.get("fingerprint", {})

	# Si déjà à jour ET complet -> rien à faire
	if complete and not local_fp.is_empty() and local_fp == remote_fp:
		return {"status": "DONE", "calls": calls}

	# 4) Choix stratégie (incremental seulement si id existe)
	var remote_max: int = int(remote_fp.get("max_id", -1))
	var remote_count: int = int(remote_fp.get("count", -1))
	var local_max: int = int(local_fp.get("max_id", -1))
	var local_count: int = int(local_fp.get("count", -1))

	var must_full_reset := false
	if not local_fp.is_empty() and local_fp != remote_fp:
		if (remote_max != -1 and local_max != -1 and remote_max < local_max) or \
		   (remote_count != -1 and local_count != -1 and remote_count < local_count):
			must_full_reset = true

	if must_full_reset:
		_emit_dbg("Reset full %s" % resource)
		_wipe_resource(resource)
		mode = "full"
		offset = 0
		gt_id = 0
		complete = false
		state = {}

	# incremental uniquement si has_id
	if has_id and not local_fp.is_empty() and local_fp != remote_fp and remote_max > local_max and local_max > 0:
		if mode != "incremental" or gt_id != local_max:
			mode = "incremental"
			gt_id = local_max
			offset = 0
			complete = false

	# si pas de manifest -> full
	if local_fp.is_empty() and state.is_empty():
		mode = "full"
		offset = 0
		gt_id = 0
		complete = false

	# si pas d'id -> jamais incremental
	if not has_id:
		mode = "full"
		gt_id = 0

	# 5) Charge index (uniquement utile en incremental)
	var index_map: Dictionary = {}
	if mode == "incremental" and FileAccess.file_exists(index_path):
		var idx: Dictionary = _read_json(index_path)
		var resarr: Array = idx.get("results", [])
		for e in resarr:
			if typeof(e) != TYPE_DICTIONARY:
				continue
			var ed := e as Dictionary
			# compat : ancien index avec "id"
			if ed.has("id"):
				var eid := int(ed.get("id", -1))
				if eid > 0:
					index_map[str(eid)] = ed
			# nouveau index avec "key"
			elif ed.has("key"):
				index_map[String(ed["key"])] = ed

	if mode == "full":
		index_map.clear()

	# 6) Download pages
	var selection := _selection_for_resource(resource, field, scalars)


	while calls < max_calls:
		emit_signal("offline_progress", "%s [%s] offset=%d" % [resource, mode, offset], calls, _load_pending().size())

		var vars: Dictionary = {"limit": page_size, "offset": offset}
		var args: Array[String] = []
		args.append("limit:$limit")
		args.append("offset:$offset")

		var ob := _order_by_clause(resource, has_id)
		if ob != "":
			args.append(ob)

		if mode == "incremental" and has_id:
			vars["gt"] = gt_id
			args.append("where:{id:{_gt:$gt}}")

		var q := "query($limit:Int!, $offset:Int!"
		if mode == "incremental" and has_id:
			q += ", $gt:Int!"
		q += "){ %s(%s){ %s } }" % [field, ", ".join(args), selection]

		var data: Dictionary = await api.gql(q, vars)
		calls += 1

		if data.has("_error"):
			print("[GQL ERROR]", resource, " => ", data)
			var e := String(data["_error"])
			if e == "rate_limited":
				_save_state(state_path, mode, offset, gt_id, false)
				return {"status":"RATE_LIMIT", "calls": calls}
			_save_state(state_path, mode, offset, gt_id, false)
			return {"status":"ERROR", "calls": calls}

		var arr: Array = data.get(field, [])
		if arr.is_empty():
			_save_state(state_path, mode, offset, gt_id, true)
			_write_manifest(manifest_path, resource, remote_fp)
			_write_index(index_path, resource, index_map, has_name)
			return {"status":"DONE", "calls": calls}

		# écrit page
		for v in arr:
			if typeof(v) != TYPE_DICTIONARY:
				continue
			var obj := v as Dictionary

			var filename := ""
			if has_id and obj.has("id"):
				var rid := int(obj.get("id", -1))
				if rid <= 0:
					continue
				filename = "%d" % rid
			else:
				# clé composite
				if not COMPOSITE_KEY_FIELDS.has(resource):
					continue
				var kfs: Array = COMPOSITE_KEY_FIELDS[resource]
				var parts: Array[String] = []
				for kf in kfs:
					var key := String(kf)
					if not obj.has(key):
						parts.clear()
						break
					parts.append("%s=%s" % [key, str(obj[key])])
				if parts.is_empty():
					continue
				filename = ",".join(parts)

			var detail_path := "%s/%s/details/%s.json" % [cache_root, resource, filename]

			if resource == "pokemon_species":
				var eg_ids := _extract_egg_group_ids_from_species_obj(obj)
				if not eg_ids.is_empty():
					obj["egg_group_ids"] = eg_ids
			if mode == "incremental":
				if not FileAccess.file_exists(detail_path):
					_write_json(detail_path, obj)
			else:
				_write_json(detail_path, obj)

			# index : compat id + key
			var entry: Dictionary = {}
			if has_id:
				entry["id"] = int(obj.get("id", -1))
			entry["key"] = filename
			if has_name and obj.has("name"):
				entry["name"] = String(obj.get("name", ""))
			index_map[filename] = entry

		# page suivante
		if arr.size() < page_size:
			_save_state(state_path, mode, offset, gt_id, true)
			_write_manifest(manifest_path, resource, remote_fp)
			_write_index(index_path, resource, index_map, has_name)
			return {"status":"DONE", "calls": calls}

		offset += page_size
		_save_state(state_path, mode, offset, gt_id, false)

	# budget fini
	_write_manifest(manifest_path, resource, remote_fp)
	_write_index(index_path, resource, index_map, has_name)
	return {"status":"PARTIAL", "calls": calls}


# =========================
# Fingerprint
# =========================

func _fetch_fingerprint(key: String, has_name: bool) -> Dictionary:
	var calls := 0
	var field := _resolve_root_field_for_key(key)
	if field.is_empty():
		return {"status":"ERROR", "calls": calls}

	var scalars: Array[String] = _get_scalar_fields_for_key(key)
	var has_id := scalars.has("id") or CUSTOM_SELECTION.has(key)

	# 1) aggregate
	var agg_field := "%s_aggregate" % field

	var agg_sel := "aggregate { count"
	if has_id:
		agg_sel += " max { id }"
	agg_sel += " }"

	var q1 := "query{ %s { %s } }" % [agg_field, agg_sel]
	var d1: Dictionary = await api.gql(q1, {})
	calls += 1
	if d1.has("_error"):
		if String(d1["_error"]) == "rate_limited":
			return {"status":"RATE_LIMIT", "calls": calls}
		return {"status":"ERROR", "calls": calls}

	var agg_container: Dictionary = (d1.get(agg_field, {}) as Dictionary)
	var agg: Dictionary = (agg_container.get("aggregate", {}) as Dictionary)

	var count := int(agg.get("count", -1))
	var max_id := -1
	if has_id:
		max_id = int((agg.get("max", {}) as Dictionary).get("id", -1))

	# 2) sample (hash stable)
	var sample_sel := ""
	if has_id:
		sample_sel = "id"
		if has_name:
			sample_sel = "id name"
	else:
		# pour tables sans id : on hash les champs de la clé composite si possible
		if COMPOSITE_KEY_FIELDS.has(key):
			var kfs: Array = COMPOSITE_KEY_FIELDS[key]
			var sf: Array[String] = []
			for kf in kfs:
				sf.append(String(kf))
			sample_sel = _join_fields(sf)
		else:
			# fallback minimal
			sample_sel = _join_fields(scalars)

	var ob := _order_by_clause(key, has_id)
	var args: Array[String] = ["limit:$n"]
	if ob != "":
		args.append(ob)

	var q2 := "query($n:Int!){ %s(%s){ %s } }" % [field, ", ".join(args), sample_sel]
	var d2: Dictionary = await api.gql(q2, {"n": sample_size})
	calls += 1
	if d2.has("_error"):
		if String(d2["_error"]) == "rate_limited":
			return {"status":"RATE_LIMIT", "calls": calls}
		return {"status":"ERROR", "calls": calls}

	var sample: Array = d2.get(field, [])
	var sample_hash := _sha256(JSON.stringify(sample))

	return {
		"status": "OK",
		"calls": calls,
		"fingerprint": {
			"count": count,
			"max_id": max_id,
			"sample_hash": sample_hash
		}
	}

# =========================
# Schema (introspection)
# =========================

func _ensure_schema_cached() -> Dictionary:
	var calls := 0
	var path := _schema_path()

	# 1) Tente de charger le cache existant
	if FileAccess.file_exists(path):
		var raw := _read_json(path)
		var schema := _extract_schema_dict(raw) # ✅ IMPORTANT

		if not schema.is_empty():
			_load_schema_from_json(schema)

			# ✅ validation : si on a des champs root, c'est OK
			if _root_field_to_type.size() > 0:
				return {"status":"OK", "calls": 0}

		# cache invalide -> on le supprime pour forcer un refetch
		_delete_file(path)

	# 2) Fetch schema via introspection (1 appel)
	var q := """
	query SchemaMini {
	  __schema {
	    queryType {
	      name
	      fields {
	        name
	        type { kind name ofType { kind name ofType { kind name ofType { kind name } } } }
	      }
	    }
	    types {
	      name
	      kind
	      fields {
	        name
	        type { kind name ofType { kind name ofType { kind name ofType { kind name } } } }
	      }
	    }
	  }
	}
	"""

	var data: Dictionary = await api.gql(q, {})
	calls += 1

	if data.has("_error"):
		if String(data["_error"]) == "rate_limited":
			return {"status":"RATE_LIMIT", "calls": calls}
		return {"status":"ERROR", "calls": calls}

	var schema2: Dictionary = data.get("__schema", {}) as Dictionary
	if schema2.is_empty():
		return {"status":"ERROR", "calls": calls}

	# ✅ on stocke uniquement __schema (format stable)
	_write_json(path, schema2)
	_load_schema_from_json(schema2)

	if _root_field_to_type.size() == 0:
		return {"status":"ERROR", "calls": calls}

	return {"status":"OK", "calls": calls}


func _load_schema_from_json(schema: Dictionary) -> void:
	_root_field_to_type.clear()
	_type_to_scalar_fields.clear()

	var query_type: Dictionary = schema.get("queryType", {}) as Dictionary
	var q_fields: Array = query_type.get("fields", []) as Array

	# root field -> type name
	for f in q_fields:
		if typeof(f) != TYPE_DICTIONARY:
			continue
		var fd := f as Dictionary
		var fname := String(fd.get("name", ""))
		if fname.is_empty():
			continue
		var t := fd.get("type", {}) as Dictionary
		var named := _unwrap_named_type(t)
		var type_name := String(named.get("name", ""))
		if not type_name.is_empty():
			_root_field_to_type[fname] = type_name

	# type -> scalar fields
	var types: Array = schema.get("types", []) as Array
	for t in types:
		if typeof(t) != TYPE_DICTIONARY:
			continue
		var td := t as Dictionary
		var tname := String(td.get("name", ""))
		if tname.is_empty():
			continue
		var kind := String(td.get("kind", ""))
		if kind != "OBJECT":
			continue

		var fields: Array = td.get("fields", []) as Array
		var scalars: Array[String] = []
		var all_fields: Array[String] = []
		var field_types: Dictionary = {}
		for f in fields:
			if typeof(f) != TYPE_DICTIONARY:
				continue
			var fd := f as Dictionary
			var fname := String(fd.get("name", ""))
			all_fields.append(fname)
			if fname.is_empty():
				continue
			var ft := fd.get("type", {}) as Dictionary
			var named := _unwrap_named_type(ft)
			field_types[fname] = {
				"kind": String(named.get("kind", "")),
				"name": String(named.get("name", "")),
			}
			if String(named.get("kind", "")) == "SCALAR":
				scalars.append(fname)
		_type_field_to_named[tname] = field_types
		_type_to_all_fields[tname] = all_fields
		_type_to_scalar_fields[tname] = scalars
	_schema_loaded = true


func _gql_int_list(ids: Array) -> String:
	var parts: Array[String] = []
	for v in ids:
		parts.append(str(int(v)))
	return "[" + ",".join(parts) + "]"

func _norm(s: String) -> String:
	return s.to_lower().replace("_", "").replace("-", "")

func _find_scalar_in_type(type_name: String, patterns) -> String:
	# patterns = Array (strings ou trucs convertibles)
	if not _type_to_scalar_fields.has(type_name):
		return ""

	var scalars_any: Array = _type_to_scalar_fields[type_name]
	for f in scalars_any:
		var fs := String(f)
		var nf := _norm(fs)

		var ok := true
		for p in patterns:
			if nf.find(_norm(String(p))) == -1:
				ok = false
				break

		if ok:
			return fs

	return ""


func _relation_type_name(parent_type: String, field_name: String) -> String:
	if not _type_field_to_named.has(parent_type):
		return ""
	var m :Variant= _type_field_to_named[parent_type]
	if typeof(m) != TYPE_DICTIONARY:
		return ""
	var info :Variant= (m as Dictionary).get(field_name, null)
	if info == null or typeof(info) != TYPE_DICTIONARY:
		return ""
	return String((info as Dictionary).get("name", ""))

func _find_relation_field_that_has_child_scalar(parent_type: String, child_scalar_patterns) -> String:
	if not _type_to_all_fields.has(parent_type):
		return ""

	var fields_any: Array = _type_to_all_fields[parent_type]
	for f in fields_any:
		var fname := String(f)
		var child_type := _relation_type_name(parent_type, fname)
		if child_type.is_empty():
			continue

		var s := _find_scalar_in_type(child_type, child_scalar_patterns)
		if s != "":
			return fname

	return ""

func _build_child_selection(child_type: String, wanted_patterns_list, with_lang_filter: bool, order_by_patterns, limit: int) -> String:
	# wanted_patterns_list = [ ["flavor","text"], ["language","id"], ... ]
	var picked: Array[String] = []
	for pats in wanted_patterns_list:
		var f := _find_scalar_in_type(child_type, pats)
		if f != "":
			picked.append(f)

	# fallback minimal
	if picked.is_empty():
		for fb in [["id"], ["name"]]:
			var f2 := _find_scalar_in_type(child_type, fb)
			if f2 != "":
				picked.append(f2)
				break

	if picked.is_empty():
		return ""

	var args: Array[String] = []

	if with_lang_filter:
		var lang_col := _find_scalar_in_type(child_type, ["language","id"])
		if lang_col != "":
			args.append("where:{%s:{_in:%s}}" % [lang_col, _gql_int_list(KEEP_LANG_IDS)])

	var ob_col := ""
	if order_by_patterns != null and order_by_patterns.size() > 0:
		ob_col = _find_scalar_in_type(child_type, order_by_patterns)
		if ob_col != "":
			args.append("order_by:{%s:desc}" % ob_col)

	if limit > 0:
		args.append("limit:%d" % limit)

	var arg_txt := ""
	if args.size() > 0:
		arg_txt = "(" + ", ".join(args) + ")"

	return "%s{ %s }" % [arg_txt, _join_fields(picked)]


func _get_scalar_fields_for_key(key: String) -> Array[String]:
	if not _schema_loaded:
		return []

	var field := _resolve_root_field_for_key(key)
	if field.is_empty():
		return []

	var type_name := String(_root_field_to_type.get(field, ""))
	if type_name.is_empty():
		return []

	if not _type_to_scalar_fields.has(type_name):
		return []

	var scalars_any: Array = _type_to_scalar_fields[type_name]
	var out: Array[String] = []
	for s in scalars_any:
		out.append(String(s))
	out.sort()

	if out.has("id"):
		out.erase("id")
		out.push_front("id")
	return out

func _unwrap_named_type(t: Dictionary) -> Dictionary:
	# introspection: type peut être NON_NULL/LIST imbriqué, name peut être null
	var cur := t
	for i in range(20):
		var name :Variant = cur.get("name", null)
		if name != null and String(name) != "":
			return cur
		var ot = cur.get("ofType", null)
		if ot == null:
			break
		cur = ot as Dictionary
	return cur

# =========================
# Files / helpers
# =========================

func _pending_path() -> String:
	return "%s/pending_resources.json" % cache_root

func _schema_path() -> String:
	return "%s/schema_cache.json" % cache_root

func _manifest_path(resource: String) -> String:
	return "%s/%s/manifest.json" % [cache_root, resource]

func _state_path(resource: String) -> String:
	return "%s/%s/details_state.json" % [cache_root, resource]

func _index_path(resource: String) -> String:
	return "%s/%s/index.json" % [cache_root, resource]

func _load_pending() -> Array[String]:
	var path := _pending_path()
	if not FileAccess.file_exists(path):
		return []
	var d := _read_json(path)
	var arr: Array = d.get("resources", [])
	var out: Array[String] = []
	for r in arr:
		out.append(String(r))
	return out

func _save_pending(resources: Array[String]) -> void:
	_write_json(_pending_path(), {
		"resources": resources,
		"saved_utc": Time.get_datetime_string_from_system(true)
	})

func _save_state(path: String, mode: String, offset: int, gt_id: int, complete: bool) -> void:
	_write_json(path, {
		"mode": mode,
		"offset": offset,
		"gt_id": gt_id,
		"complete": complete,
		"saved_utc": Time.get_datetime_string_from_system(true)
	})

func _write_manifest(path: String, resource: String, fp: Dictionary) -> void:
	_write_json(path, {
		"resource": resource,
		"fingerprint": fp,
		"last_sync_utc": Time.get_datetime_string_from_system(true)
	})

func _write_index(path: String, resource: String, index_map: Dictionary, has_name: bool) -> void:
	var keys: Array[String] = []
	for k in index_map.keys():
		keys.append(String(k))
	keys.sort()

	var results: Array = []
	for k in keys:
		var e: Dictionary = index_map[k] as Dictionary
		var row := {"key": k}
		if has_name and e.has("name"):
			row["name"] = String(e["name"])
		results.append(row)

	_write_json(path, {
		"resource": resource,
		"count": results.size(),
		"results": results
	})

func _order_by_clause(resource: String, has_id: bool) -> String:
	if has_id:
		return "order_by:{id:asc}"
	if COMPOSITE_KEY_FIELDS.has(resource):
		var kfs: Array = COMPOSITE_KEY_FIELDS[resource]
		var parts: Array[String] = []
		for kf in kfs:
			parts.append("%s:asc" % String(kf))
		return "order_by:{%s}" % ", ".join(parts)
	return ""

func _wipe_resource(resource: String) -> void:
	var base := "%s/%s" % [cache_root, resource]
	_rm_dir_recursive("%s/details" % base)
	_delete_file("%s/manifest.json" % base)
	_delete_file("%s/details_state.json" % base)
	_delete_file("%s/index.json" % base)

func _rm_dir_recursive(dir_path: String) -> void:
	var abs := ProjectSettings.globalize_path(dir_path)
	if not DirAccess.dir_exists_absolute(abs):
		return
	var da := DirAccess.open(abs)
	if da == null:
		return

	da.list_dir_begin()
	while true:
		var name := da.get_next()
		if name == "":
			break
		if name == "." or name == "..":
			continue
		var full := abs.path_join(name)
		if da.current_is_dir():
			_rm_dir_recursive(ProjectSettings.localize_path(full))
		else:
			DirAccess.remove_absolute(full)
	da.list_dir_end()

	DirAccess.remove_absolute(abs)

func _delete_file(path: String) -> void:
	var abs := ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(abs)

func _ensure_dir(path: String) -> void:
	var abs := ProjectSettings.globalize_path(path)
	DirAccess.make_dir_recursive_absolute(abs)

func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}

func _write_json(path: String, data: Variant) -> void:
	_ensure_dir(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(data, "\t"))

func _join_fields(fields: Array[String]) -> String:
	# "id name cost ..."
	var out := ""
	for i in range(fields.size()):
		out += fields[i]
		if i < fields.size() - 1:
			out += " "
	return out

func _sha256(text: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(text.to_utf8_buffer())
	return ctx.finish().hex_encode()

func _emit_finish(status: String, calls_used: int) -> void:
	var pending := _load_pending()
	emit_signal("offline_finished", status, calls_used, pending.size())

func _emit_dbg(_s: String) -> void:
	# print(_s) # décommente si tu veux
	pass

func _norm_field_name(s: String) -> String:
	# normalise pour matcher "berry_firmness" == "berryfirmness"
	return s.to_lower().replace("-", "_").replace("_", "")

func _resolve_root_field_for_key(key: String) -> String:
	# 0) override
	if KEY_FIELD_OVERRIDES.has(key):
		var forced := String(KEY_FIELD_OVERRIDES[key])
		if _root_field_to_type.has(forced):
			return forced

	# 1) match exact
	if _root_field_to_type.has(key):
		return key

	# 2) déjà résolu
	if _resolved_field_for_key.has(key):
		return String(_resolved_field_for_key[key])

	# 3) match normalisé (retire _ et -)
	var target := _norm_field_name(key)
	for f in _root_field_to_type.keys():
		var fs := String(f)
		if _norm_field_name(fs) == target:
			_resolved_field_for_key[key] = fs
			return fs

	# 4) fallback prefix/suffix (move_ailment => movemetaailment)
	var parts := key.split("_", false)
	if parts.size() >= 2:
		var first := parts[0]                # "move"
		var last := parts[parts.size() - 1]  # "ailment"
		var candidates: Array[String] = []

		for f in _root_field_to_type.keys():
			var fs := String(f)
			if fs.begins_with(first) and fs.ends_with(last) and not fs.ends_with("_aggregate"):
				candidates.append(fs)

		if candidates.size() == 1:
			_resolved_field_for_key[key] = candidates[0]
			return candidates[0]

	return ""


func debug_root_fields_contains(s: String) -> Array[String]:
	var out: Array[String] = []
	var needle := s.to_lower()
	for k in _root_field_to_type.keys():
		var ks := String(k).to_lower()
		if ks.find(needle) != -1:
			out.append(String(k))
	out.sort()
	return out

func _extract_schema_dict(raw: Dictionary) -> Dictionary:
	# format A: directement __schema
	if raw.has("queryType") and raw.has("types"):
		return raw

	# format B: wrapper {"__schema": {...}}
	if raw.has("__schema") and typeof(raw["__schema"]) == TYPE_DICTIONARY:
		return raw["__schema"] as Dictionary

	# format C: wrapper {"data": {"__schema": {...}}}
	if raw.has("data") and typeof(raw["data"]) == TYPE_DICTIONARY:
		var d := raw["data"] as Dictionary
		if d.has("__schema") and typeof(d["__schema"]) == TYPE_DICTIONARY:
			return d["__schema"] as Dictionary

	return {}

func debug_type_fields(type_name: String, contains: String = "") -> Array[String]:
	var out: Array[String] = []
	if not _type_to_all_fields.has(type_name):
		return out
	var needle := contains.to_lower()
	for f in _type_to_all_fields[type_name]:
		var fs := String(f)
		if needle == "" or fs.to_lower().find(needle) != -1:
			out.append(fs)
	out.sort()
	return out

func debug_root_type_of(root_field: String) -> String:
	return String(_root_field_to_type.get(root_field, ""))

func debug_fields_for_root(root_field: String, contains: String = "") -> Array[String]:
	var type_name := debug_root_type_of(root_field)
	if type_name.is_empty():
		return []
	if not _type_to_all_fields.has(type_name):
		return []

	var out: Array[String] = []
	var needle := contains.to_lower()
	for f in _type_to_all_fields[type_name]:
		var fs := String(f)
		if needle == "" or fs.to_lower().find(needle) != -1:
			out.append(fs)
	out.sort()
	return out

func debug_print_schema() -> void:
	print("cache_root=", cache_root)
	print("schema_path=", _schema_path(), " exists=", FileAccess.file_exists(_schema_path()))

	var res := await _ensure_schema_cached()
	print("ensure_schema_cached() => ", res)

	print("[Schema] loaded=", _schema_loaded, " root_fields=", _root_field_to_type.size())
	print("root contains 'pokemon' =", debug_root_fields_contains("pokemon"))
	print("root contains 'move'   =", debug_root_fields_contains("move"))

func _selection_for_resource(resource: String, root_field: String, scalars: Array[String]) -> String:
	# 1) override manuel si tu veux
	if CUSTOM_SELECTION.has(resource):
		return String(CUSTOM_SELECTION[resource]).strip_edges()

	# 2) auto-enrich pour pokemon_species (genus + flavor + pokedex numbers)
	if resource == "pokemon_species":
		var type_name := String(_root_field_to_type.get(root_field, ""))
		if type_name.is_empty():
			return _join_fields(scalars)

		var sel := _join_fields(scalars)

		# relation "genus" (souvent table names)
		var genus_rel := _find_relation_field_that_has_child_scalar(type_name, ["genus"])
		if genus_rel != "":
			var child_type := _relation_type_name(type_name, genus_rel)
			var child_sel := _build_child_selection(
				child_type,
				[["genus"], ["language","id"]],
				true,   # filtre fr/en
				[],     # pas d'ordre
				10
			)
			if child_sel != "":
				sel += " %s%s" % [genus_rel, child_sel]

		# relation "flavor text"
		var flavor_rel := _find_relation_field_that_has_child_scalar(type_name, ["flavor","text"])
		if flavor_rel != "":
			var child_type2 := _relation_type_name(type_name, flavor_rel)
			var child_sel2 := _build_child_selection(
				child_type2,
				[["flavor","text"], ["language","id"], ["version","id"]],
				true,                 # filtre fr/en
				["version","id"],      # ordre version desc si dispo
				40                    # limite
			)
			if child_sel2 != "":
				sel += " %s%s" % [flavor_rel, child_sel2]
				# -------- Egg groups (relation) --------
		# On cherche une relation dont le "child type" contient un champ style egg_group_id
		var egg_rel := _find_relation_field_that_has_child_scalar(type_name, ["egg", "group", "id"])
		if egg_rel != "":
			var egg_child_type := _relation_type_name(type_name, egg_rel)
			var egg_child_sel := _build_child_selection(
				egg_child_type,
				[["pokemon", "species", "id"], ["egg", "group", "id"]],
				false,  # pas de filtre langue
				[],     # pas d'ordre
				10
			)
			if egg_child_sel != "":
				sel += " %s%s" % [egg_rel, egg_child_sel]
		
		# relation "pokedex entry number"
		# on tente entry_number, sinon pokedex_number
		var dex_rel := _find_relation_field_that_has_child_scalar(type_name, ["entry","number"])
		if dex_rel == "":
			dex_rel = _find_relation_field_that_has_child_scalar(type_name, ["pokedex","number"])
		if dex_rel != "":
			var child_type3 := _relation_type_name(type_name, dex_rel)
			var child_sel3 := _build_child_selection(
				child_type3,
				[["entry","number"], ["pokedex","id"], ["pokedex","number"]],
				false,
				[],
				80
			)
			if child_sel3 != "":
				sel += " %s%s" % [dex_rel, child_sel3]

		return sel

	# ✅ enrich ability: noms localisés + descriptions
	if resource == "ability":
		var type_name := String(_root_field_to_type.get(root_field, ""))
		if type_name.is_empty():
			return _join_fields(scalars)

		var sel := _join_fields(scalars)

		# ---- NAMES (FR/EN) ----
		# On cherche une relation qui ressemble à "names" et qui contient { name, language_id }
		var names_rel := _find_relation_field(type_name, "name", [["name"], ["language","id"]])
		if names_rel != "":
			var child_type := _relation_type_name(type_name, names_rel)
			var child_sel := _build_child_selection(
				child_type,
				[["name"], ["language","id"]],
				true,      # filtre fr/en
				[],        # pas d'ordre
				10
			)
			if child_sel != "":
				sel += " %s%s" % [names_rel, child_sel]

		# ---- EFFECT ENTRIES (FR/EN) ----
		# On préfère short_effect, sinon effect
		var effect_rel := ""
		effect_rel = _find_relation_field(type_name, "effect", [["short","effect"], ["language","id"]])
		if effect_rel == "":
			effect_rel = _find_relation_field(type_name, "effect", [["effect"], ["language","id"]])

		if effect_rel != "":
			var child_type2 := _relation_type_name(type_name, effect_rel)

			# essaie de trier par version_group_id si présent, sinon pas grave
			var child_sel2 := _build_child_selection(
				child_type2,
				[["short","effect"], ["effect"], ["language","id"], ["version","group","id"]],
				true,                     # filtre fr/en
				["version","group","id"],  # ordre desc si dispo
				30
			)
			if child_sel2 == "":
				# fallback sans version_group
				child_sel2 = _build_child_selection(
					child_type2,
					[["short","effect"], ["effect"], ["language","id"]],
					true,
					[],
					30
				)

			if child_sel2 != "":
				sel += " %s%s" % [effect_rel, child_sel2]

		return sel

	# 3) par défaut : scalars only (rapide)
	return _join_fields(scalars)

func _child_has_all_scalars(child_type: String, patterns_list: Array) -> bool:
	# patterns_list = [ ["name"], ["language","id"], ... ]
	for pats in patterns_list:
		var f := _find_scalar_in_type(child_type, pats)
		if f == "":
			return false
	return true

func _find_relation_field(parent_type: String, field_hint: String, child_required_patterns: Array) -> String:
	# field_hint: "name", "effect" ... (peut être "")
	if not _type_to_all_fields.has(parent_type):
		return ""

	var hint := field_hint.to_lower()

	for f in (_type_to_all_fields[parent_type] as Array):
		var fname := String(f)
		if hint != "" and fname.to_lower().find(hint) == -1:
			continue

		var child_type := _relation_type_name(parent_type, fname)
		if child_type.is_empty():
			continue

		if _child_has_all_scalars(child_type, child_required_patterns):
			return fname

	return ""


func _extract_egg_group_ids_from_species_obj(obj: Dictionary) -> Array[int]:
	var tmp: Array[int] = []
	for k in obj.keys():
		var v :Variant= obj[k]
		if typeof(v) != TYPE_ARRAY:
			continue
		for it in (v as Array):
			if typeof(it) != TYPE_DICTIONARY:
				continue
			var d := it as Dictionary
			for dk in d.keys():
				var ks := String(dk).to_lower()
				if ks.find("egg_group_id") != -1:
					var idv := int(d.get(dk, 0))
					if idv > 0:
						tmp.append(idv)

	tmp.sort()
	var uniq: Array[int] = []
	for idv in tmp:
		if uniq.is_empty() or uniq[uniq.size() - 1] != idv:
			uniq.append(idv)
	return uniq


func force_resync_one(resource: String) -> void:
	_wipe_resource(resource)
	var pending := _load_pending()
	if not pending.has(resource):
		pending.push_front(resource)
		_save_pending(pending)


func debug_print_pending() -> void:
	var p := _load_pending()
	print("[Pending] count=", p.size())
	print("[Pending] first10=", p.slice(0, min(10, p.size())))
	print("[Pending] contains pokemon_type? ", p.has("pokemon_type"))
	print("[Pending] contains pokemon_move? ", p.has("pokemon_move"))
