extends Control
class_name EvolutionGraph

signal pokemon_selected(pokemon_id: int, species_id: int)

@export var node_size := 86.0
@export var h_gap := 120.0
@export var v_gap := 34.0
@export var padding := Vector2(40, 30)

@export var center_content := true

@export var two_children_y_spread := 120.0      # écart vertical pour le cas 2
@export var three_children_x_spread := 160.0    # écart horizontal pour le cas 3
@export var flower_radius := 170.0              # rayon de base pour >3
@export var flower_radius_step := 22.0          # + de rayon par enfant au-delà de 4

var _center := {}   # species_id -> Vector2 (centre)

const ART_DIR := "res://Resource/texture/pokemon/other/official-artwork/"
const ART_FALLBACK := "res://Resource/texture/pokemon/0.png"
var _pending_rerender := false
var _evo := {}
var _current_species := 0
var _pos := {}              # species_id -> Vector2 (top-left)
var _depth_of := {}         # species_id -> int
var _y_slot := {}           # species_id -> float
var _leaf_index := 0

# species_id -> Control (node)
var _node_controls := {}

func clear() -> void:
	_evo = {}
	_current_species = 0
	_node_controls.clear()
	for c in get_children():
		c.queue_free()
	queue_redraw()

func render(evo: Dictionary, current_species_id: int) -> void:
	clear()
	_evo = evo
	_current_species = current_species_id

	var root := int(evo.get("root_species_id", -1))
	if root <= 0:
		return

	var nodes: Dictionary = evo.get("nodes", {})
	var children: Dictionary = evo.get("children", {})

	# 1) layout (centres)
	_layout_chain(root, children)

	# 2) bounding rect (inclut le titre sous le node)
	var title_h := 18.0
	var min_x :=  1e9
	var min_y :=  1e9
	var max_x := -1e9
	var max_y := -1e9

	for sid in _center.keys():
		var c: Vector2 = _center[int(sid)]
		var tl := c - Vector2(node_size * 0.5, node_size * 0.5)
		var br := tl + Vector2(node_size, node_size + title_h)
		min_x = min(min_x, tl.x)
		min_y = min(min_y, tl.y)
		max_x = max(max_x, br.x)
		max_y = max(max_y, br.y)

	var rect_size := Vector2(max_x - min_x, max_y - min_y)
	var rect_origin := Vector2(min_x, min_y)
	# 3) taille scroll + centrage
	var wanted_size := Vector2(
		rect_size.x + padding.x * 2.0,
		rect_size.y + padding.y * 2.0
	)

	# Taille pas prête au premier affichage (VBox pas layout)
	if size.x < 2 or size.y < 2:
		if not _pending_rerender:
			_pending_rerender = true
			call_deferred("_rerender_next_frame")
		return
	# si ton graph est dans un ScrollContainer, size = viewport visible
	var target_size := Vector2(
		max(wanted_size.x, size.x),
		max(wanted_size.y, size.y)
	)
	custom_minimum_size = target_size

	var shift := Vector2.ZERO
	if center_content:
		var desired_origin := (target_size - rect_size) * 0.5
		shift = desired_origin - Vector2(min_x, min_y)
	else:
		shift = Vector2(padding.x, padding.y) - Vector2(min_x, min_y)

	# 4) instanciation des boutons
	for sid_any in _center.keys():
		var sid := int(sid_any)
		var c: Vector2 = _center[sid] + shift
		var pos := c - Vector2(node_size * 0.5, node_size * 0.5)

		var btn := EvoNodeButton.new()
		btn.size = Vector2(node_size, node_size)
		btn.position = pos
		btn.species_id = sid
		btn.pokemon_id = sid # placeholder pour l’instant
		btn.set_selected(sid == _current_species)

		var sp: Variant = nodes.get(sid, {})
		btn.set_title(String(sp.get("name", "")).capitalize())
		btn.set_texture(_load_art(btn.pokemon_id))

		btn.pressed.connect(func():
			emit_signal("pokemon_selected", btn.pokemon_id, btn.species_id)
		)

		add_child(btn)
		_node_controls[sid] = btn

	queue_redraw()



func _load_art(pokemon_id: int) -> Texture2D:
	var path := "%s%d.png" % [ART_DIR, pokemon_id]
	var final_path := path if ResourceLoader.exists(path) else ART_FALLBACK
	var tex := load(final_path)
	return tex if tex is Texture2D else null

