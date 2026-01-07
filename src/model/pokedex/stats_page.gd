extends Control
class_name StatsPage

const ART_DIR := "res://Resource/texture/pokemon/other/official-artwork/"
const ART_FALLBACK := "res://Resource/texture/pokemon/0.png"

# --- UI ---
@onready var btn_mode: Button = $Content/RightColContainer/RightCol/HBoxContainer/Button
@onready var radar: RadarChart = $Content/RightColContainer/RightCol/Radarc2/RadarChart
@onready var img_slot: TextureRect = $Content/LeftColContainer/LeftCol/SpriteCard/AspectRatioContainer/TextureRect
@onready var pokemon_name: Label = $Content/RightColContainer/RightCol/HBoxContainer/PokemonName
@onready var lblXpGive: Label = $Content/LeftColContainer/LeftCol/QuickFacts/GridContainer/LblXpGive
@onready var lblStatGive: Label = $Content/LeftColContainer/LeftCol/QuickFacts/GridContainer/LblStatGive
@onready var tab_talents : TabContainer = $Content/RightColContainer/RightCol/Talent/MarginContainer/TabContainer

# --- State ---
var show_lv100 := false
var _species_id := 0
var _pokemon_id := 0

# base stats (ordre radar)
const STAT_LABELS := ["HP", "ATT", "DEF", "ATT SP", "DEF SP", "SPEED"]
const STAT_ID_TO_INDEX := {1:0, 2:1, 3:2, 4:3, 5:4, 6:5}

var _base_stats: Array[int] = [0,0,0,0,0,0]
var _lv100_stats: Array[int] = [0,0,0,0,0,0]

func _ready() -> void:
	btn_mode.pressed.connect(_on_mode_pressed)
	_apply_mode() # met le texte du bouton

func render_species(species_id: int, pokemon_id: int = 0, display_name: String = "") -> void:
	_species_id = species_id

	var species := PokeDb.get_entity("pokemon_species", species_id)
	if species.is_empty():
		_clear_ui("Species #%d introuvable" % species_id)
		return

	# nom affiché
	var base_name := str(species.get("name", "")).capitalize()
	pokemon_name.text = display_name if display_name != "" else base_name

	# pokemon_id (si pas donné)
	if pokemon_id <= 0:
		pokemon_id = _default_pokemon_id_for_species(species, species_id)
	_pokemon_id = pokemon_id

	_set_artwork(_pokemon_id)

	# charge data “stats page”
	_load_stats_xp_ev(_pokemon_id)

	# apply affichage radar
	_refresh_radar(false)
	
	_refresh_abilities(pokemon_id)

func _on_mode_pressed() -> void:
	show_lv100 = !show_lv100
	_apply_mode()
	_refresh_radar(true)

func _apply_mode() -> void:
	if show_lv100:
		btn_mode.text = "LV 100 (IV31 / EV0 / neutre)"
	else:
		btn_mode.text = "BASE STATS"

func _refresh_radar(animated: bool) -> void:
	var display_vals := _base_stats
	var plot_vals := _base_stats
	
	var scale_max := 255.0
	if show_lv100:
		display_vals = _lv100_stats
		scale_max = 400.0
		# échelle FIXE 255 => on clamp juste pour le dessin
		plot_vals = []
		for v in _lv100_stats:
			plot_vals.append(min(v, scale_max))

	if animated:
		radar.set_series_animated(STAT_LABELS, plot_vals, display_vals, 255.0, 0.25)
	else:
		radar.set_series(STAT_LABELS, plot_vals, display_vals, scale_max)

# -------------------------
# LOAD STATS / XP / EV YIELD
# -------------------------

