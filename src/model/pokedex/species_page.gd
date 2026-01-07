extends Control
class_name SpeciesPage


const ART_DIR := "res://Resource/texture/pokemon/other/official-artwork/"
const ART_FALLBACK := "res://Resource/texture/pokemon/0.png"

# ---- LEFT COL ----
@onready var img_slot: TextureRect = $Content/LeftColContainer/LeftCol/SpriteCard/AspectRatioContainer/TextureRect
@onready var lbl_type1: Label = $Content/LeftColContainer/LeftCol/TypeRow/TypeOnePill/TypeOne
@onready var lbl_type2: Label = $Content/LeftColContainer/LeftCol/TypeRow/TypeTwoPill/TypeTwo
@onready var type2_capsule : PanelContainer = $Content/LeftColContainer/LeftCol/TypeRow/TypeTwoPill

@onready var lbl_height: Label = $Content/LeftColContainer/LeftCol/QuickFacts/GridContainer/LblHeight
@onready var lbl_weight: Label = $Content/LeftColContainer/LeftCol/QuickFacts/GridContainer/LblWeight

# ---- RIGHT COL ----
@onready var lbl_name: Label = $Content/RightColContainer/RightCol/HeaderBlock/PokemonName
@onready var lbl_species: Label = $Content/RightColContainer/RightCol/HeaderBlock/Species
@onready var lbl_dex: Label = $Content/RightColContainer/RightCol/HeaderBlock/DexNumber

# BioCard
@onready var lbl_habitat: Label = $Content/RightColContainer/RightCol/InfoRow/BioCard/BioGrid/LblHabitat
@onready var lbl_color: Label = $Content/RightColContainer/RightCol/InfoRow/BioCard/BioGrid/LblColor
@onready var lbl_shape: Label = $Content/RightColContainer/RightCol/InfoRow/BioCard/BioGrid/LblShape
@onready var lbl_growth_rate: Label = $Content/RightColContainer/RightCol/InfoRow/BioCard/BioGrid/LblGrowthRate

# ReproCard
@onready var genre_bar: Range = $Content/RightColContainer/RightCol/InfoRow/ReproCard/MarginContainer2/ReproVBox/GenreBar
@onready var lbl_male: Label = $Content/RightColContainer/RightCol/InfoRow/ReproCard/MarginContainer2/ReproVBox/GenreBar/MalePercentage
@onready var lbl_female: Label = $Content/RightColContainer/RightCol/InfoRow/ReproCard/MarginContainer2/ReproVBox/GenreBar/FemalePercentage

@onready var lbl_egg_groups: Label = $Content/RightColContainer/RightCol/InfoRow/ReproCard/MarginContainer2/ReproVBox/VBoxContainer/EggGroups
@onready var lbl_capture_rate: Label = $Content/RightColContainer/RightCol/InfoRow/ReproCard/MarginContainer2/ReproVBox/VBoxContainer/CaptureRate
@onready var lbl_base_happiness: Label = $Content/RightColContainer/RightCol/InfoRow/ReproCard/MarginContainer2/ReproVBox/VBoxContainer/BaseHappiness

# DexEntryCard
@onready var lbl_def: Label = $Content/RightColContainer/RightCol/DexEntryCard/MarginContainer/Definition


func render_species(species_id: int, pokemon_id: int = 0, display_name: String = "") -> void:
	var species := PokeDb.get_entity("pokemon_species", species_id)
	if species.is_empty():
		_clear_ui("Species #%d introuvable" % species_id)
		return

	# --- Header name ---
	var base_name := str(species.get("name", "")).capitalize()
	lbl_name.text = display_name if display_name != "" else base_name

	# --- Genus / species label ---
	lbl_species.text = _pick_genus_fr_then_en(species)
	# si tu préfères vide quand introuvable, laisse comme ça
	# sinon mets un fallback : "—"

	# --- Dex number affiché (national = species id) ---
	lbl_dex.text = "%04d National" % species_id

	# --- pokemon_id (types + taille/poids) ---
	if pokemon_id <= 0:
		pokemon_id = _default_pokemon_id_for_species(species, species_id)

	var pokemon := PokeDb.get_entity("pokemon", pokemon_id) if pokemon_id > 0 else {}

	_set_types(pokemon_id)
	_set_height_weight(pokemon)

	_set_bio(species)
	_set_repro(species)

	var def := _get_pokedex_text(species, "fr")
	lbl_def.text = def if def != "" else "Pas de description disponible."

	# image
	_set_artwork(pokemon_id)
	print("species keys=", species.keys())
	print("egg_groups=", species.get("egg_groups", null))
	print("egg_group_ids=", species.get("egg_group_ids", null))
	print("pokemon_species_egg_groups=", species.get("pokemon_species_egg_groups", null))


