extends Control

@onready var btn_back: Button = $TopBar/BackButton
@onready var btn_prev: Button = $TopBar/PrevButton
@onready var btn_next: Button = $TopBar/NextButton
@onready var tabs: TabContainer = $Pages
@onready var species_page: SpeciesPage = $Pages/SpeciesPage
@onready var stats_page: StatsPage = $Pages/StatsPage
@onready var evo_page: EvoPage = $Pages/EvoPage

func _ready() -> void:
	btn_back.pressed.connect(_go_back)
	btn_prev.pressed.connect(_go_prev)
	btn_next.pressed.connect(_go_next)
	_refresh()

func _go_back() -> void:
	get_tree().change_scene_to_file(PokedexNav.return_scene)

func _go_prev() -> void:
	PokedexNav.prev()
	_refresh()

func _go_next() -> void:
	PokedexNav.next()
	_refresh()

func _refresh() -> void:
	btn_prev.disabled = not PokedexNav.can_prev()
	btn_next.disabled = not PokedexNav.can_next()

	var entry := PokedexNav.current()

	var species_id := 0
	var pokemon_id := 0
	var display_name := ""

	if str(entry.get("kind","")) == "mega":
		species_id = int(entry.get("species_id", 0))
		pokemon_id = int(entry.get("pokemon_id", 0))
		display_name = str(entry.get("name",""))
	else:
		species_id = int(entry.get("id", 0))
		display_name = str(entry.get("name",""))

	var species := PokeDb.get_entity("pokemon_species", species_id)
	if pokemon_id <= 0:
		pokemon_id = _default_pokemon_id_for_species(species, species_id)

	species_page.render_species(species_id, pokemon_id, display_name)
	stats_page.render_species(species_id, pokemon_id, display_name)
	evo_page.render_species(species_id, pokemon_id)

func _default_pokemon_id_for_species(species: Dictionary, fallback_species_id: int) -> int:
	# PokeAPI: species.varieties -> is_default -> pokemon.url
	if species.has("varieties") and typeof(species["varieties"]) == TYPE_ARRAY:
		for v in (species["varieties"] as Array):
			if typeof(v) != TYPE_DICTIONARY: continue
			var d := v as Dictionary
			if d.has("is_default") and bool(d["is_default"]) == false:
				continue
			if d.has("pokemon") and typeof(d["pokemon"]) == TYPE_DICTIONARY:
				var p := d["pokemon"] as Dictionary
				if p.has("url"):
					var id := _id_from_url(str(p["url"]))
					if id > 0:
						return id
	# fallback: souvent = species_id
	return fallback_species_id

func _collect_chain_nodes(node: Dictionary, parent_sid: int, out: Dictionary) -> void:
	var sid := 0
	if node.has("species") and typeof(node["species"]) == TYPE_DICTIONARY:
		sid = _id_from_url(str((node["species"] as Dictionary).get("url","")))
	if sid > 0:
		out[sid] = {"node": node, "parent": parent_sid}

	if node.has("evolves_to") and typeof(node["evolves_to"]) == TYPE_ARRAY:
		for child in (node["evolves_to"] as Array):
			if typeof(child) != TYPE_DICTIONARY: continue
			_collect_chain_nodes(child as Dictionary, sid, out)

func _summarize_evo(child_node: Dictionary) -> String:
	# On prend le 1er evolution_details (souvent suffisant)
	if not (child_node.has("evolution_details") and typeof(child_node["evolution_details"]) == TYPE_ARRAY):
		return "?"
	var dets := child_node["evolution_details"] as Array
	if dets.is_empty() or typeof(dets[0]) != TYPE_DICTIONARY:
		return "?"
	var d := dets[0] as Dictionary

	var trigger := ""
	if d.has("trigger") and typeof(d["trigger"]) == TYPE_DICTIONARY:
		trigger = str((d["trigger"] as Dictionary).get("name",""))

	# ultra court (comme tu veux)
	if trigger == "level-up":
		if int(d.get("min_level", 0)) > 0:
			return "Niv. %d" % int(d.get("min_level", 0))
		if int(d.get("min_happiness", 0)) > 0:
			return "Bonheur"
		var tod := str(d.get("time_of_day",""))
		if tod != "":
			return "Jour" if tod == "day" else "Nuit" if tod == "night" else tod
		if d.has("location") and typeof(d["location"]) == TYPE_DICTIONARY:
			return "Lieu"
		return "Niveau"

	if trigger == "use-item":
		if d.has("item") and typeof(d["item"]) == TYPE_DICTIONARY:
			return "Objet"
		return "Objet"

	if trigger == "trade":
		if d.has("held_item") and typeof(d["held_item"]) == TYPE_DICTIONARY:
			return "Échange + Objet"
		return "Échange"

	return trigger if trigger != "" else "?"

func _pick_flavor(species: Dictionary, langs: Array[String]) -> String:
	if not (species.has("flavor_text_entries") and typeof(species["flavor_text_entries"]) == TYPE_ARRAY):
		return ""
	var arr := species["flavor_text_entries"] as Array
	for code in langs:
		for e in arr:
			if typeof(e) != TYPE_DICTIONARY: continue
			var d := e as Dictionary
			if d.has("language") and typeof(d["language"]) == TYPE_DICTIONARY:
				if str((d["language"] as Dictionary).get("name","")) == code:
					return str(d.get("flavor_text","")).replace("\n"," ").strip_edges()
	return ""

func _pick_genus(species: Dictionary, langs: Array[String]) -> String:
	if not (species.has("genera") and typeof(species["genera"]) == TYPE_ARRAY):
		return ""
	var arr := species["genera"] as Array
	for code in langs:
		for e in arr:
			if typeof(e) != TYPE_DICTIONARY: continue
			var d := e as Dictionary
			if d.has("language") and typeof(d["language"]) == TYPE_DICTIONARY:
				if str((d["language"] as Dictionary).get("name","")) == code:
					return str(d.get("genus","")).strip_edges()
	return ""

func _id_from_url(url: String) -> int:
	var u := url.rstrip("/")
	var parts := u.split("/")
	if parts.is_empty():
		return 0
	var last := parts[parts.size() - 1]
	return int(last) if last.is_valid_int() else 0
