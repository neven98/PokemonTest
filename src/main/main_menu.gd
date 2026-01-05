extends Control

@onready var btn_update: Button = $TextureRect/VBoxContainer/Update
@onready var lbl: Label = $TextureRect/DlInfo
@onready var opt: OptionButton = $TextureRect/OptionButton

var _vg_loading := false
var _vg_ids: Array[int] = []

func _ready() -> void:
	if not PokeCacheSync.offline_progress.is_connected(_on_update_progress):
		PokeCacheSync.offline_progress.connect(_on_update_progress)
	if not PokeCacheSync.offline_finished.is_connected(_on_update_finished):
		PokeCacheSync.offline_finished.connect(_on_update_finished)
	opt.clear()
	opt.disabled = true
	if not opt.item_selected.is_connected(_on_version_group_selected):
		opt.item_selected.connect(_on_version_group_selected)

	# charger la liste quand la DB est prête
	if PokeDb.is_ready():
		_load_version_groups()
	else:
		PokeDb.db_ready.connect(_load_version_groups)

	# si PokeConfig change ailleurs, on resync
	if not PokeConfig.version_group_changed.is_connected(_on_config_version_group_changed):
		PokeConfig.version_group_changed.connect(_on_config_version_group_changed)


func _on_exit_pressed() -> void:
	get_tree().root.propagate_notification(NOTIFICATION_WM_CLOSE_REQUEST)


func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		get_tree().quit() # default behavior


func _on_update_pressed() -> void:
	btn_update.disabled = true
	lbl.visible = true
	lbl.text = "Update..."
	PokeCacheSync.offline_finished.connect(_on_offline_finished, CONNECT_ONE_SHOT)
	await PokeCacheSync.update_offline_all(80)

func _on_offline_progress(msg: String, calls_used: int, remaining: int) -> void:
	lbl.text = "%s\ncalls=%d | restants=%d" % [msg, calls_used, remaining]

func _on_offline_finished(status: String, calls_used: int, remaining: int) -> void:
	btn_update.disabled = false
	lbl.text = "Update: %s | calls=%d | restants=%d" % [status, calls_used, remaining]


func _on_import_db_pressed() -> void:
	lbl.visible = true
	lbl.text = "Import: préparation…"

	# IMPORTANT: pas de ONE_SHOT sinon tu ne vois qu'un seul update.
	if not PokeImport.import_progress.is_connected(_on_import_progress_short):
		PokeImport.import_progress.connect(_on_import_progress_short)
	if not PokeImport.import_finished.is_connected(_on_import_finished_short):
		PokeImport.import_finished.connect(_on_import_finished_short)

	PokeImport.rebuild_all_indexes()
	await PokeImport.import_step(0)

var _import_start_ms := 0

func _on_import_progress_short(msg: String, done: int, total: int, ins: int = 0, upd: int = 0, skp: int = 0, err: int = 0) -> void:
	var pct := 0.0
	if total > 0:
		pct = (float(done) / float(total)) * 100.0
	lbl.text = "%s\n%d/%d (%.1f%%) | +%d ~%d =%d | err=%d" % [msg, done, total, pct, ins, upd, skp, err]


func _on_import_finished_short(status: String, ins: int, upd: int, skp: int, err: int, total: int = -1) -> void:
	var extra := ""
	if total >= 0:
		extra = " total=%d" % total
	lbl.text = "Import: %s | +%d ~%d =%d | err=%d%s" % [status, ins, upd, skp, err, extra]

func _on_test_pressed() -> void:
	print(PokeDb._query("SELECT COUNT(*) AS c FROM entities WHERE resource='pokemon_form';"))

func _on_update_progress(msg: String, calls_used: int, remaining: int) -> void:
	lbl.text = "%s\ncalls=%d | restants=%d" % [msg, calls_used, remaining]

func _on_update_finished(status: String, calls_used: int, remaining: int) -> void:
	btn_update.disabled = false
	lbl.text = "Update: %s\ncalls=%d | restants=%d" % [status, calls_used, remaining]

# ==========================
# OPTIONBUTTON version_group
# ==========================

func _load_version_groups() -> void:
	_vg_loading = true
	opt.clear()
	_vg_ids.clear()

	var rows := PokeDb.list_entities("version_group", 5000, 0) # [{id,name}...]

	if rows.is_empty():
		opt.add_item("Aucun version_group en DB")
		opt.disabled = true
		_vg_loading = false
		return

	rows.sort_custom(func(a, b): return int(a.get("id", 0)) < int(b.get("id", 0)))

	for r in rows:
		var id := int(r.get("id", 0))
		if id <= 0:
			continue
		var name := str(r.get("name", ""))
		opt.add_item("%s  (#%d)" % [name, id])
		_vg_ids.append(id)

	opt.disabled = false

	# sélection : PokeConfig -> sinon dernier
	var current_id := PokeConfig.get_version_group_id()
	var idx := _find_vg_index(current_id)
	if idx < 0:
		idx = _vg_ids.size() - 1
		current_id = _vg_ids[idx]
		PokeConfig.set_version_group_id(current_id)

	opt.select(idx)
	_vg_loading = false

	lbl.visible = true
	lbl.text = "Version group actif: #%d" % current_id


func _on_version_group_selected(index: int) -> void:
	if _vg_loading:
		return
	if index < 0 or index >= _vg_ids.size():
		return

	var vg_id := _vg_ids[index]
	PokeConfig.set_version_group_id(vg_id)

	lbl.visible = true
	lbl.text = "Version group actif: #%d" % vg_id


func _on_config_version_group_changed(new_id: int) -> void:
	# si ça change ailleurs, aligne le dropdown
	var idx := _find_vg_index(new_id)
	if idx >= 0 and opt.selected != idx:
		_vg_loading = true
		opt.select(idx)
		_vg_loading = false


func _find_vg_index(vg_id: int) -> int:
	for i in range(_vg_ids.size()):
		if _vg_ids[i] == vg_id:
			return i
	return -1


func _on_pokedex_pressed() -> void:
	get_tree().change_scene_to_file("res://src/model/pokedex/pokedex_menu.tscn")
