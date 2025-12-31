extends Node

const EntityType := preload("res://src/data/PokeEntityType.gd")

@onready var Registry: PokeModelRegistry = get_node("/root/PokeModelRegistry")

func get_by_id(kind: int, id: int) -> RefCounted:
	var resource := EntityType.to_resource(kind)
	if resource.is_empty():
		return null

	var data := PokeDb.get_entity(resource, id)
	if data.is_empty():
		return null

	return Registry.make_model(kind, resource, data)

func get_by_name(kind: int, name: String) -> RefCounted:
	var resource := EntityType.to_resource(kind)
	if resource.is_empty():
		return null

	var data := PokeDb.get_entity_by_name(resource, name)
	if data.is_empty():
		return null

	return Registry.make_model(kind, resource, data)