func _load_stats_xp_ev(pokemon_id: int) -> void:
	_base_stats = [0,0,0,0,0,0]
	_lv100_stats = [0,0,0,0,0,0]

	if pokemon_id <= 0:
		lblXpGive.text = "-"
		lblStatGive.text = "-"
		return

	# XP given : base_experience depuis l’entité pokemon (si dispo)
	var p := PokeDb.get_entity("pokemon", pokemon_id)
	var xp := int(p.get("base_experience", 0))
	lblXpGive.text = str(xp) if xp > 0 else "-"

	# base stats + EV yield depuis dex_pokemon_stat
	var rows: Array[Dictionary] = PokeDb.pokemon_stats_rows(pokemon_id)
	if rows.is_empty():
		lblStatGive.text = "-"
		return

	# EV yield -> format "1 ATT / 1 DEF / ..."
	var ev_parts: Array[String] = []

	for r in rows:
		var stat_id := int(r.get("stat_id", 0))
		var base_stat := int(r.get("base_stat", 0))
		var effort := int(r.get("effort", 0))

		if STAT_ID_TO_INDEX.has(stat_id):
			_base_stats[STAT_ID_TO_INDEX[stat_id]] = base_stat

		if effort > 0:
			var nm := _stat_short_name(stat_id)
			ev_parts.append("%d %s" % [effort, nm])

	lblStatGive.text = " / ".join(ev_parts) if not ev_parts.is_empty() else "-"

	# calc LV100 (IV31, EV0, nature neutre)
	_compute_lv100_from_base()

func _compute_lv100_from_base() -> void:
	# Formules (Gen 3+) niveau 100, IV=31, EV=0, nature neutre
	# HP = 2*base + 31 + 110 = 2*base + 141
	# Others = 2*base + 31 + 5 = 2*base + 36
	_lv100_stats = _base_stats.duplicate()
	for i in range(_lv100_stats.size()):
		var b := int(_base_stats[i])
		if i == 0: # HP
			_lv100_stats[i] = 2 * b + 141
		else:
			_lv100_stats[i] = 2 * b + 36

func _stat_short_name(stat_id: int) -> String:
	match stat_id:
		1: return "HP"
		2: return "ATT"
		3: return "DEF"
		4: return "ATT SP"
		5: return "DEF SP"
		6: return "SPEED"
		_: return "STAT"

func _get_ability_text(ability: Dictionary, prefer_lang: String = "fr") -> String:
	# tente plusieurs formats possibles selon ton import/cache
	var keys := [
		"abilityeffecttexts",
		"ability_effect_texts",
		"effect_entries",
		"effect_entries",
		"flavor_text_entries",
		"abilityflavortexts"
	]

	var entries: Array = []
	for k in keys:
		if ability.has(k) and typeof(ability[k]) == TYPE_ARRAY:
			entries = ability[k]
			break
	if entries.is_empty():
		return ""

	var prefer := prefer_lang.to_lower()

	# 1) langue préférée
	for e in entries:
		if typeof(e) != TYPE_DICTIONARY: continue
		var d := e as Dictionary

		var txt := ""
		if d.has("short_effect"): txt = str(d.get("short_effect", ""))
		elif d.has("effect"): txt = str(d.get("effect", ""))
		elif d.has("flavor_text"): txt = str(d.get("flavor_text", ""))

		if txt == "": continue

		var lang_ok := false
		if d.has("language") and typeof(d["language"]) == TYPE_DICTIONARY:
			lang_ok = str((d["language"] as Dictionary).get("name","")).to_lower() == prefer
		elif d.has("language_id"):
			var lid := int(d.get("language_id", 0))
			var l := PokeDb.get_entity("language", lid)
			lang_ok = str(l.get("name","")).to_lower() == prefer

		if lang_ok:
			return _clean_text(txt)

	# 2) fallback
	for e in entries:
		if typeof(e) != TYPE_DICTIONARY: continue
		var d := e as Dictionary
		var txt2 := ""
		if d.has("short_effect"): txt2 = str(d.get("short_effect", ""))
		elif d.has("effect"): txt2 = str(d.get("effect", ""))
		elif d.has("flavor_text"): txt2 = str(d.get("flavor_text", ""))
		if txt2 != "":
			return _clean_text(txt2)

	return ""

# -------------------------
# UI helpers
# -------------------------

func _clear_ui(msg: String) -> void:
	pokemon_name.text = msg
	lblXpGive.text = "-"
	lblStatGive.text = "-"

# -------------------------
# Artwork
# -------------------------

func _set_artwork(pokemon_id: int) -> void:
	var path := "%s%d.png" % [ART_DIR, pokemon_id]
	var final_path := path if ResourceLoader.exists(path) else ART_FALLBACK
	var tex := load(final_path)
	if tex is Texture2D:
		img_slot.texture = tex

# -------------------------
# Default pokemon id from species (si besoin)
# -------------------------

func _default_pokemon_id_for_species(species: Dictionary, fallback_species_id: int) -> int:
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
	return fallback_species_id

