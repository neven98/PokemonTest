extends Object
class_name PokeEntityType

enum Kind {
	UNKNOWN,

	# Berries
	BERRY,
	BERRY_FIRMNESS,
	BERRY_FLAVOR,

	# Contests
	CONTEST_TYPE,
	CONTEST_EFFECT,
	SUPER_CONTEST_EFFECT,

	# Encounters
	ENCOUNTER_METHOD,
	ENCOUNTER_CONDITION,
	ENCOUNTER_CONDITION_VALUE,

	# Evolution
	EVOLUTION_CHAIN,
	EVOLUTION_TRIGGER,

	# Games
	GENERATION,
	POKEDEX,
	VERSION,
	VERSION_GROUP,

	# Items
	ITEM,
	ITEM_ATTRIBUTE,
	ITEM_CATEGORY,
	ITEM_FLING_EFFECT,
	ITEM_POCKET,

	# Locations
	LOCATION,
	LOCATION_AREA,
	PAL_PARK_AREA,
	REGION,

	# Machines
	MACHINE,

	# Moves (= attaques)
	MOVE,
	MOVE_AILMENT,
	MOVE_BATTLE_STYLE,
	MOVE_CATEGORY,
	MOVE_DAMAGE_CLASS,
	MOVE_LEARN_METHOD,
	MOVE_TARGET,

	# Pokemon
	ABILITY,
	CHARACTERISTIC,
	EGG_GROUP,
	GENDER,
	GROWTH_RATE,
	NATURE,
	POKEATHLON_STAT,
	POKEMON,
	POKEMON_COLOR,
	POKEMON_FORM,
	POKEMON_HABITAT,
	POKEMON_SHAPE,
	POKEMON_SPECIES,
	STAT,
	TYPE,

	# Utility
	LANGUAGE,
}

const KIND_TO_RESOURCE := {
	Kind.BERRY: "berry",
	Kind.BERRY_FIRMNESS: "berry_firmness",
	Kind.BERRY_FLAVOR: "berry_flavor",

	Kind.CONTEST_TYPE: "contest_type",
	Kind.CONTEST_EFFECT: "contest_effect",
	Kind.SUPER_CONTEST_EFFECT: "super_contest_effect",

	Kind.ENCOUNTER_METHOD: "encounter_method",
	Kind.ENCOUNTER_CONDITION: "encounter_condition",
	Kind.ENCOUNTER_CONDITION_VALUE: "encounter_condition_value",

	Kind.EVOLUTION_CHAIN: "evolution_chain",
	Kind.EVOLUTION_TRIGGER: "evolution_trigger",

	Kind.GENERATION: "generation",
	Kind.POKEDEX: "pokedex",
	Kind.VERSION: "version",
	Kind.VERSION_GROUP: "version_group",

	Kind.ITEM: "item",
	Kind.ITEM_ATTRIBUTE: "item_attribute",
	Kind.ITEM_CATEGORY: "item_category",
	Kind.ITEM_FLING_EFFECT: "item_fling_effect",
	Kind.ITEM_POCKET: "item_pocket",

	Kind.LOCATION: "location",
	Kind.LOCATION_AREA: "location_area",
	Kind.PAL_PARK_AREA: "pal_park_area",
	Kind.REGION: "region",

	Kind.MACHINE: "machine",

	Kind.MOVE: "move",
	Kind.MOVE_AILMENT: "move_ailment",
	Kind.MOVE_BATTLE_STYLE: "move_battle_style",
	Kind.MOVE_CATEGORY: "move_category",
	Kind.MOVE_DAMAGE_CLASS: "move_damage_class",
	Kind.MOVE_LEARN_METHOD: "move_learn_method",
	Kind.MOVE_TARGET: "move_target",

	Kind.ABILITY: "ability",
	Kind.CHARACTERISTIC: "characteristic",
	Kind.EGG_GROUP: "egg_group",
	Kind.GENDER: "gender",
	Kind.GROWTH_RATE: "growth_rate",
	Kind.NATURE: "nature",
	Kind.POKEATHLON_STAT: "pokeathlon_stat",
	Kind.POKEMON: "pokemon",
	Kind.POKEMON_COLOR: "pokemon_color",
	Kind.POKEMON_FORM: "pokemon_form",
	Kind.POKEMON_HABITAT: "pokemon_habitat",
	Kind.POKEMON_SHAPE: "pokemon_shape",
	Kind.POKEMON_SPECIES: "pokemon_species",
	Kind.STAT: "stat",
	Kind.TYPE: "type",

	Kind.LANGUAGE: "language",
}

static func to_resource(kind: int) -> String:
	return String(KIND_TO_RESOURCE.get(kind, ""))

static func from_resource(resource: String) -> int:
	for k in KIND_TO_RESOURCE.keys():
		if String(KIND_TO_RESOURCE[k]) == resource:
			return int(k)
	return Kind.UNKNOWN