func _draw() -> void:
	if _evo.is_empty():
		return

	var children: Dictionary = _evo.get("children", {})
	var ed: Dictionary = _evo.get("edge_details", {})

	var line_col := Color(1, 1, 1, 0.25)
	var head_col := Color(1, 1, 1, 0.60)

	for parent in children.keys():
		var p := int(parent)
		if not _node_controls.has(p):
			continue

		var pctrl: Control = _node_controls[p]
		var p_center := pctrl.position + pctrl.size * 0.5

		for kid in (children[p] as Array):
			var k := int(kid)
			if not _node_controls.has(k):
				continue

			var kctrl: Control = _node_controls[k]
			var k_center := kctrl.position + kctrl.size * 0.5

			var dir := (k_center - p_center)
			if dir.length() < 0.001:
				continue
			dir = dir.normalized()

			# on part du bord du cercle parent et on arrive au bord du cercle enfant
			var start := p_center + dir * (node_size * 0.5)
			var tip := k_center - dir * (node_size * 0.5)

			draw_line(start, tip, line_col, 3.0)
			_draw_arrow_head(tip, dir, 12.0, head_col)

			# label
			var key := "%d->%d" % [p, k]
			var dets: Array = ed.get(key, [])
			var label := _format_edge_label(dets)

			# midpoint + petit décalage perpendiculaire pour lire mieux
			var mid := (start + tip) * 0.5
			var perp := Vector2(-dir.y, dir.x)
			_draw_edge_label(mid + perp * 18.0, label)


func _dfs_layout(children: Dictionary, id: int, depth: int) -> void:
	_depth_of[id] = depth

	var kids := _kids_sorted(children, id)
	if kids.is_empty():
		_y_slot[id] = float(_leaf_index)
		_leaf_index += 1
		return

	for k in kids:
		_dfs_layout(children, k, depth + 1)

	var sum := 0.0
	for k in kids:
		sum += float(_y_slot[k])
	_y_slot[id] = sum / float(kids.size())

func _ordered_ids() -> Array[int]:
	var ordered: Array[int] = []
	for k in _depth_of.keys():
		ordered.append(int(k))

	ordered.sort_custom(func(a: int, b: int) -> bool:
		var da := int(_depth_of[a])
		var db := int(_depth_of[b])
		if da != db:
			return da < db
		return float(_y_slot[a]) < float(_y_slot[b])
	)

	return ordered

func _draw_arrow_head(tip: Vector2, dir: Vector2, size: float, col: Color) -> void:
	# dir doit être normalisé
	var d := dir.normalized()
	var side := Vector2(-d.y, d.x) # perpendiculaire
	var p1 := tip - d * size + side * (size * 0.6)
	var p2 := tip - d * size - side * (size * 0.6)
	draw_polygon(PackedVector2Array([tip, p1, p2]), PackedColorArray([col, col, col]))

func _draw_edge_label(mid: Vector2, text: String) -> void:
	if text.is_empty():
		return

	var font := get_theme_default_font()
	var fs :int= max(10, get_theme_default_font_size() - 2)

	# taille texte
	var ts := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var pad := Vector2(8, 4)
	var box_size := ts + pad * 2.0

	# place le badge centré sur mid
	var pos := mid - box_size * 0.5
	var rect := Rect2(pos, box_size)

	# fond + bord
	var bg := Color(0, 0, 0, 0.65)
	var border := Color(1, 1, 1, 0.18)

	draw_rect(rect, bg, true)
	draw_rect(rect, border, false, 1.0)

	# texte
	var text_pos := pos + Vector2(pad.x, pad.y + fs)
	draw_string(font, text_pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1,1,1,0.92))

func _format_edge_label(dets: Array) -> String:
	if dets.is_empty():
		return ""

	var parts: Array[String] = []

	for det_any in dets:
		if typeof(det_any) != TYPE_DICTIONARY:
			continue
		var det := det_any as Dictionary

		# --- ITEM (prioritaire) ---
		var item_label := _extract_item_label(det)
		if item_label != "":
			parts.append(item_label)

		# --- LEVEL ---
		var ml :Variant= det.get("min_level", null)
		if ml != null:
			var lv := int(float(ml))
			if lv > 0:
				parts.append("Lvl %d" % lv)

		# --- HAPPINESS / AFFECTION / BEAUTY ---
		var mh :Variant= det.get("min_happiness", null)
		if mh != null and int(mh) > 0:
			parts.append("Bonheur %d+" % int(mh))

		var ma :Variant= det.get("min_affection", null)
		if ma != null and int(ma) > 0:
			parts.append("Affection %d+" % int(ma))

		var mb :Variant= det.get("min_beauty", null)
		if mb != null and int(mb) > 0:
			parts.append("Beauté %d+" % int(mb))

		# --- TIME OF DAY ---
		var tod := str(det.get("time_of_day", "")).strip_edges()
		if tod != "":
			if tod == "day":
				parts.append("Jour")
			elif tod == "night":
				parts.append("Nuit")
			else:
				parts.append(tod)

		# --- RAIN ---
		if bool(det.get("needs_overworld_rain", false)):
			parts.append("Pluie")

		# --- SPECIAL CASES ---
		if bool(det.get("turn_upside_down", false)):
			parts.append("Console inversée")

		var rps :Variant= det.get("relative_physical_stats", null)
		if rps != null:
			var ri := int(rps)
			if ri == 1: parts.append("Atk>Def")
			elif ri == -1: parts.append("Atk<Def")
			elif ri == 0: parts.append("Atk=Def")

		# --- Trigger fallback (si rien d’autre) ---
		# Si on a déjà un item, on évite d’ajouter "use-item"
		var trig :Variant= det.get("trigger", null)
		if trig != null and typeof(trig) == TYPE_DICTIONARY:
			var tn := str((trig as Dictionary).get("name", "")).strip_edges()
			if tn != "" and tn != "level-up" and tn != "use-item":
				parts.append(tn)

	if parts.is_empty():
		return ""
	return " • ".join(parts)

