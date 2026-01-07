extends Control

@onready var fade: ColorRect = $Fade
@onready var btn_back: Button = $TopBar/BackButton
@onready var opt_mode: OptionButton = $TopBar/ModeOption
@onready var opt_region: OptionButton = $TopBar/RegionOption
@onready var edit_search: LineEdit = $TopBar/Search
@onready var list: ItemList = $List
@onready var btn_prev: Button = $BottomBar/Prev
@onready var btn_next: Button = $BottomBar/Next
@onready var lbl_page: Label = $BottomBar/PageLabel
@onready var lbl_info: Label = $Info
@onready var chk_mega: CheckBox = $TopBar/MegaCheck

const PAGE_SIZE := 8
const REGION_SLICES := [
	{"label":"Kanto",  "start":1,   "end":151},
	{"label":"Johto",  "start":152, "end":251},
	{"label":"Hoenn",  "start":252, "end":386},
	{"label":"Sinnoh", "start":387, "end":493},
	{"label":"Unova",  "start":494, "end":649},
	{"label":"Kalos",  "start":650, "end":721},
	{"label":"Alola",  "start":722, "end":809},
	{"label":"Galar",  "start":810, "end":898},
	{"label":"Paldea", "start":899, "end":1025},
]

enum DexMode { ALL, REGION }

var _entries: Array[Dictionary] = []
var _region_index: int = 0
var _include_mega := false
var _mode: int = DexMode.REGION
var _page: int = 0
var _total: int = 0
var _mega_map: Dictionary = {}
# cache de la page courante : [{id, name}]
var _page_rows: Array[Dictionary] = []

func _ready() -> void:
	chk_mega.toggled.connect(func(v: bool):
		_include_mega = v
		_page = 0
		_reload()
	)
	_setup_ui()
	await _fade_in()
	_rebuild_mega_map()
	_reload()
	_apply_mode_ui()

func _on_region_option_item_selected(_index: int) -> void:
	_region_index = opt_region.get_selected_id()
	_page = 0
	_reload()

func _id_from_url(url: String) -> int:
	var u := url.rstrip("/")
	var parts := u.split("/")
	if parts.is_empty():
		return 0
	var last := parts[parts.size() - 1]
	return int(last) if last.is_valid_int() else 0

func _species_id_from_pokemon_id(pokemon_id: int) -> int:
	var p := PokeDb.get_entity("pokemon", pokemon_id)
	if p.is_empty():
		return 0

	# cas "plat"
	if p.has("pokemon_species_id"):
		return int(p.get("pokemon_species_id", 0))
	if p.has("species_id"):
		return int(p.get("species_id", 0))

	# cas PokeAPI: {"species":{"url":...}}
	if p.has("species") and typeof(p["species"]) == TYPE_DICTIONARY:
		var s := p["species"] as Dictionary
		if s.has("url"):
			return _id_from_url(str(s["url"]))
		if s.has("id"):
			return int(s.get("id", 0))

	return 0

func _pretty_mega_name(form: Dictionary, species_id: int) -> String:
	var base := str(PokeDb.get_entity("pokemon_species", species_id).get("name", "")).capitalize()

	# On essaye de récupérer une info de variante (X/Y) depuis form_name,
	# sinon on fallback sur form.name
	var raw := str(form.get("form_name", "")).strip_edges()
	if raw == "":
		raw = str(form.get("name", "")).strip_edges()

	var s := raw.to_lower()

	# Nettoyage : virer tout ce qui est "mega"
	s = s.replace("mega", "").strip_edges()
	s = s.replace("-", " ").strip_edges()

	# Déduire suffix (X/Y) si présent
	var suffix := ""
	# cas les plus courants
	if s.find(" x") != -1 or s == "x":
		suffix = "X"
	elif s.find(" y") != -1 or s == "y":
		suffix = "Y"
	elif s.find(" z") != -1 or s == "z":
		suffix = "Z"

	if suffix == "":
		return "Mega %s" % base
	return "Mega %s %s" % [base, suffix]   # => Mega X Charizard


