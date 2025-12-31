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
