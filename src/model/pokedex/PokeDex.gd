extends Node

# ---------- Pokemon (forme/base) ----------
func pokemon(pokemon_id: int) -> Dictionary:
	return PokeDb.get_entity("pokemon", pokemon_id)

func pokemon_by_name(name: String) -> Dictionary:
	return PokeDb.get_entity_by_name("pokemon", name)

# ---------- Espèce ----------
func species(species_id: int) -> Dictionary:
	return PokeDb.get_entity("pokemon_species", species_id)

func species_from_pokemon(pokemon_id: int) -> Dictionary:
	var p := pokemon(pokemon_id)
	var sid := int(p.get("pokemon_species_id", -1))
	return {} if sid <= 0 else species(sid)

# ---------- Types / Moves / etc (données, pas instance) ----------
func type(type_id: int) -> Dictionary:
	return PokeDb.get_entity("type", type_id)

func move(move_id: int) -> Dictionary:
	return PokeDb.get_entity("move", move_id)

func types_names_for_pokemon(pokemon_id: int) -> Array[String]:
	var ids := PokeDb.pokemon_types_ids(pokemon_id)
	var out: Array[String] = []
	for tid in ids:
		out.append(str(type(tid).get("name", "")))
	return out
