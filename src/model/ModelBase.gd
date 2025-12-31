extends RefCounted
class_name ModelBase

var id: int
var resource: String
var _data: Dictionary

func _init(p_resource: String, p_id: int) -> void:
	resource = p_resource
	id = p_id
	_data = PokeRepo.get_json(resource, id)

func exists() -> bool:
	return not _data.is_empty()

func raw() -> Dictionary:
	return _data

func name() -> String:
	return str(_data.get("name", ""))

# --- helpers typed ---
func _i(key: String, def: int = 0) -> int:
	var v: Variant = _data.get(key, null)
	if v == null: return def
	if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT: return int(v)
	if typeof(v) == TYPE_STRING and String(v).is_valid_int(): return int(v)
	return def

func _s(key: String, def: String = "") -> String:
	var v: Variant = _data.get(key, null)
	return def if v == null else str(v)

func _b(key: String, def: bool = false) -> bool:
	var v: Variant = _data.get(key, null)
	if v == null: return def
	if typeof(v) == TYPE_BOOL: return bool(v)
	if typeof(v) == TYPE_INT: return int(v) != 0
	if typeof(v) == TYPE_STRING:
		var t := String(v).to_lower()
		if t == "true": return true
		if t == "false": return false
	return def
