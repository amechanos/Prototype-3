extends Control

const DECK_SIZE := 50
const FACE_DOWN_LABEL := "?"
const DRAW_THREE_SENTINEL := -1
const BOARD_CARD_SIZE := Vector2(78, 120)
const DECK_CARD_SIZE := Vector2(96, 148)
const BOARD_GAP := 12.0
const CARD_NAMES: Array[String] = [
	"1", "2", "3", "4", "5", "6", "7", "8", "9", "10",
	"jack", "queen", "king", "joker", "minus", "multiplication", "division",
]
const CARD_COUNTS := {
	"1": 3,
	"2": 3,
	"3": 3,
	"4": 3,
	"5": 3,
	"6": 3,
	"7": 3,
	"8": 3,
	"9": 3,
	"10": 3,
	"jack": 3,
	"queen": 3,
	"king": 3,
	"minus": 3,
	"multiplication": 3,
	"division": 3,
	"joker": 2,
}

@onready var board_grid: GridContainer = $MarginContainer/Layout/BoardScroll/BoardGrid
@onready var your_deck_flow: HFlowContainer = $MarginContainer/Layout/YourDeckScroll/YourDeckFlow
@onready var your_deck_count_label: Label = $MarginContainer/Layout/Counts/YourDeckCount
@onready var board_count_label: Label = $MarginContainer/Layout/Counts/BoardCount
@onready var turn_label: Label = $MarginContainer/Layout/TurnLabel
@onready var draw_three_button: Button = $MarginContainer/Layout/DrawOptions/DrawThreeButton
@onready var status_label: Label = $MarginContainer/Layout/Status
@onready var start_game_button: Button = $StartGame
@onready var board_scroll: ScrollContainer = $MarginContainer/Layout/BoardScroll

var board_card_size := BOARD_CARD_SIZE
var available_card_ids: Array[int] = []
var card_by_id: Dictionary = {}
var card_name_by_id: Dictionary = {}
var card_suit_by_id: Dictionary = {}
var card_buttons: Dictionary = {}
var collected_card_owners: Dictionary = {}
var player_order: Array[int] = []
var current_turn_id := 1


func _ready() -> void:
	DevilStyle.apply(self)
	_style_board_ui()
	randomize()
	if not _load_card_resources():
		return
	draw_three_button.pressed.connect(_on_draw_three_pressed)
	if multiplayer.multiplayer_peer != null:
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)

	if multiplayer.multiplayer_peer == null or multiplayer.is_server():
		_initialize_board()
	elif multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		status_label.text = "Syncing the shared board with the host..."
		_request_board_state.rpc_id(1)
	else:
		status_label.text = "Waiting for the host to connect..."

	board_scroll.resized.connect(_fit_board_cards)
	_fit_board_cards()


func _load_card_resources() -> bool:
	var card_id := 0
	for card_name in CARD_NAMES:
		var resource_path := "res://cards/%s.tres" % card_name
		var card_data := load(resource_path) as Resource
		if card_data == null:
			push_error("Could not load card resource: %s" % resource_path)
			return false

		for copy_index in range(CARD_COUNTS[card_name]):
			card_by_id[card_id] = card_data
			card_name_by_id[card_id] = card_name
			card_suit_by_id[card_id] = DevilStyle.SUITS[copy_index % DevilStyle.SUITS.size()]
			card_id += 1

	if card_by_id.size() != DECK_SIZE:
		push_error("Expected %d cards, but loaded %d." % [DECK_SIZE, card_by_id.size()])
		return false
	return true


func _initialize_board() -> void:
	available_card_ids.clear()
	for card_id in range(DECK_SIZE):
		available_card_ids.append(card_id)
	available_card_ids.shuffle()
	player_order = [multiplayer.get_unique_id()]
	if multiplayer.multiplayer_peer != null:
		var peer_ids := multiplayer.get_peers()
		peer_ids.sort()
		for peer_id in peer_ids:
			player_order.append(int(peer_id))
	current_turn_id = player_order[0]
	_render_board()
	_update_counts()
	_update_turn_ui()
	_update_start_game_button()
	status_label.text = "Choose a draw option on your turn."


