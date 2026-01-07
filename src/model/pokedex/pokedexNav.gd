extends Node

var entries: Array[Dictionary] = []
var index: int = -1
var return_scene: String = "res://src/model/pokedex/pokedex_menu.tscn"

func set_context(new_entries: Array[Dictionary], new_index: int, back_scene: String = "") -> void:
	entries = new_entries.duplicate(true)
	index = clamp(new_index, 0, entries.size() - 1) if entries.size() > 0 else -1
	if back_scene != "":
		return_scene = back_scene

func has_context() -> bool:
	return index >= 0 and index < entries.size()

func current() -> Dictionary:
	return entries[index] if has_context() else {}

func can_prev() -> bool:
	return has_context() and index > 0

func can_next() -> bool:
	return has_context() and (index + 1) < entries.size()

func prev() -> void:
	if can_prev():
		index -= 1

func next() -> void:
	if can_next():
		index += 1