func _rebuild_mega_map() -> void:
	_mega_map.clear()

	# Si pas de pokemon_form, on désactive proprement
	var chk := PokeDb._query("SELECT 1 AS x FROM entities WHERE resource='pokemon_form' LIMIT 1;")
	if chk.is_empty():
		chk_mega.disabled = true
		chk_mega.button_pressed = false
		_include_mega = false
		return

	chk_mega.disabled = false

	# candidats : name LIKE '%mega%'
	var ids_rows := PokeDb._query_bind(
		"SELECT id FROM entities WHERE resource='pokemon_form' AND name LIKE ? ORDER BY id ASC;",
		["%mega%"]
	)

	for r in ids_rows:
		var form_id := int((r as Dictionary).get("id", 0))
		if form_id <= 0:
			continue

		var form := PokeDb.get_entity("pokemon_form", form_id)
		if form.is_empty():
			continue
		if not bool(form.get("is_mega", false)):
			continue

		var pid := int(form.get("pokemon_id", 0))
		if pid <= 0:
			continue

		var sid := _species_id_from_pokemon_id(pid)
		if sid <= 0:
			continue

		var entry := {
			"kind": "mega",
			"species_id": sid,
			"pokemon_id": pid,
			"form_id": form_id,
			"name": _pretty_mega_name(form, sid),
			"num": sid, # on garde l'ordre "après l'espèce"
		}

		if not _mega_map.has(sid):
			_mega_map[sid] = []
		(_mega_map[sid] as Array).append(entry)

	# tri stable (Mega X puis Mega Y)
	for sid in _mega_map.keys():
		(_mega_map[sid] as Array).sort_custom(func(a, b):
			return str(a["name"]) < str(b["name"])
		)


func _fill_region_option_with_slices() -> void:
	opt_region.clear()
	for i in range(REGION_SLICES.size()):
		opt_region.add_item(REGION_SLICES[i]["label"], i) # id = index

	opt_region.select(_region_index)

func _apply_mode_ui() -> void:
	var show_region := (_mode == DexMode.REGION)
	opt_region.visible = show_region

func _setup_ui() -> void:
	fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fade.color.a = 1.0

	btn_back.pressed.connect(_on_back)

	opt_mode.clear()
	opt_mode.add_item("ALL", DexMode.ALL)
	opt_mode.add_item("REGION", DexMode.REGION)
	opt_mode.select(_mode)
	opt_mode.item_selected.connect(func(_idx):
		_mode = opt_mode.get_selected_id()
		_page = 0
		_apply_mode_ui()
		_reload()
	)
	

	# régions
	_fill_region_option_with_slices()
	if not opt_region.item_selected.is_connected(_on_region_option_item_selected):
		opt_region.item_selected.connect(_on_region_option_item_selected)

	edit_search.text_submitted.connect(_on_search_submit)

	btn_prev.pressed.connect(func():
		if _page > 0:
			_page -= 1
			_reload_page_only()
	)
	btn_next.pressed.connect(func():
		if (_page + 1) * PAGE_SIZE < _total:
			_page += 1
			_reload_page_only()
	)

	list.item_selected.connect(_on_list_item_selected)

	# Ouvrir seulement sur action “forte”
	list.item_activated.connect(_open_details_from_local_index)
	list.mouse_filter = Control.MOUSE_FILTER_PASS

var _hover_index := -1

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_update_hover_preview()

func _update_hover_preview() -> void:
	# position souris dans le repère du ItemList
	var local := list.get_local_mouse_position()
	var idx := list.get_item_at_position(local, true) # true => exact item only

	if idx == -1:
		return

	# évite spam
	if idx == _hover_index:
		return
	_hover_index = idx
	list.select(idx)
	_preview_from_local_index(idx)

func _on_list_item_selected(index: int) -> void:
	_preview_from_local_index(index)

func _on_list_item_hovered(index: int) -> void:
	# Hover = preview, mais ne change pas la sélection (comme tu veux)
	_preview_from_local_index(index)


func _preview_from_local_index(local_index: int) -> void:
	if local_index < 0 or local_index >= _page_rows.size():
		return

	var row := _page_rows[local_index]

	if str(row.get("kind", "")) == "mega":
		var sid := int(row.get("species_id", 0))
		var pid := int(row.get("pokemon_id", 0))
		var dn := str(row.get("name", ""))
		if sid > 0:
			_set_artwork(sid)
	else:
		var sid := int(row.get("id", 0))
		var dn := str(row.get("name", ""))
		if sid > 0:
			_set_artwork(sid)
		else :
			_set_artwork(0)