func _render_board() -> void:
	for child in board_grid.get_children():
		child.queue_free()
	card_buttons.clear()

	for card_id in available_card_ids:
		var card_button: Button
		if _is_number_card(card_id):
			card_button = DevilStyle.make_card_back(board_card_size)
		else:
			card_button = DevilStyle.make_card_button(
				str(card_name_by_id[card_id]),
				str(card_suit_by_id[card_id]),
				_get_board_card_name(card_id),
				board_card_size
			)
			card_button.pressed.connect(_on_card_pressed.bind(card_id))
		board_grid.add_child(card_button)
		card_buttons[card_id] = card_button


func _on_card_pressed(card_id: int) -> void:
	if not _is_my_turn():
		status_label.text = "Wait for your turn to draw."
		return
	_request_draw(card_id)


func _on_draw_three_pressed() -> void:
	_request_draw(DRAW_THREE_SENTINEL)


func _request_draw(card_id: int) -> void:
	if not _is_my_turn():
		status_label.text = "Wait for your turn to draw."
		return

	if multiplayer.multiplayer_peer == null or multiplayer.is_server():
		_process_draw_request(multiplayer.get_unique_id(), card_id)
	elif multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		_request_draw_from_host.rpc_id(1, card_id)
	else:
		status_label.text = "You must be connected to the host to draw."


@rpc("any_peer", "call_remote", "reliable")
func _request_draw_from_host(card_id: int) -> void:
	if not multiplayer.is_server():
		return
	_process_draw_request(multiplayer.get_remote_sender_id(), card_id)


func _process_draw_request(drawer_id: int, selected_card_id: int) -> void:
	if not multiplayer.is_server() and multiplayer.multiplayer_peer != null:
		return
	if drawer_id != current_turn_id or not player_order.has(drawer_id):
		return

	var drawn_card_ids: Array[int] = []
	if selected_card_id == DRAW_THREE_SENTINEL:
		var face_down_ids: Array[int] = []
		for card_id in available_card_ids:
			if _is_number_card(card_id):
				face_down_ids.append(card_id)
		if face_down_ids.size() < 3:
			if drawer_id == multiplayer.get_unique_id():
				status_label.text = "There are fewer than three face-down cards left."
			return

		face_down_ids.shuffle()
		for index in range(3):
			drawn_card_ids.append(face_down_ids[index])
	elif available_card_ids.has(selected_card_id) and not _is_number_card(selected_card_id):
		drawn_card_ids.append(selected_card_id)
	else:
		return

	var next_turn_id := _get_next_turn_id(drawer_id)
	if multiplayer.multiplayer_peer == null:
		_apply_draw(drawn_card_ids, drawer_id, next_turn_id)
	else:
		_apply_draw.rpc(drawn_card_ids, drawer_id, next_turn_id)


@rpc("any_peer", "call_remote", "reliable")
func _request_board_state() -> void:
	if not multiplayer.is_server():
		return
	var requesting_peer := multiplayer.get_remote_sender_id()
	_send_board_state.rpc_id(
		requesting_peer,
		available_card_ids,
		collected_card_owners,
		player_order,
		current_turn_id
	)


@rpc("authority", "call_remote", "reliable")
func _send_board_state(
	remaining_ids: Array[int],
	collected_owners: Dictionary,
	players: Array[int],
	turn_id: int
) -> void:
	available_card_ids = remaining_ids.duplicate()
	collected_card_owners = collected_owners.duplicate()
	player_order = players.duplicate()
	current_turn_id = turn_id
	_render_board()
	_render_your_deck()
	_update_counts()
	_update_turn_ui()
	_update_start_game_button()
	status_label.text = "Connected to the shared board."


func _get_next_turn_id(player_id: int) -> int:
	var current_index := player_order.find(player_id)
	return player_order[(current_index + 1) % player_order.size()]


func _on_peer_disconnected(peer_id: int) -> void:
	if not multiplayer.is_server() or not player_order.has(peer_id):
		return

	player_order.erase(peer_id)
	if player_order.is_empty():
		player_order.append(multiplayer.get_unique_id())
	if current_turn_id == peer_id:
		current_turn_id = player_order[0]
	_apply_turn_state.rpc(player_order, current_turn_id)


@rpc("authority", "call_local", "reliable")
func _apply_turn_state(players: Array[int], turn_id: int) -> void:
	player_order = players.duplicate()
	current_turn_id = turn_id
	_update_turn_ui()


