extends Control

@onready var btn_update: Button = $TextureRect/VBoxContainer/Update
@onready var lbl: Label = $TextureRect/DlInfo
@onready var opt: OptionButton = $TextureRect/OptionButton

var _vg_loading := false
var _vg_ids: Array[int] = []

func _ready() -> void:
	if not PokeDb.import_progress.is_connected(_on_import_progress):
		PokeDb.import_progress.connect(_on_import_progress)
	if not PokeDb.import_finished.is_connected(_on_import_finished):
		PokeDb.import_finished.connect(_on_import_finished)
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
	PokeImport.import_progress.connect(func(msg, d, t): lbl.text = "%s %d/%d" % [msg, d, t], CONNECT_ONE_SHOT)
	PokeImport.import_finished.connect(func(status, ins, upd, skp, err):
		lbl.text = "Import: %s | +%d ~%d skip=%d err=%d" % [status, ins, upd, skp, err]
	, CONNECT_ONE_SHOT)

	await PokeImport.import_step(5000) # batch

func _on_import_progress(msg: String, done: int, total: int, ins: int, upd: int, skp: int, err: int) -> void:
	lbl.text = "%s %d/%d | +%d ~%d =%d | err=%d" % [msg, done, total, ins, upd, skp, err]

func _on_import_finished(status: String, ins: int, upd: int, skp: int, err: int, total: int) -> void:
	lbl.text = "Import: %s total=%d | +%d ~%d =%d | err=%d" % [status, total, ins, upd, skp, err]


func _on_test_pressed() -> void:
	var vg := PokeConfig.get_version_group_id()
	var p := PokeGen.make(1, 5, vg) # bulbasaur

	print("Pokemon:", p.name(), "lvl", p.level, "vg chosen", p.version_group_id, "learnset vg", p.learnset_vg_id)
	print("Types ids:", p.type_ids())
	print("Types names:", [PokeRepo.get_entity_name("type", p.type_ids()[0]), PokeRepo.get_entity_name("type", p.type_ids()[1])])

	print("Moves ids:", p.move_ids)

	var move_names: Array[String] = []
	for mid in p.move_ids:
		if mid <= 0:
			move_names.append("")
		else:
			move_names.append(MoveModel.new(mid).name())
	print("Moves:", move_names)


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
