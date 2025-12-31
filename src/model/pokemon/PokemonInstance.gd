extends RefCounted
class_name PokemonInstance

var pokemon_id: int
var level: int
var version_group_id: int

var allowed_learn_methods: Array[int] = [] # ex: [1,4]
var move_ids: Array[int] = [0, 0, 0, 0]

func _init(p_id: int, p_level: int = 5, vg_id: int = 0) -> void:
	pokemon_id = max(1, p_id)
	level = max(1, p_level)
	version_group_id = vg_id if vg_id > 0 else PokeConfig.get_version_group_id()

	allowed_learn_methods = PokeRules.default_allowed_methods_for_game()
	auto_fill_moves_with_rules()

func auto_fill_moves_with_rules() -> void:
	var ids := PokeRules.pick_default_moves(pokemon_id, level, version_group_id, allowed_learn_methods)
	move_ids = ids # déjà pad à 4

func moves_names() -> Array[String]:
	var out: Array[String] = []
	for mid in move_ids:
		if mid <= 0:
			out.append("")
		else:
			out.append(MoveModel.new(mid).name())
	return out
