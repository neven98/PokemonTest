extends Node

signal version_group_changed(new_id: int)

var default_version_group_id: int = 0

func _ready() -> void:
	# attend que la DB soit prête
	if PokeDb.is_ready():
		_load_or_compute_default()
	else:
		PokeDb.db_ready.connect(_load_or_compute_default)

func get_version_group_id() -> int:
	return default_version_group_id

func set_version_group_id(vg_id: int) -> void:
	default_version_group_id = max(0, vg_id)
	PokeDb.meta_set("default_version_group_id", str(default_version_group_id))
	emit_signal("version_group_changed", default_version_group_id)

func refresh_to_latest_from_db() -> void:
	default_version_group_id = _compute_latest_version_group_id()
	PokeDb.meta_set("default_version_group_id", str(default_version_group_id))
	emit_signal("version_group_changed", default_version_group_id)

func _load_or_compute_default() -> void:
	var saved := int(PokeDb.meta_get("default_version_group_id", "0"))
	if saved > 0:
		default_version_group_id = saved
		return

	default_version_group_id = _compute_latest_version_group_id()
	PokeDb.meta_set("default_version_group_id", str(default_version_group_id))

func _compute_latest_version_group_id() -> int:
	var rows := PokeDb._query(
		"SELECT COALESCE(MAX(id), 0) AS m "
		+ "FROM entities WHERE resource='version_group';"
	)
	if rows.is_empty():
		return 0

	var v :Variant= (rows[0] as Dictionary).get("m")
	return 0 if v == null else int(v)
