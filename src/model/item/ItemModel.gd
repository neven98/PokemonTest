extends ModelBase
class_name ItemModel

func _init(item_id: int) -> void:
	super._init("item", item_id)

func cost() -> int: return _i("cost", 0)
func fling_power() -> int: return _i("fling_power", -1)
func category_id() -> int: return _i("item_category_id", -1)

func category_name() -> String:
	var cid := category_id()
	if cid <= 0: return ""
	return str(PokeRepo.get_json("item_category", cid).get("name", ""))

func summary() -> String:
	if not exists(): return "Item #%d (missing)" % id
	return "%s (cost=%d cat=%s)" % [name(), cost(), category_name()]