@rpc("authority", "call_local", "reliable")
func _apply_draw(drawn_card_ids: Array[int], drawer_id: int, next_turn_id: int) -> void:
	for card_id in drawn_card_ids:
		if not available_card_ids.has(card_id):
			continue
		available_card_ids.erase(card_id)
		collected_card_owners[card_id] = drawer_id
		if card_buttons.has(card_id):
			var card_button: Button = card_buttons[card_id]
			card_button.queue_free()
			card_buttons.erase(card_id)

	current_turn_id = next_turn_id
	_render_your_deck()
	_update_counts()
	_update_turn_ui()
	_update_start_game_button()
	if drawer_id == multiplayer.get_unique_id():
		status_label.text = "You drew %d card(s)." % drawn_card_ids.size()
	else:
		status_label.text = "Player %d drew %d card(s)." % [
			drawer_id,
			drawn_card_ids.size(),
		]
	if available_card_ids.is_empty():
		status_label.text = "The board is empty. The host can start the game."


func _on_start_game_pressed() -> void:
	if multiplayer.multiplayer_peer != null and not multiplayer.is_server():
		status_label.text = "Only the host can start the game."
		return
	if not available_card_ids.is_empty():
		status_label.text = "The host can start once every card has been drawn."
		_update_start_game_button()
		return

	var players_data := _build_players_data()
	Global.game_players = players_data.duplicate(true)
	if multiplayer.multiplayer_peer == null:
		_open_table(players_data)
	else:
		_start_table.rpc(players_data)


func _build_players_data() -> Array[Dictionary]:
	var peer_ids: Array[int] = [multiplayer.get_unique_id()]
	if multiplayer.multiplayer_peer != null:
		peer_ids = [1]
		var remote_peer_ids := multiplayer.get_peers()
		remote_peer_ids.sort()
		for remote_peer_id in remote_peer_ids:
			peer_ids.append(int(remote_peer_id))

	var players_data: Array[Dictionary] = []
	for peer_id in peer_ids:
		var player_name := "Host" if peer_id == 1 else "Player %d" % peer_id
		var score := 0
		var profile: Dictionary = Global.players.get(peer_id, {})
		if profile.has("name"):
			player_name = str(profile["name"])
		if profile.has("score"):
			score = int(profile["score"])

		var cards: Array[Dictionary] = []
		for card_id_variant in collected_card_owners:
			var card_id := int(card_id_variant)
			if int(collected_card_owners[card_id_variant]) == peer_id:
				cards.append({
					"name": _get_card_name_by_id(card_id),
					"value": int(card_by_id[card_id].get("value")),
				})

		players_data.append({
			"peer_id": peer_id,
			"name": player_name,
			"score": score,
			"cards": cards,
		})
	return players_data


@rpc("authority", "call_local", "reliable")
func _start_table(players_data: Array[Dictionary]) -> void:
	Global.game_players = players_data.duplicate(true)
	_open_table(players_data)


func _open_table(players_data: Array[Dictionary]) -> void:
	Global.game_players = players_data.duplicate(true)
	var error := get_tree().change_scene_to_file("res://table.tscn")
	if error != OK:
		push_error("Could not open the table scene: %s" % error_string(error))


func _update_start_game_button() -> void:
	start_game_button.disabled = (
		not available_card_ids.is_empty()
		or (multiplayer.multiplayer_peer != null and not multiplayer.is_server())
	)


func _render_your_deck() -> void:
	for child in your_deck_flow.get_children():
		child.queue_free()

	for card_id in collected_card_owners:
		if int(collected_card_owners[card_id]) == multiplayer.get_unique_id():
			_add_card_to_your_deck(int(card_id))


func _add_card_to_your_deck(card_id: int) -> void:
	var collected_card := DevilStyle.make_card_button(
		str(card_name_by_id[card_id]),
		str(card_suit_by_id[card_id]),
		_get_inventory_card_name(card_id),
		DECK_CARD_SIZE
	)
	collected_card.focus_mode = Control.FOCUS_NONE
	collected_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	your_deck_flow.add_child(collected_card)


func _update_turn_ui() -> void:
	var my_turn := _is_my_turn()
	if my_turn:
		turn_label.text = "Your turn"
	elif current_turn_id == 1:
		turn_label.text = "Waiting for the host's turn"
	else:
		turn_label.text = "Waiting for Player %d's turn" % current_turn_id

	draw_three_button.disabled = not my_turn or _count_face_down_cards() < 3
	for card_id in card_buttons:
		var card_button: Button = card_buttons[card_id]
		card_button.disabled = not my_turn or _is_number_card(int(card_id))


