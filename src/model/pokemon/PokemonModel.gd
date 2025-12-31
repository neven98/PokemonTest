extends ModelBase
class_name PokemonModel

func _init(pokemon_id: int) -> void:
	super._init("pokemon", pokemon_id)

func types_ids() -> Array[int]:
	return PokeRepo.pokemon_type_ids(id)

func base_stats() -> Array[Dictionary]:
	return PokeRepo.pokemon_stats_rows(id)

# “suggestion” de moves selon des règles (pas de learn_method unique)
func default_move_ids_for_level(level: int, version_group_id: int, allowed_methods: Array[int]) -> Array[int]:
	return PokeRules.pick_default_moves(id, level, version_group_id, allowed_methods)