func _extract_item_label(det: Dictionary) -> String:
	var item_v :Variant= det.get("item", null)
	if item_v == null or typeof(item_v) != TYPE_DICTIONARY:
		return ""
	var name := str((item_v as Dictionary).get("name", "")).strip_edges()
	if name == "":
		return ""
	return _pretty_item_name(name)

func _pretty_item_name(n: String) -> String:
	# quelques traductions “connues” (pierres)
	var stone_map := {
		"thunder-stone": "Pierre Foudre",
		"water-stone": "Pierre Eau",
		"fire-stone": "Pierre Feu",
		"leaf-stone": "Pierre Plante",
		"ice-stone": "Pierre Glace",
		"moon-stone": "Pierre Lune",
		"sun-stone": "Pierre Soleil",
		"shiny-stone": "Pierre Éclat",
		"dusk-stone": "Pierre Nuit",
		"dawn-stone": "Pierre Aube",
	}
	if stone_map.has(n):
		return stone_map[n]

	# fallback: "razor-claw" -> "Razor Claw"
	var parts := n.split("-", false)
	for i in range(parts.size()):
		var p := parts[i]
		if p.length() > 0:
			parts[i] = p[0].to_upper() + p.substr(1)
	return " ".join(parts)

func _kids_sorted(children: Dictionary, id: int) -> Array[int]:
	var out: Array[int] = []
	var raw: Array = children.get(id, [])
	for v in raw:
		out.append(int(v))
	out.sort()
	return out

func _layout_chain(root_id: int, children: Dictionary) -> void:
	_center.clear()
	_layout_node(root_id, Vector2.ZERO, children)

func _layout_node(id: int, center: Vector2, children: Dictionary) -> void:
	if _center.has(id):
		return
	_center[id] = center

	var kids := _kids_sorted(children, id)
	var n := kids.size()
	if n == 0:
		return

	# distances de base
	var step_x := node_size + h_gap
	var step_y := node_size + v_gap + 18.0 # 18 = place pour ton titre sous le cercle

	if n == 1:
		_layout_node(kids[0], center + Vector2(step_x, 0), children)
		return

	if n == 2:
		var base := center + Vector2(step_x, 0)
		var dy := two_children_y_spread * 0.5
		_layout_node(kids[0], base + Vector2(0, -dy), children)
		_layout_node(kids[1], base + Vector2(0,  dy), children)
		return

	if n == 3:
		var y := center.y + step_y
		var dx := three_children_x_spread
		_layout_node(kids[0], Vector2(center.x - dx, y), children)
		_layout_node(kids[1], Vector2(center.x,      y), children)
		_layout_node(kids[2], Vector2(center.x + dx,  y), children)
		return

	# n > 3 : fleur autour du parent
	var r := flower_radius + float(max(0, n - 4)) * flower_radius_step
	var start_angle := -PI * 0.5  # commence en haut
	for i in range(n):
		var a := start_angle + (TAU * float(i) / float(n))
		var c := center + Vector2(cos(a), sin(a)) * r
		_layout_node(kids[i], c, children)

func _get_visible_size() -> Vector2:
	var p := get_parent()
	if p != null and p is ScrollContainer:
		return (p as ScrollContainer).size
	# fallback : viewport
	var vr := get_viewport_rect()
	if vr.size.x > 0 and vr.size.y > 0:
		return vr.size
	return size

func _rerender_next_frame() -> void:
	await get_tree().process_frame
	_pending_rerender = false
	if _evo.is_empty():
		return
	render(_evo, _current_species)