func _is_my_turn() -> bool:
	return current_turn_id == multiplayer.get_unique_id()


func _count_face_down_cards() -> int:
	var count := 0
	for card_id in available_card_ids:
		if _is_number_card(card_id):
			count += 1
	return count


func _is_number_card(card_id: int) -> bool:
	return str(card_name_by_id[card_id]).is_valid_int()


func _get_board_card_name(card_id: int) -> String:
	if _is_number_card(card_id):
		return FACE_DOWN_LABEL
	return _get_card_name(card_by_id[card_id])


func _get_inventory_card_name(card_id: int) -> String:
	if _is_number_card(card_id):
		return str(card_by_id[card_id].get("value"))
	return _get_card_name(card_by_id[card_id])


func _update_counts() -> void:
	board_count_label.text = "Cards on board: %d" % available_card_ids.size()
	var your_card_count := 0
	for collector_id in collected_card_owners.values():
		if int(collector_id) == multiplayer.get_unique_id():
			your_card_count += 1
	your_deck_count_label.text = "Cards in your deck: %d" % your_card_count


func _fit_board_cards() -> void:
	var area := board_scroll.size
	if area.x <= 0.0 or area.y <= 0.0:
		return
	var aspect := BOARD_CARD_SIZE.y / BOARD_CARD_SIZE.x
	var best_width := 0.0
	var best_columns := 1
	for columns in range(1, DECK_SIZE + 1):
		var rows := ceili(float(DECK_SIZE) / float(columns))
		var width_fit := (area.x - BOARD_GAP * (columns - 1)) / float(columns)
		var height_fit := (area.y - BOARD_GAP * (rows - 1)) / float(rows) / aspect
		var card_width := minf(width_fit, height_fit)
		if card_width > best_width:
			best_width = card_width
			best_columns = columns
	best_width = clampf(best_width, 30.0, 150.0)
	board_card_size = Vector2(floorf(best_width), floorf(best_width * aspect))
	board_grid.columns = best_columns
	for card_id in card_buttons:
		var card_button := card_buttons[card_id] as Button
		if is_instance_valid(card_button):
			card_button.custom_minimum_size = board_card_size


func _get_card_name(card_data: Resource) -> String:
	var type := int(card_data.get("data"))
	match type:
		1:
			return "Jack"
		2:
			return "Queen"
		3:
			return "King"
		4:
			return "Joker"
		5:
			return "Minus"
		6:
			return "Multiplication"
		7:
			return "Division"

	var value := int(card_data.get("value"))
	if value > 0:
		return str(value)
	return "Unknown card"


func _get_card_name_by_id(card_id: int) -> String:
	var card_name := str(card_name_by_id[card_id])
	if card_name.is_valid_int():
		return card_name
	return card_name.capitalize()

func _style_board_ui() -> void:
	board_grid.add_theme_constant_override("h_separation", int(BOARD_GAP))
	board_grid.add_theme_constant_override("v_separation", int(BOARD_GAP))
	board_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	board_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	your_deck_flow.add_theme_constant_override("h_separation", 8)
	your_deck_flow.add_theme_constant_override("v_separation", 8)

	var deck_scroll := find_child("YourDeckScroll", true, false) as Control
	if deck_scroll != null:
		deck_scroll.custom_minimum_size.y = 312.0

	var draw_row := draw_three_button.get_parent() as Control
	if draw_row != null:
		draw_row.custom_minimum_size.y = 64.0

	turn_label.add_theme_font_size_override("font_size", 38)
	turn_label.add_theme_color_override("font_color", DevilStyle.COL_EMBER)

	var heading := find_child("YourDeckHeading", true, false) as Label
	if heading != null:
		heading.add_theme_font_size_override("font_size", 34)
		heading.add_theme_color_override("font_color", DevilStyle.COL_EMBER)

	DevilStyle.use_body_font(status_label, 22)
	DevilStyle.use_body_font(your_deck_count_label, 22)
	DevilStyle.use_body_font(board_count_label, 22)

	draw_three_button.custom_minimum_size = Vector2(300, 64)
	DevilStyle.style_primary(draw_three_button, 28)
	DevilStyle.style_primary(start_game_button, 30)
