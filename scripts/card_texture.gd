class_name CardTexture
extends RefCounted

const SUITS: Array[String] = ["Crown", "Fire", "Skull"]
const BACK_PATH := "res://Assets/BackCard.png"
const FACE_PATHS := {
	"jack": "res://Assets/cards/Jack.png",
	"queen": "res://Assets/cards/Queen.png",
	"king": "res://Assets/cards/King.png",
	"minus": "res://Assets/cards/Minus.png",
	"multiplication": "res://Assets/cards/Multiplication.png",
	"division": "res://Assets/cards/Division.png",
}
const HIGHLIGHT := Color(1.0, 0.85, 0.45)
const PAPER := Color(0.78, 0.65, 0.45)
const INK := Color(0.1, 0.06, 0.04)


static func get_texture(card_name: String, suit: String) -> Texture2D:
	var path := ""
	if FACE_PATHS.has(card_name):
		path = FACE_PATHS[card_name]
	elif card_name.is_valid_int() and SUITS.has(suit):
		path = "res://Assets/cards/%s%d.png" % [suit, int(card_name)]
	if path != "" and ResourceLoader.exists(path):
		return load(path) as Texture2D
	return null


static func make_card_back(size: Vector2) -> Button:
	var button := _base_button(size)
	_apply_texture(button, load(BACK_PATH) as Texture2D, false)
	return button


# Cards without art (the 10s and Jokers) fall back to a plain paper card with the title on it.
static func make_card_button(card_name: String, suit: String, title: String, size: Vector2) -> Button:
	var button := _base_button(size)
	var texture := get_texture(card_name, suit)
	if texture != null:
		_apply_texture(button, texture, true)
	else:
		button.text = title
		button.add_theme_color_override("font_color", INK)
		button.add_theme_color_override("font_hover_color", INK)
		button.add_theme_color_override("font_pressed_color", INK)
		button.add_theme_color_override("font_hover_pressed_color", INK)
		button.add_theme_color_override("font_disabled_color", INK.lerp(PAPER, 0.4))
		button.add_theme_font_size_override("font_size", maxi(14, int(size.x * 0.28)))
		button.add_theme_stylebox_override("normal", _box(PAPER, INK, 3))
		button.add_theme_stylebox_override("disabled", _box(PAPER, INK, 3))
		button.add_theme_stylebox_override("hover", _box(PAPER, HIGHLIGHT, 3))
		button.add_theme_stylebox_override("pressed", _box(PAPER, HIGHLIGHT, 4))
		button.add_theme_stylebox_override("hover_pressed", _box(PAPER, HIGHLIGHT, 4))
	return button


static func _base_button(size: Vector2) -> Button:
	var button := Button.new()
	button.custom_minimum_size = size
	button.size = size
	button.focus_mode = Control.FOCUS_NONE
	return button


static func _apply_texture(button: Button, texture: Texture2D, dim_when_disabled: bool) -> void:
	button.icon = texture
	button.expand_icon = true
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
	var empty := StyleBoxEmpty.new()
	button.add_theme_stylebox_override("normal", empty)
	button.add_theme_stylebox_override("disabled", empty)
	button.add_theme_stylebox_override("hover", _box(Color(0, 0, 0, 0), HIGHLIGHT, 3))
	button.add_theme_stylebox_override("pressed", _box(Color(0, 0, 0, 0), HIGHLIGHT, 4))
	button.add_theme_stylebox_override("hover_pressed", _box(Color(0, 0, 0, 0), HIGHLIGHT, 4))
	var disabled_tint := Color(1, 1, 1, 0.6) if dim_when_disabled else Color.WHITE
	button.add_theme_color_override("icon_disabled_color", disabled_tint)
	button.add_theme_color_override("icon_normal_color", Color.WHITE)
	button.add_theme_color_override("icon_hover_color", Color.WHITE)
	button.add_theme_color_override("icon_pressed_color", Color.WHITE)
	button.add_theme_color_override("icon_hover_pressed_color", Color.WHITE)


static func _box(bg: Color, border: Color, border_width: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = border
	style.set_border_width_all(border_width)
	style.set_corner_radius_all(8)
	return style