func _id_from_url(url: String) -> int:
	var u := url.rstrip("/")
	var parts := u.split("/")
	return int(parts[parts.size() - 1]) if not parts.is_empty() and parts[parts.size() - 1].is_valid_int() else 0

# -------------------------
# TALENTS (ABILITIES)
# -------------------------

func _load_talents(pokemon_id: int) -> void:
	if tab_talents == null:
		return

	# récupère abilities depuis dex_pokemon_ability
	var rows := PokeDb._query_bind(
		"SELECT slot, ability_id, is_hidden FROM dex_pokemon_ability WHERE pokemon_id=? ORDER BY slot ASC;",
		[pokemon_id]
	)

	var talents: Array[Dictionary] = []
	for r in rows:
		var aid := int((r as Dictionary).get("ability_id", 0))
		if aid <= 0:
			continue
		var ab := PokeDb.get_entity("ability", aid)
		var nm := str(ab.get("name", "")).capitalize()
		var hidden := int((r as Dictionary).get("is_hidden", 0)) == 1

		var desc := _pick_ability_desc_fr_then_en(ab)
		if desc == "":
			desc = "Pas de description disponible."

		talents.append({
			"name": nm + (" (Hidden)" if hidden else ""),
			"desc": desc
		})

	_build_talent_tabs(talents)

func _preferred_langs() -> Array[String]:
	var loc := TranslationServer.get_locale().to_lower() # ex: "fr", "fr_fr", "en_us"
	if loc.begins_with("fr"):
		return ["fr", "en"]
	if loc.begins_with("en"):
		return ["en", "fr"]
	# fallback
	return ["en", "fr"]

func _pick_ability_desc_fr_then_en(ab: Dictionary) -> String:
	# PokeAPI style
	if ab.has("effect_entries") and typeof(ab["effect_entries"]) == TYPE_ARRAY:
		var langs := _preferred_langs()
		for code in langs:
			for e in (ab["effect_entries"] as Array):
				if typeof(e) != TYPE_DICTIONARY: continue
				var d := e as Dictionary
				if d.has("language") and typeof(d["language"]) == TYPE_DICTIONARY:
					var ln := str((d["language"] as Dictionary).get("name","")).to_lower()
					if ln == code:
						var s := str(d.get("short_effect","")).strip_edges()
						if s == "":
							s = str(d.get("effect","")).strip_edges()
						return s.replace("\n"," ").replace("\f"," ").strip_edges()

	# fallback vide
	return "Pas de description disponible."

func _pick_lang_id(d: Dictionary) -> int:
	# cas A: language_id
	if d.has("language_id"):
		return int(d.get("language_id", 0))
	# cas B: language:{id/name}
	if d.has("language") and typeof(d["language"]) == TYPE_DICTIONARY:
		var lang := d["language"] as Dictionary
		if lang.has("id"):
			return int(lang.get("id", 0))
		var n := str(lang.get("name", "")).to_lower()
		if n == "fr": return 5
		if n == "en": return 9
	return 0

func _ability_desc_fr_then_en(ability: Dictionary) -> String:
	# selon tes versions, ça peut être abilityeffecttexts ou autre
	var keys := ["abilityeffecttexts", "ability_effect_texts", "ability_effect_entries", "effect_entries"]
	var arr: Array = []
	for k in keys:
		if ability.has(k) and typeof(ability[k]) == TYPE_ARRAY:
			arr = ability[k]
			break
	if arr.is_empty():
		return ""

	var fr := ""
	var en := ""
	var any := ""

	for e in arr:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var d := e as Dictionary
		var lid := _pick_lang_id(d)

		# priorité au short_effect, sinon effect
		var txt := str(d.get("short_effect", ""))
		if txt == "":
			txt = str(d.get("effect", ""))
		txt = _clean_text(txt)
		if txt == "":
			continue

		if any == "":
			any = txt
		if lid == 5 and fr == "":
			fr = txt
		elif lid == 9 and en == "":
			en = txt

	if fr != "":
		return fr
	if en != "":
		return en
	return any



func _clear_talent_tabs() -> void:
	for i in range(tab_talents.get_tab_count() - 1, -1, -1):
		var c := tab_talents.get_tab_control(i)
		if c != null:
			c.queue_free()