func _clear_ui(msg: String) -> void:
	lbl_name.text = msg
	lbl_species.text = ""
	lbl_dex.text = ""

	lbl_type1.text = "-"
	lbl_type2.text = "-"
	lbl_height.text = "-"
	lbl_weight.text = "-"

	lbl_habitat.text = "-"
	lbl_color.text = "-"
	lbl_shape.text = "-"

	lbl_egg_groups.text = "-"
	lbl_capture_rate.text = "-"
	lbl_base_happiness.text = "-"

	genre_bar.visible = false
	lbl_def.text = ""


# --------------------
# DATA MAPPING helpers
# --------------------

func _set_bio(species: Dictionary) -> void:
	# habitat / color / shape sont souvent des objets {name,url} ou id dans ton cache “aplati”
	lbl_habitat.text = _named_ref(species.get("habitat", null), species.get("pokemon_habitat_id", null), "pokemon_habitat")
	lbl_color.text   = _named_ref(species.get("color", null),   species.get("pokemon_color_id", null),   "pokemon_color")
	lbl_shape.text   = _named_ref(species.get("shape", null),   species.get("pokemon_shape_id", null),   "pokemon_shape")
	lbl_growth_rate.text = _format_growth_rate(species)

func _set_repro(species: Dictionary) -> void:
	# egg groups : parfois egg_groups:[{name..},...] ou egg_group_ids
	lbl_egg_groups.text = _format_egg_groups(species)

	lbl_capture_rate.text = str(int(species.get("capture_rate", 0)))
	lbl_base_happiness.text = str(int(species.get("base_happiness", 0)))
	
	_set_gender(species)

func _format_growth_rate(species: Dictionary) -> String:
	# 1) PokeAPI: growth_rate: {name:"medium-slow", ...}
	if species.has("growth_rate") and typeof(species["growth_rate"]) == TYPE_DICTIONARY:
		var n := str((species["growth_rate"] as Dictionary).get("name","")).strip_edges()
		return _pretty_growth_rate_name(n)

	# 2) Cache aplati: growth_rate_id
	if species.has("growth_rate_id"):
		var id := int(species.get("growth_rate_id", 0))
		if id > 0:
			var gr := PokeDb.get_entity("growth_rate", id)
			var n2 := str(gr.get("name","")).strip_edges()
			return _pretty_growth_rate_name(n2)

	# 3) fallback
	return "-"

func _pretty_growth_rate_name(raw: String) -> String:
	var s := raw.to_lower().strip_edges()
	if s == "":
		return "-"

	match s:
		"slow": return "Slow"
		"medium": return "Medium"
		"fast": return "Fast"
		"medium-slow": return "Medium Slow"
		"slow-then-very-fast": return "Erratic"
		"fast-then-very-slow": return "Fluctuating"

	# fallback générique
	return s.replace("-", " ").capitalize()


func _format_egg_groups(species: Dictionary) -> String:
	var ids: Array[int] = []

	# (A) format direct : egg_group_ids: [1,7,...]
	if species.has("egg_group_ids") and typeof(species["egg_group_ids"]) == TYPE_ARRAY:
		for v in (species["egg_group_ids"] as Array):
			var id := int(v)
			if id > 0:
				ids.append(id)

	# (B) format relation : pokemonegggroups: [{egg_group_id:1}, ...]
	if ids.is_empty() and species.has("pokemonegggroups") and typeof(species["pokemonegggroups"]) == TYPE_ARRAY:
		for e in (species["pokemonegggroups"] as Array):
			if typeof(e) != TYPE_DICTIONARY:
				continue
			var d := e as Dictionary
			var id2 := int(d.get("egg_group_id", 0))
			if id2 > 0:
				ids.append(id2)

	# (C) si vraiment rien
	if ids.is_empty():
		return "-"

	# dédoublonne
	var uniq := {}
	for id3 in ids:
		uniq[id3] = true

	# résout en noms
	var names: Array[String] = []
	for k in uniq.keys():
		var eg := PokeDb.get_entity("egg_group", int(k))
		var n := str(eg.get("name", "")).strip_edges()
		if n != "":
			n = n.replace("-", " ").capitalize()
			names.append(n)
		else:
			# fallback si l'entity egg_group manque en DB
			names.append("EggGroup #%d" % int(k))

	names.sort()
	return " / ".join(names)


func _named_ref(obj_ref: Variant, id_ref: Variant, resource: String) -> String:
	# obj_ref : {name: "..."} ou null
	if typeof(obj_ref) == TYPE_DICTIONARY:
		var n := str((obj_ref as Dictionary).get("name",""))
		if n != "":
			return n.capitalize()

	# id_ref : int
	var id := int(id_ref) if id_ref != null else 0
	if id > 0:
		var e := PokeDb.get_entity(resource, id)
		var n2 := str(e.get("name",""))
		if n2 != "":
			return n2.capitalize()

	return "-"


# --------------------
# Existing helpers (repris)
# --------------------