# =========================
# ARTWORK
# =========================
const ART_DIR := "res://Resource/texture/pokemon/other/official-artwork/"
const ART_FALLBACK := "res://Resource/texture/pokemon/0.png"

func _set_artwork(pokemon_id: int) -> void:
	var path := "%s%d.png" % [ART_DIR, pokemon_id]
	var final_path := path if ResourceLoader.exists(path) else ART_FALLBACK
	var tex := load(final_path)
	if tex is Texture2D:
		$PokemonPreview.texture = tex

func _on_list_item_clicked(index: int, _pos: Vector2, button: int) -> void:
	if button != MOUSE_BUTTON_LEFT:
		return
	_open_details_from_local_index(index)


func _fill_regions() -> void:
	opt_region.clear()

	# table "region" dans entities (id + name)
	var regs := PokeDb.list_entities("region", 999, 0)
	for r in regs:
		opt_region.add_item(str(r.get("name","")), int(r.get("id",0)))

	# par défaut : Kanto si trouvé, sinon 1
	_region_index = 0
	for r in regs:
		if str(r.get("name","")) == "kanto":
			_region_index = int(r.get("id", 0))
			break
	if _region_index <= 0 and regs.size() > 0:
		_region_index = int(regs[0].get("id", 0))

	# sélection UI
	for i in range(opt_region.item_count):
		if opt_region.get_item_id(i) == _region_index:
			opt_region.select(i)
			break

func _reload() -> void:
	_apply_mode_ui()
	_rebuild_entries()

	_total = _count_total()
	_reload_page_only()

func _rebuild_entries() -> void:
	_entries.clear()

	var start_id := 1
	var end_id := 1025

	if _mode == DexMode.REGION:
		var slice := _current_slice()
		start_id = int(slice["start"])
		end_id = int(slice["end"])

	var rows := PokeDb._query_bind(
		"SELECT id, name FROM entities WHERE resource='pokemon_species' AND id BETWEEN ? AND ? ORDER BY id ASC;",
		[start_id, end_id]
	)

	for rr in rows:
		var sid := int((rr as Dictionary).get("id", 0))
		var name := str((rr as Dictionary).get("name", "")).capitalize()

		_entries.append({"kind":"species","id":sid,"name":name,"num":sid})

		if _include_mega and _mega_map.has(sid):
			for m in (_mega_map[sid] as Array):
				_entries.append(m)

func _count_total() -> int:
	return _entries.size()

func _current_slice() -> Dictionary:
	if _region_index < 0 or _region_index >= REGION_SLICES.size():
		return REGION_SLICES[0]
	return REGION_SLICES[_region_index]

func _count_species_in_slice() -> int:
	var s := _current_slice()
	var rows := PokeDb._query_bind(
		"SELECT COUNT(*) AS c FROM entities WHERE resource='pokemon_species' AND id BETWEEN ? AND ?;",
		[int(s["start"]), int(s["end"])]
	)
	return int((rows[0] as Dictionary).get("c", 0)) if rows.size() > 0 else 0

func _fetch_species_in_slice(limit: int, offset: int) -> Array[Dictionary]:
	var s := _current_slice()
	return PokeDb._query_bind(
		"SELECT id, name FROM entities "
		+ "WHERE resource='pokemon_species' AND id BETWEEN ? AND ? "
		+ "ORDER BY id ASC LIMIT ? OFFSET ?;",
		[int(s["start"]), int(s["end"]), limit, offset]
	)

func _index_in_slice(species_id: int) -> int:
	var s := _current_slice()
	var rows := PokeDb._query_bind(
		"SELECT COUNT(*) AS c FROM entities "
		+ "WHERE resource='pokemon_species' AND id BETWEEN ? AND ? AND id < ?;",
		[int(s["start"]), int(s["end"]), species_id]
	)
	return int((rows[0] as Dictionary).get("c", -1)) if rows.size() > 0 else -1


func _reload_page_only() -> void:
	_page_rows = _fetch_page()
	_render_list()

	var a := _page * PAGE_SIZE + 1
	var b :Variant= min((_page + 1) * PAGE_SIZE, _total)
	lbl_page.text = "%d-%d / %d" % [a if _total>0 else 0, b if _total>0 else 0, _total]
	btn_prev.disabled = (_page <= 0)
	btn_next.disabled = ((_page + 1) * PAGE_SIZE >= _total)

	lbl_info.text = "mode=%s page=%d total=%d" % [_mode, _page, _total]

