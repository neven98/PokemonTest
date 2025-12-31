extends Node
class_name PokemonGenerator

func make(pokemon_id: int, level: int = 5, version_group_id: int = 0) -> PokemonInstance:
	return PokemonInstance.new(pokemon_id, level, version_group_id)

func make_by_name(pokemon_name: String, level: int = 5, version_group_id: int = 0) -> PokemonInstance:
	var p := PokeDb.get_entity_by_name("pokemon", pokemon_name)
	var id := int(p.get("id", 0))
	return PokemonInstance.new(id, level, version_group_id)
