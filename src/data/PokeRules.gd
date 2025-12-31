extends Node

# PokeAPI move_learn_method ids (classiques)
const LEARN_LEVEL_UP := 1
const LEARN_EGG := 2
const LEARN_TUTOR := 3
const LEARN_MACHINE := 4

# règle par défaut “jeu”
func default_allowed_methods_for_game() -> Array[int]:
	# Pour commencer simple (Gen1-like) : level-up puis TM si besoin
	return [LEARN_LEVEL_UP, LEARN_MACHINE]

func pick_default_moves(pokemon_id: int, level: int, version_group_id: int, allowed_methods: Array[int]) -> Array[int]:
	if allowed_methods.is_empty():
		allowed_methods = default_allowed_methods_for_game()

	var vg := version_group_id
	if vg <= 0:
		vg = PokeConfig.get_version_group_id()

	# 1) on tente vg demandé
	var picked: Array[int] = _pick_for_vg(pokemon_id, level, vg, allowed_methods)
	if picked.size() > 0:
		return _pad4(picked)

	# 2) fallback : vg le + récent avec des moves (dans les méthodes autorisées)
	var best_vg := PokeRepo.best_vg_for_moves_upto_level(pokemon_id, allowed_methods, level)
	if best_vg > 0 and best_vg != vg:
		picked = _pick_for_vg(pokemon_id, level, best_vg, allowed_methods)

	return _pad4(picked)

func _pick_for_vg(pokemon_id: int, level: int, vg: int, allowed_methods: Array[int]) -> Array[int]:
	# Stratégie stable:
	# - on remplit d’abord avec level-up (si autorisé)
	# - puis on complète avec les autres méthodes dans l’ordre
	var out: Array[int] = []
	var seen := {}

	for m in allowed_methods:
		var rows := PokeRepo.pokemon_moves_upto_level(pokemon_id, vg, m, level)
		if rows.is_empty():
			continue

		# on prend les derniers distincts de CETTE méthode
		for i in range(rows.size() - 1, -1, -1):
			var mid := int(rows[i].get("move_id", 0))
			if mid <= 0: continue
			if seen.has(mid): continue
			seen[mid] = true
			out.append(mid)
			if out.size() >= 4:
				return out

	return out

func _pad4(arr: Array[int]) -> Array[int]:
	var out := arr.duplicate()
	while out.size() < 4:
		out.append(0)
	if out.size() > 4:
		out.resize(4)
	return out