func _fetch_page() -> Array[Dictionary]:
	var offset := _page * PAGE_SIZE
	var out: Array[Dictionary] = []
	for i in range(offset, min(offset + PAGE_SIZE, _entries.size())):
		out.append(_entries[i])
	return out

func _render_list() -> void:
	list.clear()
	for row in _page_rows:
		var id := int(row.get("id", 0))
		var name := str(row.get("name", ""))
		var num := int(row.get("num", id))

		# si tu veux afficher un "numéro pokedex", tu peux le format ici
		list.add_item("%04d    %s" % [num, name])

func _on_search_submit(text: String) -> void:
	var q := text.strip_edges()
	if q == "":
		_page = 0
		_reload()
		return

	# 1) recherche par numéro
	if q.is_valid_int():
		var id := int(q)
		_jump_to_species(id)
		return

	# 2) recherche par nom (localisé si possible, sinon entities.name)
	var sid := _find_species_id_by_name(q)
	if sid > 0:
		_jump_to_species(sid)
	else:
		lbl_info.text = "Aucun résultat pour: %s" % q

func _jump_to_species(species_id: int) -> void:
	# On calcule sur quelle page ça tombe selon le mode courant
	var index := _index_of_species_in_current_mode(species_id)
	if index < 0:
		lbl_info.text = "Introuvable dans ce filtre."
		return

	_page = int(index / PAGE_SIZE)
	_reload_page_only()

	# highlight si visible
	var local := index % PAGE_SIZE
	if local >= 0 and local < list.item_count:
		list.select(local)
		_preview_from_local_index(local)
		list.ensure_current_is_visible()

func _index_of_species_in_current_mode(species_id: int) -> int:
	match _mode:
		DexMode.ALL:
			# index = position triée par id
			var rows := PokeDb._query_bind(
				"SELECT COUNT(*) AS c FROM entities WHERE resource='pokemon_species' AND id < ?;",
				[species_id]
			)
			return int((rows[0] as Dictionary).get("c", -1)) if rows.size()>0 else -1

		DexMode.REGION:
			return _index_in_slice(species_id)

	return -1

func _find_species_id_by_name(name_query: String) -> int:
	var q := name_query.to_lower()

	# (A) Essai table de noms localisés si tu l’as
	# Exemple de table possible: pokemonspeciesname (resource) avec fields: pokemon_species_id, language_id, name
	# Si tu n'as pas cette table, ça renverra 0 et on fallback.
	var lang_id := _guess_language_id()
	var sid := _find_species_id_by_localized_name(q, lang_id)
	if sid > 0:
		return sid

	# (B) fallback sur entities.name (anglais)
	var rows := PokeDb._query_bind(
		"SELECT id FROM entities WHERE resource='pokemon_species' AND LOWER(name)=? LIMIT 1;",
		[q]
	)
	if rows.size() > 0:
		return int((rows[0] as Dictionary).get("id", 0))

	# (C) contains (plus permissif)
	rows = PokeDb._query_bind(
		"SELECT id FROM entities WHERE resource='pokemon_species' AND LOWER(name) LIKE ? ORDER BY id ASC LIMIT 1;",
		["%" + q + "%"]
	)
	return int((rows[0] as Dictionary).get("id", 0)) if rows.size() > 0 else 0

func _guess_language_id() -> int:
	# simple: si tu veux, tu peux mapper OS locale -> language_id
	# pour l’instant: 9 = en (souvent), mais on tente de trouver "en"
	var rows := PokeDb._query("SELECT id FROM entities WHERE resource='language' AND name='en' LIMIT 1;")
	return int((rows[0] as Dictionary).get("id", 9)) if rows.size() > 0 else 9