func _build_talent_tabs(talents: Array[Dictionary]) -> void:
	# Force visibilité
	tab_talents.visible = true
	tab_talents.tabs_visible = true

	_clear_talent_tabs()

	if talents.is_empty():
		var lbl0 := Label.new()
		lbl0.text = "Aucun talent."
		lbl0.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl0.set_anchors_preset(Control.PRESET_FULL_RECT)
		lbl0.offset_left = 0
		lbl0.offset_top = 0
		lbl0.offset_right = 0
		lbl0.offset_bottom = 0
		tab_talents.add_child(lbl0)
		tab_talents.set_tab_title(0, "—")
		tab_talents.current_tab = 0
		return

	for t in talents:
		var tab_title := String(t.get("name", "—"))
		var desc := String(t.get("desc", "Pas de description disponible."))

		# Root du tab (Margin -> Scroll -> Label)
		var margin := MarginContainer.new()
		margin.set_anchors_preset(Control.PRESET_FULL_RECT)
		margin.offset_left = 0
		margin.offset_top = 0
		margin.offset_right = 0
		margin.offset_bottom = 0
		margin.add_theme_constant_override("margin_left", 10)
		margin.add_theme_constant_override("margin_right", 10)
		margin.add_theme_constant_override("margin_top", 10)
		margin.add_theme_constant_override("margin_bottom", 10)

		var scroll := ScrollContainer.new()
		scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
		scroll.offset_left = 0
		scroll.offset_top = 0
		scroll.offset_right = 0
		scroll.offset_bottom = 0
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		margin.add_child(scroll)

		var lbl := Label.new()
		lbl.text = desc
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.size_flags_vertical = Control.SIZE_EXPAND_FILL
		scroll.add_child(lbl)

		tab_talents.add_child(margin)
		tab_talents.set_tab_title(tab_talents.get_tab_count() - 1, tab_title)

	tab_talents.current_tab = 0

func _refresh_abilities(pokemon_id: int) -> void:
	if tab_talents == null:
		return

	# vide tout
	for c in tab_talents.get_children():
		c.queue_free()

	if pokemon_id <= 0:
		return

	# récup depuis table dex_pokemon_ability
	var rows := PokeDb._query_bind(
		"SELECT slot, ability_id, is_hidden FROM dex_pokemon_ability WHERE pokemon_id=? ORDER BY slot;",
		[pokemon_id]
	)

	for r in rows:
		var slot := int(r.get("slot", 0))
		var ability_id := int(r.get("ability_id", 0))
		var hidden := int(r.get("is_hidden", 0)) == 1
		if ability_id <= 0:
			continue

		var ability := PokeDb.get_entity("ability", ability_id)

		# DEBUG utile si jamais ça coince encore
		# print("ability#", ability_id, "keys=", ability.keys(), "has_effecttexts=", ability.has("abilityeffecttexts"))

		var title := _ability_name_fr_then_en(ability)
		if hidden:
			title += " (Caché)"

		var page := VBoxContainer.new()
		page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		page.size_flags_vertical = Control.SIZE_EXPAND_FILL

		var lbl := Label.new()
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.size_flags_vertical = Control.SIZE_EXPAND_FILL
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_TOP

		var desc := _ability_desc_fr_then_en(ability)
		lbl.text = desc if desc != "" else "Pas de description disponible."

		page.add_child(lbl)

		tab_talents.add_child(page)
		tab_talents.set_tab_title(tab_talents.get_tab_count() - 1, title)

func _ability_name_fr_then_en(ability: Dictionary) -> String:
	var keys := ["abilitynames", "ability_names", "names"]
	var arr: Array = []
	for k in keys:
		if ability.has(k) and typeof(ability[k]) == TYPE_ARRAY:
			arr = ability[k]
			break

	var fr := ""
	var en := ""
	for e in arr:
		if typeof(e) != TYPE_DICTIONARY: continue
		var d := e as Dictionary
		var lid := int(d.get("language_id", 0))
		var n := str(d.get("name", "")).strip_edges()
		if n == "": continue
		if lid == 5 and fr == "":
			fr = n
		elif lid == 9 and en == "":
			en = n

	if fr != "": return fr
	if en != "": return en
	# fallback sur ability.name (anglais “technique”)
	return str(ability.get("name","")).capitalize()

func _clean_text(t: String) -> String:
	var s := t.replace("\n", " ").replace("\f", " ")
	while s.find("  ") != -1:
		s = s.replace("  ", " ")
	return s.strip_edges()
