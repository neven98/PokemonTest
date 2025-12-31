extends Node

# petit cache mémoire optionnel
var _cache: Dictionary = {} # key: "resource:id" -> Dictionary

func get_json(resource: String, id: int) -> Dictionary:
	if id <= 0: return {}
	var k := "%s:%d" % [resource, id]
	if _cache.has(k):
		return _cache[k]
	var d := PokeDb.get_entity(resource, id)
	if not d.is_empty():
		_cache[k] = d
	return d

func get_json_by_name(resource: String, name: String) -> Dictionary:
	if name.is_empty(): return {}
	# pas mis en cache volontairement (ou tu le fais si tu veux)
	return PokeDb.get_entity_by_name(resource, name)

func clear_cache() -> void:
	_cache.clear()

# --- helpers relations (wrappers DB) ---
func pokemon_type_ids(pokemon_id: int) -> Array[int]:
	return PokeDb.pokemon_types_ids(pokemon_id)

func pokemon_stats_rows(pokemon_id: int) -> Array[Dictionary]:
	return PokeDb.pokemon_stats_rows(pokemon_id)

func pokemon_moves_upto_level(pokemon_id: int, version_group_id: int, learn_method_id: int, level: int) -> Array[Dictionary]:
	return PokeDb.pokemon_moves_upto_level(pokemon_id, version_group_id, learn_method_id, level)

func best_vg_for_moves_upto_level(pokemon_id: int, allowed_methods: Array[int], level: int) -> int:
	if allowed_methods.is_empty():
		return 0

	# on prend le VG max qui a au moins 1 move dans les méthodes autorisées
	var best := 0
	for m in allowed_methods:
		var rows := PokeDb._query_bind(
			"SELECT MAX(version_group_id) AS vg FROM dex_pokemon_move "
			+ "WHERE pokemon_id=? AND move_learn_method_id=? AND level<=?;",
			[pokemon_id, m, level]
		)
		if rows.size() > 0:
			best = maxi(best, int((rows[0] as Dictionary).get("vg", 0)))
	return best
