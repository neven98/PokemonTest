extends Control
class_name RadarChart

@export var max_value: float = 255.0
@export var ring_count: int = 6
@export var value_label_offset: float = 14.0 # distance du texte par rapport au point

var _labels: Array[String] = ["HP", "ATT", "DEF", "ATT SP", "DEF SP", "SPEED"]
var _plot_values: Array[float] = [0,0,0,0,0,0]      # ce qui est dessiné (clampé)
var _display_values: Array[int] = [0,0,0,0,0,0]     # ce qui est affiché (peut dépasser 255)

func set_series(labels: Array, plot_values: Array, display_values: Array, p_max_value: float = 255.0) -> void:
	max_value = p_max_value
	_labels = []
	for v in labels:
		_labels.append(String(v))
	_plot_values = []
	_display_values = []

	for i in range(_labels.size()):
		var pv := 0.0
		var dv := 0
		if i < plot_values.size(): pv = float(plot_values[i])
		if i < display_values.size(): dv = int(display_values[i])
		_plot_values.append(pv)
		_display_values.append(dv)

	queue_redraw()

func set_series_animated(labels: Array, plot_values: Array, display_values: Array, p_max_value: float = 255.0, duration: float = 0.25) -> void:
	# animation simple: tween sur _plot_values
	var old := _plot_values.duplicate()
	set_series(labels, plot_values, display_values, p_max_value)

	# si tailles différentes, pas d’anim propre -> redraw direct
	if old.size() != _plot_values.size():
		queue_redraw()
		return

	var start := old
	var target := _plot_values.duplicate()
	_plot_values = start.duplicate()

	var t := create_tween()
	t.tween_method(func(a: float):
		for i in range(_plot_values.size()):
			_plot_values[i] = lerp(start[i], target[i], a)
		queue_redraw()
	, 0.0, 1.0, duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func _draw() -> void:
	var s := size
	if s.x <= 4 or s.y <= 4:
		return

	var center := s * 0.5
	var radius: float = min(s.x, s.y) * 0.42
	var n := _labels.size()
	if n < 3:
		return

	# --- tuning distances ---
	var label_radius := radius + 18.0     # <- labels plus proches (au lieu de +22)
	var value_radius := radius + 6.0      # <- valeurs entre le graphe et les labels
	var min_sep := 16.0                   # <- séparation mini value <-> label

	# couleurs basiques
	var col_grid := Color(1,1,1,0.35)
	var col_axis := Color(1,1,1,0.25)
	var col_poly := Color(1,0.2,0.2,0.95)
	var col_fill := Color(1,0.2,0.2,0.20)
	var col_text := Color(1,1,1,0.85)
	var col_value := Color(1,1,1,0.70)

	# grid rings
	for r_i in range(1, ring_count + 1):
		var rr := radius * (float(r_i) / float(ring_count))
		_draw_polygon_outline(_regular_polygon(center, rr, n), col_grid, 2.0)
	# axes
	for i in range(n):
		var ang := -PI/2.0 + (TAU * float(i) / float(n))
		var p := center + Vector2(cos(ang), sin(ang)) * radius
		draw_line(center, p, col_axis, 2.0)
	# labels (autour)
	var font := get_theme_default_font()
	var font_size := get_theme_default_font_size()
	for i in range(n):
		var ang := -PI/2.0 + (TAU * float(i) / float(n))
		var p_label := center + Vector2(cos(ang), sin(ang)) * label_radius
		var txt := _labels[i]
		var w := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		draw_string(font, p_label - Vector2(w * 0.5, 0), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, col_text)
	# polygon (valeurs)
	var pts := PackedVector2Array()
	for i in range(n):
		var v := 0.0
		if i < _plot_values.size():
			v = clamp(_plot_values[i], 0.0, max_value)
		var k := 0.0 if max_value <= 0.0 else (v / max_value)
		var ang := -PI/2.0 + (TAU * float(i) / float(n))
		var p := center + Vector2(cos(ang), sin(ang)) * (radius * k)
		pts.append(p)
	# fill + outline
	draw_colored_polygon(pts, col_fill)
	_draw_polygon_outline(pts, col_poly, 3.0)
	# valeurs (affiche display_values) - placement anti-chevauchement avec labels
	for i in range(n):
		var dv := 0
		if i < _display_values.size():
			dv = _display_values[i]
		var txtv := str(dv)

		var ang := -PI/2.0 + (TAU * float(i) / float(n))
		var dir := Vector2(cos(ang), sin(ang))
		var tangent := Vector2(-dir.y, dir.x)

		# 0 = haut/bas, 1 = côtés (gauche/droite)
		var side_t :float= clamp(1.0 - abs(dir.y), 0.0, 1.0)

		# positions de référence
		var p_label := center + dir * label_radius

		# on part du point réel du polygone, puis on sort un peu
		var p_val := pts[i] + dir * value_label_offset

		# séparation min (plus forte sur les côtés)
		min_sep = lerp(18.0, 32.0, side_t)

		# si trop proche du label, on pousse vers l'intérieur
		if p_val.distance_to(p_label) < min_sep:
			p_val = p_label - dir * min_sep

		# petit décalage tangent (uniquement sur les côtés)
		# sens opposé selon gauche/droite pour que ça “s’écarte” bien
		var tangent_sign := 1.0 if dir.x >= 0.0 else -1.0
		p_val += tangent * (10.0 * side_t * tangent_sign)

		# --- dessin du texte avec ancrage selon le côté ---
		var wv := font.get_string_size(txtv, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x

		var draw_pos := p_val
		if dir.x > 0.25:
			# côté droit -> texte part à droite
			draw_pos = p_val + Vector2(2, 0)
		elif dir.x < -0.25:
			# côté gauche -> texte ancré à droite
			draw_pos = p_val - Vector2(wv + 2, 0)
		else:
			# haut/bas -> centré
			draw_pos = p_val - Vector2(wv * 0.5, 0)

		draw_string(font, draw_pos, txtv, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, col_value)


func _regular_polygon(center: Vector2, radius: float, n: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in range(n):
		var ang := -PI/2.0 + (TAU * float(i) / float(n))
		out.append(center + Vector2(cos(ang), sin(ang)) * radius)
	return out

func _draw_polygon_outline(pts: PackedVector2Array, color: Color, width: float) -> void:
	var n := pts.size()
	for i in range(n):
		draw_line(pts[i], pts[(i+1) % n], color, width)