func _set_types(pokemon_id: int) -> void:
	lbl_type1.text = "-"
	lbl_type2.text = "-"

	if pokemon_id <= 0:
		return

	var tids := PokeDb.pokemon_types_ids(pokemon_id)
	if tids.is_empty():
		return

	var t1 := PokeDb.get_entity("type", tids[0])
	lbl_type1.text = str(t1.get("name", "")).capitalize()

	if tids.size() >= 2:
		var t2 := PokeDb.get_entity("type", tids[1])
		lbl_type2.text = str(t2.get("name", "")).capitalize()
		type2_capsule.visible = true
	else:
		lbl_type2.text = "-"
		type2_capsule.visible = false


func _set_height_weight(pokemon: Dictionary) -> void:
	if pokemon.is_empty():
		lbl_height.text = "-"
		lbl_weight.text = "-"
		return

	var h_dm := float(pokemon.get("height", 0))
	var w_hg := float(pokemon.get("weight", 0))

	lbl_height.text = "%.1f m" % (h_dm / 10.0) if h_dm > 0 else "-"
	lbl_weight.text = "%.1f kg" % (w_hg / 10.0) if w_hg > 0 else "-"


func _set_gender(species: Dictionary) -> void:
	var gr := int(species.get("gender_rate", -2))

	if gr == -1:
		genre_bar.visible = true
		lbl_male.text = "♂ —"
		lbl_female.text = "♀ —"
		genre_bar.min_value = 0
		genre_bar.max_value = 100
		genre_bar.value = 0
		_apply_gender_bar_grey()
		return

	if gr < 0:
		genre_bar.visible = false
		return

	genre_bar.visible = true
	var female := float(gr) * 12.5
	var male := 100.0 - female

	lbl_male.text = "♂ %.1f%%" % male
	lbl_female.text = "♀ %.1f%%" % female

	genre_bar.min_value = 0
	genre_bar.max_value = 100
	genre_bar.value = male

	_apply_gender_bar_normal()

func _apply_gender_bar_grey() -> void:
	genre_bar.modulate = Color(0.7, 0.7, 0.7, 1.0)

func _apply_gender_bar_normal() -> void:
	genre_bar.modulate = Color(1, 1, 1, 1.0)

func _pick_genus(species: Dictionary, lang_id: int = 5) -> String:
	# ton ancien format “aplati”
	if species.has("pokemonspeciesnames") and typeof(species["pokemonspeciesnames"]) == TYPE_ARRAY:
		for v in (species["pokemonspeciesnames"] as Array):
			if typeof(v) != TYPE_DICTIONARY: continue
			var d := v as Dictionary
			if int(d.get("language_id", 0)) == lang_id:
				return str(d.get("genus", "")).strip_edges()
	return ""

func _pick_genus_fr_then_en(species: Dictionary) -> String:
	var g := _pick_genus(species, 5)
	if g == "":
		g = _pick_genus(species, 9)
	return g

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

func _clean_flavor(t: String) -> String:
	var s := t.replace("\n", " ").replace("\f", " ")
	while s.find("  ") != -1:
		s = s.replace("  ", " ")
	return s.strip_edges()

func _get_pokedex_text(species: Dictionary, prefer_lang: String = "fr") -> String:
	# tu as déjà ça, je le garde tel quel (juste compact)
	var keys := ["pokemonspeciesflavortexts", "pokemon_species_flavor_texts", "flavor_text_entries"]
	var entries: Array = []
	for k in keys:
		if species.has(k) and typeof(species[k]) == TYPE_ARRAY:
			entries = species[k]
			break
	if entries.is_empty():
		return ""

	var prefer := prefer_lang.to_lower()

	for e in entries:
		if typeof(e) != TYPE_DICTIONARY: continue
		var d := e as Dictionary
		var txt := str(d.get("flavor_text", ""))
		if txt == "": continue

		var lang_ok := false
		if d.has("language") and typeof(d["language"]) == TYPE_DICTIONARY:
			lang_ok = str((d["language"] as Dictionary).get("name","")).to_lower() == prefer
		elif d.has("language_id"):
			var lid := int(d.get("language_id", 0))
			var l := PokeDb.get_entity("language", lid)
			lang_ok = str(l.get("name","")).to_lower() == prefer

		if lang_ok:
			return _clean_flavor(txt)

	for e in entries:
		if typeof(e) != TYPE_DICTIONARY: continue
		var d := e as Dictionary
		var txt := str(d.get("flavor_text", ""))
		if txt != "":
			return _clean_flavor(txt)

	return ""

# =========================
# ARTWORK
# =========================
func _set_artwork(pokemon_id: int) -> void:
	var path := "%s%d.png" % [ART_DIR, pokemon_id]
	var final_path := path if ResourceLoader.exists(path) else ART_FALLBACK
	var tex := load(final_path)
	if tex is Texture2D:
		img_slot.texture = tex
