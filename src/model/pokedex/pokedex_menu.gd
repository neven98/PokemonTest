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

const PAGE_SIZE := 50

enum DexMode { REGION, ALL }

var _mode: int = DexMode.REGION
var _region_id: int = 0
var _page: int = 0
var _total: int = 0

# cache de la page courante : [{id, name}]
var _page_rows: Array[Dictionary] = []

func _ready() -> void:
	_setup_ui()
	await _fade_in()
	_reload()
	_apply_mode_ui()

func _on_region_option_item_selected(_index: int) -> void:
	_region_id = opt_region.get_selected_id()
	_page = 0
	_reload()

func _fill_region_option_with_pokedex() -> void:
	opt_region.clear()

	var rows := PokeDb._query("SELECT id, name FROM entities WHERE resource='pokedex' ORDER BY id ASC;")
	var kanto_index := -1
	for r in rows:
		var id := int(r.get("id", 0))
		var name := str(r.get("name", ""))
		opt_region.add_item(name.capitalize(), id)
		if name.to_lower() == "kanto":
			kanto_index = opt_region.item_count - 1

	if opt_region.item_count > 0:
		var target := kanto_index if kanto_index >= 0 else 0
		opt_region.select(target)
		_region_id = opt_region.get_item_id(target)

func _apply_mode_ui() -> void:
	var show_region := (_mode == DexMode.REGION)
	opt_region.visible = show_region

func _setup_ui() -> void:
	fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fade.color.a = 1.0

	btn_back.pressed.connect(_on_back)

	opt_mode.clear()
	opt_mode.add_item("REGION", DexMode.REGION)
	opt_mode.add_item("ALL", DexMode.ALL)
	opt_mode.select(_mode)
	opt_mode.item_selected.connect(func(_idx):
		_mode = opt_mode.get_selected_id()
		_page = 0
		_apply_mode_ui()
		_reload()
	)

	# régions
	_fill_region_option_with_pokedex()

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

	list.item_activated.connect(_on_item_activated)

func _fill_regions() -> void:
	opt_region.clear()

	# table "region" dans entities (id + name)
	var regs := PokeDb.list_entities("region", 999, 0)
	for r in regs:
		opt_region.add_item(str(r.get("name","")), int(r.get("id",0)))

	# par défaut : Kanto si trouvé, sinon 1
	_region_id = 0
	for r in regs:
		if str(r.get("name","")) == "kanto":
			_region_id = int(r.get("id", 0))
			break
	if _region_id <= 0 and regs.size() > 0:
		_region_id = int(regs[0].get("id", 0))

	# sélection UI
	for i in range(opt_region.item_count):
		if opt_region.get_item_id(i) == _region_id:
			opt_region.select(i)
			break

func _reload() -> void:
	opt_region.visible = (_mode == DexMode.REGION)

	_total = _count_total()
	_reload_page_only()

func _count_total() -> int:
	match _mode:
		DexMode.ALL:
			var rows := PokeDb._query("SELECT COUNT(*) AS c FROM entities WHERE resource='pokemon_species';")
			return int((rows[0] as Dictionary).get("c", 0)) if rows.size() > 0 else 0

		DexMode.REGION:
			return _count_species_in_pokedex(_region_id)

	return 0

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

	match _mode:
		DexMode.ALL:
			# on liste pokemon_species id + name depuis entities
			return PokeDb.list_entities("pokemon_species", PAGE_SIZE, offset)

		DexMode.REGION:
			return _fetch_species_in_pokedex(_region_id, PAGE_SIZE, offset)

	return []

func _render_list() -> void:
	list.clear()
	for row in _page_rows:
		var id := int(row.get("id", 0))
		var name := str(row.get("name", ""))
		var num := int(row.get("num", id))

		# si tu veux afficher un "numéro pokedex", tu peux le format ici
		list.add_item("#%04d  %s" % [num, name])

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
			return _index_in_pokedex(_region_id, species_id)

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
	var sid := int(_page_rows[index].get("id", 0))
	lbl_info.text = "Selected species_id=%d" % sid
	# TODO: ouvrir une fiche Pokémon (sous-menu détail)

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
