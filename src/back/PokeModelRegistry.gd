extends Node
class_name PokeModelRegistry

const EntityType := preload("res://src/data/PokeEntityType.gd")

const MoveModel := preload("res://src/model/move/MoveModel.gd")
const ItemModel := preload("res://src/model/item/ItemModel.gd")
const PokemonModel := preload("res://src/model/pokemon/PokemonModel.gd")

var _map: Dictionary = {}

func _ready() -> void:
	_build_default_map()

func _build_default_map() -> void:
	_map.clear()
	_map[EntityType.Kind.MOVE] = MoveModel
	_map[EntityType.Kind.ITEM] = ItemModel
	_map[EntityType.Kind.POKEMON] = PokemonModel

func resolve(kind: int) -> Script:
	return _map.get(kind, null)

# ✅ Crée un modèle à partir d'un ID
func make_by_id(kind: int, id: int) -> RefCounted:
	var script: Script = resolve(kind)
	if script == null:
		return null
	return script.new(id)
