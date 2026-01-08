extends Button
class_name EvoNodeButton

var species_id := 0
var pokemon_id := 0

var _tex: Texture2D
var _title := ""
var _selected := false

func _ready() -> void:
	focus_mode = Control.FOCUS_NONE
	flat = true

func set_texture(t: Texture2D) -> void:
	_tex = t
	queue_redraw()

func set_title(t: String) -> void:
	_title = t
	queue_redraw()

func set_selected(v: bool) -> void:
	_selected = v
	queue_redraw()

func _draw() -> void:
	var r :int= min(size.x, size.y) * 0.5
	var c := size * 0.5

	# fond cercle
	var bg := Color(0,0,0,0.35)
	draw_circle(c, r, bg)

	# outline
	var outline := Color(1,1,1, 0.25)
	if _selected:
		outline = Color(1, 0.9, 0.2, 0.9)
	draw_arc(c, r - 2.0, 0, TAU, 64, outline, 4.0)

	# image (clippée “à la main” en cercle simple via draw_texture_rect + masque soft)
	if _tex:
		var inset := 8.0
		var rect := Rect2(Vector2(inset, inset), size - Vector2(inset*2, inset*2))
		draw_texture_rect(_tex, rect, true)

	# nom dessous (petit)
	if _title != "":
		var font := get_theme_default_font()
		var fs :int= max(10, get_theme_default_font_size() - 2)
		var w := font.get_string_size(_title, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var p := Vector2((size.x - w) * 0.5, size.y + fs + 2)
		draw_string(font, p, _title, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1,1,1,0.85))
