extends RefCounted
class_name PokeKind

enum Kind { POKEMON, MOVE, ITEM, TYPE, ABILITY, SPECIES }

static func resource_of(kind: int) -> String:
	match kind:
		Kind.POKEMON: return "pokemon"
		Kind.MOVE: return "move"
		Kind.ITEM: return "item"
		Kind.TYPE: return "type"
		Kind.ABILITY: return "ability"
		Kind.SPECIES: return "pokemon_species"
		_: return ""
