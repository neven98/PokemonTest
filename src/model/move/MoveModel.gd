extends ModelBase
class_name MoveModel

func _init(move_id: int) -> void:
	super._init("move", move_id)

func accuracy() -> int:
	var v: Variant = raw().get("accuracy", null)
	return -1 if v == null else int(v)

func power() -> int:
	var v: Variant = raw().get("power", null)
	return -1 if v == null else int(v)

func pp() -> int:
	var v: Variant = raw().get("pp", null)
	return -1 if v == null else int(v)

func priority() -> int:
	var v: Variant = raw().get("priority", null)
	return 0 if v == null else int(v)

func type_id() -> int: return _i("type_id", -1)
func damage_class_id() -> int: return _i("move_damage_class_id", -1)
func target_id() -> int: return _i("move_target_id", -1)

func type_name() -> String:
	var tid := type_id()
	if tid <= 0: return ""
	return str(PokeRepo.get_json("type", tid).get("name", ""))

func summary() -> String:
	if not exists(): return "Move #%d (missing)" % id
	return "%s (pow=%d acc=%d pp=%d type=%s)" % [name(), power(), accuracy(), pp(), type_name()]
