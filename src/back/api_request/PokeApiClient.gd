extends Node
class_name PokeApiClient

const ENDPOINT := "https://graphql.pokeapi.co/v1beta2"

@export var min_seconds_between_calls := 1.0
@export var max_retries := 2
@export var retry_delay_sec := 1.5

@onready var http := HTTPRequest.new()
var _last_call_ms := 0

func _ready() -> void:
	add_child(http)

func gql(query: String, variables: Dictionary = {}) -> Dictionary:
	await _throttle()

	var body := {
		"query": query,
		"variables": variables
	}
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Accept: application/json",
	])

	for attempt in range(max_retries + 1):
		var err := http.request(ENDPOINT, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
		if err != OK:
			return {"_error": "request_failed", "_code": -1}

		var result = await http.request_completed
		var code: int = result[1]
		var raw: PackedByteArray = result[3]
		var txt := raw.get_string_from_utf8()

		# Rate limit
		if code == 429:
			return {"_error": "rate_limited", "_code": code, "_raw": txt}

		# Downtime / instabilité
		if code >= 500 and attempt < max_retries:
			await get_tree().create_timer(retry_delay_sec).timeout
			continue

		if code != 200:
			return {"_error": "http_error", "_code": code, "_raw": txt}

		var parsed = JSON.parse_string(txt)
		if typeof(parsed) != TYPE_DICTIONARY:
			return {"_error": "bad_json", "_code": code, "_raw": txt}

		if (parsed as Dictionary).has("errors"):
			return {"_error": "gql_error", "_code": code, "errors": (parsed as Dictionary)["errors"]}

		return (parsed as Dictionary).get("data", {})

	return {"_error": "unknown", "_code": -1}

func _throttle() -> void:
	var now := Time.get_ticks_msec()
	var delta := now - _last_call_ms
	var min_ms := int(min_seconds_between_calls * 1000.0)
	if delta < min_ms:
		await get_tree().create_timer(float(min_ms - delta) / 1000.0).timeout
	_last_call_ms = Time.get_ticks_msec()

# -----------------------------
# REST + cache disque (JSON)
# -----------------------------

const REST_BASE := "https://pokeapi.co/api/v2"

@export var rest_cache_root := "user://poke_cache/v1beta2" # même style que toi
@export var rest_timeout_sec := 30.0

func rest_get(relative_path: String) -> Dictionary:
	# relative_path ex: "/evolution-chain/?limit=20&offset=0" ou "/evolution-chain/1/"
	await _throttle()

	var url := REST_BASE + relative_path
	var headers := PackedStringArray([
		"Accept: application/json",
	])

	for attempt in range(max_retries + 1):
		var err := http.request(url, headers, HTTPClient.METHOD_GET)
		if err != OK:
			return {"_error": "request_failed", "_code": -1, "_url": url}

		var result = await http.request_completed
		var code: int = result[1]
		var raw: PackedByteArray = result[3]
		var txt := raw.get_string_from_utf8()

		if code == 429:
			return {"_error": "rate_limited", "_code": code, "_raw": txt, "_url": url}

		if code >= 500 and attempt < max_retries:
			await get_tree().create_timer(retry_delay_sec).timeout
			continue

		if code < 200 or code >= 300:
			return {"_error": "http_error", "_code": code, "_raw": txt, "_url": url}

		var parsed = JSON.parse_string(txt)
		if typeof(parsed) != TYPE_DICTIONARY:
			return {"_error": "bad_json", "_code": code, "_raw": txt, "_url": url}

		return parsed as Dictionary

	return {"_error": "unknown", "_code": -1, "_url": url}

func rest_cached(
	relative_path: String, # ex: "/evolution-chain/1/"
	cache_subdir: String,  # ex: "evolution_chain_rest"
	cache_key: String      # ex: "1"  (nom de fichier)
) -> Dictionary:
	# 1) chemin cache
	var clean_key := cache_key.strip_edges()
	var cache_path := "%s/%s/details/%s.json" % [rest_cache_root, cache_subdir, clean_key]
	_ensure_dir(cache_path.get_base_dir())

	# 2) si existe -> read
	if FileAccess.file_exists(cache_path):
		var cached := _read_json(cache_path)
		if not cached.is_empty():
			cached["_cache"] = "HIT"
			cached["_cache_path"] = cache_path
			return cached
		# si fichier corrompu -> on retente en refaisant la requête

	# 3) requête REST
	await _throttle()

	var url := REST_BASE + relative_path
	var headers := PackedStringArray([
		"Accept: application/json",
		"User-Agent: Godot (offline-cache)",
	])

	for attempt in range(max_retries + 1):
		var err := http.request(url, headers, HTTPClient.METHOD_GET)
		if err != OK:
			return {"_error": "request_failed", "_code": -1, "_url": url}

		var result = await http.request_completed
		var code: int = result[1]
		var raw: PackedByteArray = result[3]
		var txt := raw.get_string_from_utf8()

		if code == 429:
			return {"_error": "rate_limited", "_code": code, "_raw": txt, "_url": url}

		if code >= 500 and attempt < max_retries:
			await get_tree().create_timer(retry_delay_sec).timeout
			continue

		if code < 200 or code >= 300:
			return {"_error": "http_error", "_code": code, "_raw": txt, "_url": url}

		var parsed = JSON.parse_string(txt)
		if typeof(parsed) != TYPE_DICTIONARY:
			return {"_error": "bad_json", "_code": code, "_raw": txt, "_url": url}

		# 4) write cache
		_write_json(cache_path, parsed)

		(parsed as Dictionary)["_cache"] = "MISS"
		(parsed as Dictionary)["_cache_path"] = cache_path
		return parsed

	return {"_error": "unknown", "_code": -1, "_url": url}


# Helper spécifique: evolution-chain/{id}
func evolution_chain_cached(chain_id: int) -> Dictionary:
	return await rest_cached(
		"/evolution-chain/%d/" % chain_id,
		"evolution_chain_rest",
		str(chain_id)
	)

# ---------- file helpers (local) ----------
func _ensure_dir(path: String) -> void:
	var abs := ProjectSettings.globalize_path(path)
	DirAccess.make_dir_recursive_absolute(abs)

func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed :Variant= JSON.parse_string(f.get_as_text())
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}

func _write_json(path: String, data: Variant) -> void:
	_ensure_dir(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(data, "\t"))