func _find_species_id_by_localized_name(q_lower: String, language_id: int) -> int:
	# ⚠️ Ajuste resource selon ta DB si tu as importé une table name dédiée
	# Essais sur quelques noms de tables possibles:
	for res in ["pokemonspeciesname", "pokemon_speciesname", "pokemon_species_name"]:
		var exists := PokeDb._query_bind(
			"SELECT 1 AS x FROM entities WHERE resource=? LIMIT 1;",
			[res]
		)
		if exists.size() == 0:
			continue

		var rows := PokeDb._query_bind(
			"SELECT json FROM entities WHERE resource=? AND LOWER(name)=? LIMIT 1;",
			[res, q_lower]
		)
		if rows.size() == 0:
			continue

		var js := str((rows[0] as Dictionary).get("json", ""))
		var d :Variant= JSON.parse_string(js)
		if typeof(d) == TYPE_DICTIONARY:
			# champ probable
			var sid := int((d as Dictionary).get("pokemon_species_id", 0))
			if sid > 0:
				return sid

	return 0

# --------- Pokedex by region ---------

func _count_species_in_pokedex(pokedex_id: int) -> int:
	if pokedex_id <= 0:
		return 0
	var rows := PokeDb._query_bind("SELECT COUNT(*) AS c FROM dex_pokedex_number WHERE pokedex_id=?;", [pokedex_id])
	if rows.size() == 0:
		return 0
	return int((rows[0] as Dictionary).get("c", 0))

func _fetch_species_in_pokedex(pokedex_id: int, limit: int, offset: int) -> Array[Dictionary]:
	if pokedex_id <= 0:
		return []

	# dex_pokedex_number: (pokedex_id, pokemon_species_id, pokedex_number)
	var rows := PokeDb._query_bind(
		"SELECT pokemon_species_id AS id, pokedex_number AS num "
		+ "FROM dex_pokedex_number WHERE pokedex_id=? "
		+ "ORDER BY pokedex_number ASC LIMIT ? OFFSET ?;",
		[pokedex_id, limit, offset]
	)

	var out: Array[Dictionary] = []
	for r in rows:
		var sid := int((r as Dictionary).get("id", 0))
		var spec := PokeDb.get_entity("pokemon_species", sid)
		out.append({
			"id": sid,
			"name": str(spec.get("name","")),
			"num": int((r as Dictionary).get("num", sid))
		})
	return out

func _index_in_pokedex(pokedex_id: int, species_id: int) -> int:
	if pokedex_id <= 0:
		return -1
	# nombre d'entrées avec pokedex_number < notre numéro
	var rows := PokeDb._query_bind(
		"SELECT pokedex_number AS n FROM dex_pokedex_number WHERE pokedex_id=? AND pokemon_species_id=? LIMIT 1;",
		[pokedex_id, species_id]
	)
	if rows.size() == 0:
		return -1
	var n := int((rows[0] as Dictionary).get("n", 0))
	if n <= 0:
		return -1

	var rows2 := PokeDb._query_bind(
		"SELECT COUNT(*) AS c FROM dex_pokedex_number WHERE pokedex_id=? AND pokedex_number < ?;",
		[pokedex_id, n]
	)
	return int((rows2[0] as Dictionary).get("c", -1)) if rows2.size()>0 else -1

# --------- interactions ---------

func _on_item_activated(index: int) -> void:
	if index < 0 or index >= _page_rows.size():
		return
	var row := _page_rows[index]
	if str(row.get("kind", "")) == "mega":
		var pid := int(row.get("pokemon_id", 0))
		lbl_info.text = "Selected MEGA pokemon_id=%d" % pid
		# TODO: ouvrir la fiche du pokemon_id
	else:
		var sid := int(row.get("id", 0))
		lbl_info.text = "Selected species_id=%d" % sid
		# TODO: ouvrir la fiche espèce

func _on_back() -> void:
	await _fade_out()
	get_tree().change_scene_to_file("res://src/main/main_menu.tscn")

func _fade_in() -> void:
	var t := create_tween()
	t.tween_property(fade, "color:a", 0.0, 0.2)

func _fade_out() -> void:
	var t := create_tween()
	t.tween_property(fade, "color:a", 1.0, 0.2)
	await t.finished

func _open_details_from_local_index(local_index: int) -> void:
	if local_index < 0 or local_index >= _page_rows.size():
		return

	var global_index := _page * PAGE_SIZE + local_index
	PokedexNav.set_context(_entries, global_index, "res://src/model/pokedex/pokedex_menu.tscn")
	get_tree().change_scene_to_file("res://src/model/pokedex/pokemon_details.tscn")
