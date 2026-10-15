extends Control

@onready var target_num_label: Label = $TargetNumber
@onready var player_cards_container: HBoxContainer = $playerCards/HandLayout/ScrollContainer/HBoxContainer
@onready var opponent_cards_container: HBoxContainer = $opponentCards/HandLayout/ScrollContainer2/HBoxContainer
@onready var player_heading: Label = $playerCards/HandLayout/HandHeading
@onready var opponent_heading: Label = $opponentCards/HandLayout/HandHeading

var targetNum: int
var player_card_buttons: Array[Button] = []


func _ready() -> void:
	_render_player_cards()


func roll_number() -> int:
	var roll := randf()
	var cumulative := 0.0
	var weights := {
		12: 0.025,
		15: 0.125,
		18: 0.200,
		21: 0.300,
		24: 0.200,
		27: 0.125,
		30: 0.025,
	}

	for target in weights:
		cumulative += weights[target]
		if roll <= cumulative:
			return target

	return 21


func get_target_number() -> void:
	targetNum = roll_number()
	target_num_label.text = str(targetNum)


func _on_button_pressed() -> void:
	get_target_number()


func _render_player_cards() -> void:
	player_card_buttons.clear()
	var local_player: Dictionary = {}
	var opponent_players: Array[Dictionary] = []
	var local_peer_id := multiplayer.get_unique_id()

	for player_data in Global.game_players:
		if int(player_data.get("peer_id", -1)) == local_peer_id and local_player.is_empty():
			local_player = player_data
		else:
			opponent_players.append(player_data)

	if local_player.is_empty():
		player_heading.text = "Your hand (no cards)"
	else:
		var player_cards: Array = local_player.get("cards", [])
		for card_index in range(player_cards.size()):
			var card_data: Dictionary = player_cards[card_index]
			_add_player_card(str(card_data.get("name", "Unknown card")))
		if player_card_buttons.is_empty():
			_add_empty_card_message(player_cards_container, "No cards in hand.")
		_update_player_heading()

	var hidden_card_count := 0
	var opponent_names: Array[String] = []
	for opponent_data in opponent_players:
		var opponent_cards: Array = opponent_data.get("cards", [])
		hidden_card_count += opponent_cards.size()
		opponent_names.append(str(opponent_data.get("name", "Opponent")))
		for _card_index in range(opponent_cards.size()):
			_add_face_down_card()

	if opponent_players.is_empty():
		opponent_heading.text = "Opponent (no cards)"
	else:
		var opponent_label := ", ".join(opponent_names)
		opponent_heading.text = "%s (%d cards, face down)" % [
			opponent_label,
			hidden_card_count,
		]
		if hidden_card_count == 0:
			_add_empty_card_message(opponent_cards_container, "No cards.")


func _add_player_card(card_name: String) -> void:
	var card_button := Button.new()
	card_button.text = card_name
	card_button.tooltip_text = "Click to select this card to put out."
	card_button.custom_minimum_size = Vector2(100, 136)
	card_button.toggle_mode = true
	card_button.pressed.connect(_on_player_card_pressed.bind(card_button))
	player_cards_container.add_child(card_button)
	player_card_buttons.append(card_button)


func _add_face_down_card() -> void:
	var card_back := Button.new()
	card_back.text = "?"
	card_back.tooltip_text = "Opponent card"
	card_back.custom_minimum_size = Vector2(100, 136)
	card_back.disabled = true
	opponent_cards_container.add_child(card_back)


func _add_empty_card_message(container: HBoxContainer, message: String) -> void:
	var empty_message := Label.new()
	empty_message.text = message
	empty_message.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	container.add_child(empty_message)


func _on_player_card_pressed(_card_button: Button) -> void:
	_update_player_heading()


func _update_player_heading() -> void:
	var selected_count := 0
	for card_button in player_card_buttons:
		if card_button.button_pressed:
			selected_count += 1
	player_heading.text = "Your hand - click cards to select (%d selected)" % selected_count
