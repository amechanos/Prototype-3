extends Control

const Rules = preload("res://scripts/rules.gd")
const RESULT_PAUSE := 7.0
const DEADLINE_GRACE := 5.0
const DEAL_OFFSCREEN := 300.0
const DEAL_PEEK := 120.0
const DEAL_SLIDE_IN := 0.5
const DEAL_HOLD := 0.6
const DEAL_SETTLE := 0.5
const DEAL_SPREAD := 0.9
const DEAL_STACK_SEPARATION := -96
const HAND_SEPARATION := 8
const SELECT_LIFT := 12.0
const CARD_SIZE := Vector2(112, 152)
const OPPONENT_CARD_SIZE := Vector2(84, 114)
const EDGE_MARGIN := 24.0
const PILL_COLOR_BG := Color(0.1, 0.1, 0.1, 0.85)
const PILL_COLOR_NEUTRAL := Color(0.35, 0.35, 0.4, 0.9)
const PILL_COLOR_RAISE := Color(0.25, 0.6, 0.35, 0.95)
const PILL_COLOR_LOWER := Color(0.7, 0.28, 0.28, 0.95)
const LOW_TIME := 15.0
const COLOR_LOW_TIME := Color(0.9, 0.2, 0.2)
const DRAW_SCENE := "res://board.tscn"
const RING_CALM := Color(0.6, 0.08, 0.1, 0.8)
const RING_HOT := Color(1.0, 0.22, 0.08, 1.0)
const PULSE_SLOW := 1.1 # pulse speed when calm (radians per second)
const PULSE_FAST := 3.0 # pulse speed at full heat
const HEAT_OVERLAY_MAX := 0.55 # strongest the red screen-edge glow gets

const SFX_SHUFFLE := preload("res://SFX/Insane shuffle.wav")
const SFX_DEAL := preload("res://SFX/Card place down.wav")
const SFX_PICK := preload("res://SFX/Card Pick.mp3")
const SFX_LOW_TIME := preload("res://SFX/Card Pick.mp3") # placeholder

@onready var equation_label: Label = $PlayerInterface/EQDisplay
@onready var submit_button: Button = $PlayerInterface/Submit
@onready var pickup_button: Button = $PlayerInterface/Pickup

@onready var playerHeading: Label = $playerCards/HandLayout/HandHeading
@onready var opponentHeading: Label = $opponentCards/HandLayout/HandHeading

@onready var timer_label: Label = $UI/Timer
@onready var round_counter: Label = $UI/Round
@onready var target_num_label: Label = $UI/TargetNumber
@onready var information: Label = $UI/Info

@onready var player_cards_container: HBoxContainer = $playerCards/HandLayout/ScrollContainer/HBoxContainer
@onready var opponent_cards_container: HBoxContainer = $opponentCards/HandLayout/ScrollContainer/HBoxContainer
@onready var player_heading: Label = $playerCards/HandLayout/HandHeading
@onready var opponent_heading: Label = $opponentCards/HandLayout/HandHeading

var my_id := 1
var names: Dictionary = {}
var player_ids: Array[int] = []

# Host-only state.
var low_time := false
var hands: Dictionary = {}
var discarded_cards: Array = []
var ready_peers: Array[int] = []
var submissions: Dictionary = {}
var redrawn_peers: Dictionary = {}
var round_active := false
var round_number := 0
var base_target := 21
var game_finished := false
var next_uid := 0
var round_wins: Dictionary = {}

# Local state.
var my_hand: Array = []
var opponent_count := 0
var opponent_played_cards: Array = []
var target_number := 21
var player_card_buttons: Array[Button] = []
var selected_cards: Array[Button] = []
var card_params: Dictionary = {}
var has_submitted := false
var has_redrawn := false
var redraw_pending := false
var round_received := false
var discard_pile_count := 0
var time_left := -1.0
var my_wins := 0
var opponent_wins := 0
var restart_button: Button

# Table look state.
var heat := 0.0
var _clock := 0.0
var _ring_spin := 0.0
var _pulse_phase := 0.0
var _pulse := 0.0
var _flash := 0.0
var _flash_color := Color.WHITE
var _dealing := false
var _ring: Control
var _sparks: CPUParticles2D
var _heat_overlay: TextureRect


func _ready() -> void:
	_build_table_look()
	_tidy_ui()
	_prepare_hand_rows()
	_style_table_text()
	_add_heat_overlay()
	get_viewport().size_changed.connect(_on_viewport_resized)
	playerHeading.hide()
	opponentHeading.hide()
	_update_pickup_button()
	information.text = " "
	my_id = multiplayer.get_unique_id()
	for player_data in Global.game_players:
		var peer_id := int(player_data.get("peer_id", -1))
		player_ids.append(peer_id)
		names[peer_id] = str(player_data.get("name", "Player %d" % peer_id))
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	_fit_layout()
	if multiplayer.is_server():
		_host_mark_ready()
	else:
		_send(1, &"_host_mark_ready", [])


func _process(delta: float) -> void:
	_animate_table(delta)
	if time_left < 0.0:
		return
	time_left = maxf(0.0, time_left - delta)
	timer_label.text = "Time left: %.1f" % time_left
	_update_timer_warning()
	if time_left == 0.0:
		time_left = -1.0
		if not has_submitted:
			_submit_current_hand(true)


func _update_timer_warning() -> void:
	if time_left > LOW_TIME:
		return
	timer_label.add_theme_color_override("font_color", COLOR_LOW_TIME)
	if not low_time:
		low_time = true
		_play_sfx(SFX_LOW_TIME)


func _reset_timer_warning() -> void:
	low_time = false
	timer_label.remove_theme_color_override("font_color")


func _sender() -> int:
	var sender := multiplayer.get_remote_sender_id()
	return sender if sender != 0 else multiplayer.get_unique_id()


func _send(peer_id: int, method: StringName, args: Array) -> void:
	if peer_id == multiplayer.get_unique_id():
		callv(method, args)
	else:
		callv("rpc_id", [peer_id, method] + args)


func _broadcast(method: StringName, args: Array) -> void:
	for peer_id in player_ids:
		_send(peer_id, method, args)

# ---------------------------------------------------------------- host logic

@rpc("any_peer", "call_remote", "reliable")
func _host_mark_ready() -> void:
	if not multiplayer.is_server():
		return
	var sender := _sender()
	if not player_ids.has(sender) or ready_peers.has(sender):
		return
	ready_peers.append(sender)
	if ready_peers.size() == player_ids.size():
		_host_begin()


func _host_begin() -> void:
	var copy_counts := {}
	for player_data in Global.game_players:
		var hand: Array = []
		for card_variant in player_data.get("cards", []):
			var card: Dictionary = card_variant
			var card_name := str(card.get("name", "")).to_lower()
			var suit := str(card.get("suit", ""))
			if suit == "":
				var copy_index := int(copy_counts.get(card_name, 0))
				copy_counts[card_name] = copy_index + 1
				suit = DevilStyle.SUITS[copy_index % DevilStyle.SUITS.size()]
			hand.append({
				"uid": next_uid,
				"name": card_name,
				"value": int(card.get("value", 1)),
				"suit": suit,
			})
			next_uid += 1
		hands[int(player_data.get("peer_id", -1))] = hand
	_host_start_round()


func _host_start_round() -> void:
	if game_finished:
		return
	round_number += 1
	base_target = Rules.roll_target()
	submissions.clear()
	redrawn_peers.clear()
	round_active = true
	var counts := {}
	for peer_id in player_ids:
		counts[peer_id] = (hands[peer_id] as Array).size()
	for peer_id in player_ids:
		_send(peer_id, &"_receive_round", [
			hands[peer_id],
			counts,
			base_target,
			round_number,
			discarded_cards.size(),
		])
	_host_deadline(round_number, Rules.ROUND_LIMIT_SECONDS)


@rpc("any_peer", "call_remote", "reliable")
func _host_receive_submit(picks: Array) -> void:
	if not multiplayer.is_server() or not round_active:
		return
	var sender := _sender()
	if not player_ids.has(sender) or submissions.has(sender):
		return

	_host_record_submission(sender, picks)


func _host_record_submission(peer_id: int, picks: Array) -> void:
	if not multiplayer.is_server() or not round_active or submissions.has(peer_id):
		return

	var played := _build_played_cards(peer_id, picks)
	submissions[peer_id] = played
	_broadcast(&"_show_submission", [peer_id, played])
	if submissions.size() == player_ids.size():
		_host_resolve()
	elif submissions.size() == 1:
		_broadcast(&"_start_countdown", [LOW_TIME])
		_host_deadline(round_number, LOW_TIME)


func _build_played_cards(peer_id: int, picks: Array) -> Array:
	var played: Array = []
	var used_uids: Array[int] = []
	for pick_variant in picks:
		var pick: Dictionary = pick_variant
		var uid := int(pick.get("uid", -1))
		if used_uids.has(uid):
			continue
		for card_variant in hands[peer_id]:
			var card: Dictionary = card_variant
			if int(card["uid"]) != uid:
				continue
			var played_card := card.duplicate()
			var param := int(pick.get("param", 0))
			if card["name"] == "king":
				played_card["param"] = clampi(param, Rules.KING_MIN, Rules.KING_MAX)
			elif card["name"] == "jack":
				played_card["param"] = Rules.JACK_DELTA if param >= 0 else -Rules.JACK_DELTA
			played.append(played_card)
			used_uids.append(uid)
			break
	if not bool(Rules.evaluate(played)["valid"]):
		return []
	return played


func _host_deadline(for_round: int, seconds: float) -> void:
	await get_tree().create_timer(seconds + DEADLINE_GRACE).timeout
	if not round_active or round_number != for_round:
		return
	for peer_id in player_ids:
		if not submissions.has(peer_id):
			submissions[peer_id] = []
			_broadcast(&"_show_submission", [peer_id, []])
	_host_resolve()


func _host_resolve() -> void:
	round_active = false
	var peer_a: int = player_ids[0]
	var peer_b: int = player_ids[1] if player_ids.size() > 1 else -1
	var cards_a: Array = submissions.get(peer_a, [])
	var cards_b: Array = submissions.get(peer_b, [])
	var result := Rules.resolve(base_target, cards_a, cards_b)
	result["peers"] = [peer_a, peer_b]
	result["cards"] = [cards_a, cards_b]
	var round_winner := int(result["winner"])
	if round_winner != -1:
		var winner_peer := int(result["peers"][round_winner])
		if winner_peer != -1:
			round_wins[winner_peer] = int(round_wins.get(winner_peer, 0)) + 1
	result["wins"] = round_wins.duplicate()

	var finished_peer := -1
	for index in range(player_ids.size()):
		var peer_id: int = player_ids[index]
		var discard_uids: Array = result["discard"][index]
		for card_variant in hands[peer_id]:
			var card: Dictionary = card_variant
			if discard_uids.has(int(card["uid"])):
				discarded_cards.append(card.duplicate(true))
		hands[peer_id] = (hands[peer_id] as Array).filter(
			func(card: Dictionary) -> bool: return not discard_uids.has(int(card["uid"]))
		)
		if (hands[peer_id] as Array).is_empty() and finished_peer == -1:
			finished_peer = peer_id

	_broadcast(&"_show_result", [result])
	await get_tree().create_timer(RESULT_PAUSE).timeout
	if game_finished:
		return
	if finished_peer != -1:
		game_finished = true
		_broadcast(&"_game_over", [finished_peer, ""])
	else:
		_host_start_round()


func _on_peer_disconnected(peer_id: int) -> void:
	if not multiplayer.is_server() or game_finished or not player_ids.has(peer_id):
		return
	player_ids.erase(peer_id)
	game_finished = true
	round_active = false
	_broadcast(&"_game_over", [my_id, "Your opponent disconnected."])


func _on_server_disconnected() -> void:
	game_finished = true
	time_left = -1.0
	print("Host disconnected.")
	_lock_hand()

# ------------------------------------------------------------ client: rounds

@rpc("authority", "call_remote", "reliable")
func _receive_round(
	hand: Array,
	counts: Dictionary,
	target: int,
	round_no: int,
	current_discard_count: int
) -> void:
	my_hand = hand.duplicate(true)
	target_number = target
	target_num_label.text = str(target)
	discard_pile_count = current_discard_count
	has_submitted = false
	has_redrawn = false
	redraw_pending = false
	round_received = true
	_update_pickup_button()
	submit_button.disabled = game_finished
	time_left = Rules.ROUND_LIMIT_SECONDS
	timer_label.text = ""
	_reset_timer_warning()
	opponent_heading.text = ""
	opponent_played_cards = []
	opponent_count = 0
	for peer_id in counts:
		if int(peer_id) != my_id:
			opponent_count += int(counts[peer_id])
	selected_cards.clear()
	_render_hand()
	_render_opponent()
	_refresh_selection()
	round_counter.text = "Round %d  |  Wins: You %d - %d Opponent" % [round_no, my_wins, opponent_wins]
	_fit_layout()
	if round_no == 1:
		_play_deal_animation()


@rpc("any_peer", "call_remote", "reliable")
func _host_redraw_numbers() -> void:
	if not multiplayer.is_server() or not round_active or game_finished:
		return
	var sender := _sender()
	if not player_ids.has(sender) or not hands.has(sender):
		return
	if submissions.has(sender) or redrawn_peers.has(sender) or discarded_cards.size() < 12:
		_send(sender, &"_pickup_rejected", [])
		return

	var available_numbers: Array = []
	for card_variant in discarded_cards:
		var card: Dictionary = card_variant
		if str(card.get("name", "")).is_valid_int():
			available_numbers.append(card)
	if available_numbers.is_empty():
		_send(sender, &"_redraw_unavailable", [])
		return

	redrawn_peers[sender] = true
	var drawn_cards: Array = []
	var draw_count := mini(3, available_numbers.size())
	for _index in range(draw_count):
		var card_index := randi_range(0, available_numbers.size() - 1)
		var card: Dictionary = available_numbers.pop_at(card_index)
		discarded_cards.erase(card)
		(hands[sender] as Array).append(card)
		drawn_cards.append(card)
	_broadcast(&"_receive_redraw", [sender, drawn_cards])
	_host_record_submission(sender, [])


@rpc("authority", "call_remote", "reliable")
func _receive_redraw(peer_id: int, cards: Array) -> void:
	if peer_id == my_id:
		for card_variant in cards:
			my_hand.append((card_variant as Dictionary).duplicate(true))
		has_redrawn = true
		redraw_pending = false
		has_submitted = true
		time_left = -1.0
		timer_label.text = ""
		round_counter.text = "Pickup submitted for this round."
		selected_cards.clear()
		_lock_hand()
		discard_pile_count = maxi(0, discard_pile_count - cards.size())
		information.text = "You picked up %d number card(s) and submitted nothing." % cards.size()
		_render_hand()
		_refresh_selection()
	else:
		opponent_count += cards.size()
		discard_pile_count = maxi(0, discard_pile_count - cards.size())
		information.text = "%s redrew %d number card(s)." % [
			names.get(peer_id, "Your opponent"),
			cards.size()
		]
		_render_opponent()
	_update_pickup_button()


@rpc("authority", "call_remote", "reliable")
func _redraw_unavailable() -> void:
	redraw_pending = false
	information.text = "There are no number cards in the discard pile to redraw."
	_update_pickup_button()


@rpc("authority", "call_remote", "reliable")
func _pickup_rejected() -> void:
	redraw_pending = false
	information.text = "Pickup is no longer available this round."
	_update_pickup_button()


func _on_pickup_pressed() -> void:
	if has_submitted or has_redrawn or redraw_pending or game_finished:
		return
	if not round_received or discard_pile_count < 12:
		return
	redraw_pending = true
	_update_pickup_button()
	_send(1, &"_host_redraw_numbers", [])


func _update_pickup_button() -> void:
	var available := round_received and discard_pile_count >= 12 and not game_finished
	pickup_button.visible = available and not has_submitted
	pickup_button.disabled = has_redrawn or redraw_pending


@rpc("authority", "call_remote", "reliable")
func _start_countdown(seconds: float) -> void:
	if has_submitted:
		return
	time_left = seconds if time_left < 0.0 else minf(seconds, time_left)
	information.text = "Your opponent has submitted!"
	_flash_ring(COLOR_LOW_TIME, 0.5)


@rpc("authority", "call_remote", "reliable")
func _show_result(result: Dictionary) -> void:
	time_left = -1.0
	round_received = false
	_update_pickup_button()
	timer_label.text = ""
	var peers: Array = result["peers"]
	var mine := peers.find(my_id)
	if mine == -1:
		mine = 0
	var other := 1 - mine
	var score: Array = result["score"]
	var bust: Array = result["bust"]
	target_num_label.text = str(int(result["target"]))

	var winner := int(result["winner"])
	var discard_mine: Array = result["discard"][mine]
	var discard_other: Array = result["discard"][other]
	var wins: Dictionary = result.get("wins", {})
	my_wins = int(wins.get(my_id, 0))
	opponent_wins = int(wins.get(int(peers[other]), 0))
	var other_name := str(names.get(int(peers[other]), "Opponent"))

	var lines: Array[String] = []
	if int(result["target"]) != target_number:
		lines.append("Jacks moved the target to %d." % int(result["target"]))
	if bool(result["swapped"]):
		lines.append("A Joker swapped the hands!")
	if bool(result.get("queen_active", false)):
		lines.append("Queen played: the last two numbers were voided for both players!")

	var score_line := "You: %s%s" % [
		Rules.format_number(float(score[mine])),
		" (bust)" if bool(bust[mine]) else "",
	]
	if int(peers[other]) != -1:
		score_line += "   |   %s: %s%s" % [
			other_name,
			Rules.format_number(float(score[other])),
			" (bust)" if bool(bust[other]) else "",
		]
	lines.append(score_line)

	var outcome := ""
	if winner == -1:
		outcome = "Draw - nobody discards."
	elif winner == mine:
		outcome = "You win the round!"
		_flash_ring(Color(1.0, 0.85, 0.45), 0.8)
	else:
		outcome = "You lose the round and keep your cards."
		_flash_ring(Color(0.35, 0.0, 0.04), 0.8)
	if discard_mine.size() > 0:
		outcome += "  You discard %d card(s)." % discard_mine.size()
	lines.append(outcome)
	information.text = "\n".join(lines)

	my_hand = my_hand.filter(
		func(card: Dictionary) -> bool: return not discard_mine.has(int(card["uid"]))
	)
	opponent_count = maxi(0, opponent_count - discard_other.size())
	has_submitted = true
	_update_pickup_button()
	selected_cards.clear()
	_render_hand()
	_render_opponent()
	_refresh_selection()


@rpc("authority", "call_remote", "reliable")
func _game_over(winner_peer: int, note: String) -> void:
	game_finished = true
	time_left = -1.0
	timer_label.text = ""
	has_submitted = true
	selected_cards.clear()
	_render_hand()
	_refresh_selection()
	if winner_peer == my_id:
		round_counter.text = "You won!"
		_flash_ring(Color(1.0, 0.85, 0.45), 0.8)
	else:
		round_counter.text = "You lost."
		_flash_ring(Color(0.35, 0.0, 0.04), 0.8)
	if note != "":
		information.text = note
	submit_button.disabled = true
	_update_pickup_button()
	_show_restart_button()

# ----------------------------------------------------------------- client: UI

func _make_hand_card(card: Dictionary) -> Button:
	var button := DevilStyle.make_card_button(
		str(card["name"]),
		str(card.get("suit", "")),
		_card_title(card),
		CARD_SIZE
	)
	button.toggle_mode = true
	if button.icon != null:
		button.add_theme_stylebox_override("hover_pressed", DevilStyle.box(Color(0, 0, 0, 0), DevilStyle.COL_EMBER, 3, 6, 2))
	else:
		button.add_theme_stylebox_override("hover_pressed", DevilStyle.box(Color(0.08, 0.0, 0.0), DevilStyle.COL_EMBER))
	return button


func _render_hand() -> void:
	for child in player_cards_container.get_children():
		child.queue_free()
	player_card_buttons.clear()
	for card_variant in my_hand:
		var card: Dictionary = card_variant
		var slot := Control.new()
		slot.custom_minimum_size = CARD_SIZE + Vector2(0, SELECT_LIFT)
		var card_button := _make_hand_card(card)
		card_button.set_meta("card", card)
		card_button.size = CARD_SIZE
		card_button.position = Vector2(0, SELECT_LIFT)
		card_button.disabled = has_submitted or game_finished
		card_button.toggled.connect(_on_card_toggled.bind(card_button))
		card_button.add_child(_make_order_badge(card))
		var param_control := _make_param_control(card)
		if param_control != null:
			card_button.add_child(param_control)
			card_button.set_meta("param_control", param_control)
		slot.add_child(card_button)
		slot.set_meta("button", card_button)
		player_cards_container.add_child(slot)
		player_card_buttons.append(card_button)
	_fit_hands()


func _make_order_badge(card: Dictionary) -> Label:
	var badge := Label.new()
	badge.name = "OrderBadge"
	badge.custom_minimum_size = Vector2(24, 24)
	var card_name := str(card["name"])
	var at_top := card_name == "king" or card_name == "jack"
	badge.position = Vector2(6.0, 6.0) if at_top else Vector2(6.0, CARD_SIZE.y - 30.0)
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = PILL_COLOR_BG
	style.set_corner_radius_all(12)
	badge.add_theme_stylebox_override("normal", style)
	return badge


func _make_param_control(card: Dictionary) -> Control:
	var card_name := str(card["name"])
	var uid: int = card["uid"]
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	if card_name == "king":
		var value_label := Label.new()
		value_label.text = str(int(card_params.get(uid, _default_param(card_name))))
		value_label.custom_minimum_size = Vector2(28, 0)
		value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		value_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var minus := _make_pill_button("-", PILL_COLOR_NEUTRAL)
		var plus := _make_pill_button("+", PILL_COLOR_NEUTRAL)
		minus.pressed.connect(_step_king.bind(uid, -1, value_label))
		plus.pressed.connect(_step_king.bind(uid, 1, value_label))
		row.add_child(minus)
		row.add_child(value_label)
		row.add_child(plus)
	elif card_name == "jack":
		var group := ButtonGroup.new()
		var current := int(card_params.get(uid, _default_param(card_name)))
		var raise := _make_pill_button("+3", PILL_COLOR_RAISE, group)
		var lower := _make_pill_button("-3", PILL_COLOR_LOWER, group)
		raise.tooltip_text = "Raise the target by 3"
		lower.tooltip_text = "Lower the target by 3"
		raise.button_pressed = current >= 0
		lower.button_pressed = current < 0
		raise.toggled.connect(_on_jack_picked.bind(uid, Rules.JACK_DELTA))
		lower.toggled.connect(_on_jack_picked.bind(uid, -Rules.JACK_DELTA))
		raise.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lower.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(raise)
		row.add_child(lower)
	else:
		return null

	var pill := PanelContainer.new()
	pill.add_theme_stylebox_override("panel", _pill_style(PILL_COLOR_BG, 4))
	pill.add_child(row)
	pill.position = Vector2(4, CARD_SIZE.y - 36)
	pill.size = Vector2(CARD_SIZE.x - 8, 30)
	pill.visible = false
	_set_param_control_locked(pill, has_submitted or game_finished)
	return pill


func _pill_style(color: Color, margin := 0) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(12)
	style.set_content_margin_all(margin)
	return style


func _make_pill_button(text: String, active_color: Color, group: ButtonGroup = null) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(26, 22)
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 14)
	button.add_theme_stylebox_override("normal", _pill_style(Color.TRANSPARENT))
	button.add_theme_stylebox_override("hover", _pill_style(active_color.lerp(PILL_COLOR_BG, 0.55)))
	button.add_theme_stylebox_override("pressed", _pill_style(active_color))
	button.add_theme_stylebox_override("hover_pressed", _pill_style(active_color))
	if group != null:
		button.toggle_mode = true
		button.button_group = group
	return button


func _set_param_control_locked(control: Control, locked: bool) -> void:
	for node in control.find_children("*", "Button", true, false):
		(node as Button).mouse_filter = Control.MOUSE_FILTER_IGNORE if locked else Control.MOUSE_FILTER_STOP


func _step_king(uid: int, delta: int, value_label: Label) -> void:
	var value := clampi(int(card_params.get(uid, _default_param("king"))) + delta, Rules.KING_MIN, Rules.KING_MAX)
	card_params[uid] = value
	value_label.text = str(value)
	_refresh_selection()


func _on_jack_picked(pressed: bool, uid: int, delta: int) -> void:
	if not pressed:
		return
	card_params[uid] = delta
	_refresh_selection()


func _render_opponent() -> void:
	for child in opponent_cards_container.get_children():
		child.queue_free()
	var opponent_names: Array[String] = []
	for peer_id in player_ids:
		if peer_id != my_id:
			opponent_names.append(str(names.get(peer_id, "Opponent")))
	if opponent_names.is_empty():
		opponent_heading.text = "No opponent (practice round)"
		return
	opponent_heading.text = "%s (%d cards, face down)" % [", ".join(opponent_names), opponent_count]
	for _index in range(opponent_count):
		var card_back := DevilStyle.make_card_back(OPPONENT_CARD_SIZE)
		card_back.disabled = true
		opponent_cards_container.add_child(card_back)
	_fit_hands()


func _card_title(card: Dictionary) -> String:
	var card_name := str(card["name"])
	if Rules.is_operator(card_name):
		return "%s\n(%s)" % [card_name.capitalize(), Rules.OPERATOR_SYMBOLS[card_name]]
	if card_name.is_valid_int():
		return card_name
	return card_name.capitalize()


func _on_card_toggled(pressed: bool, card_button: Button) -> void:
	if pressed:
		if not selected_cards.has(card_button):
			selected_cards.append(card_button)
		_play_sfx(SFX_PICK)
	else:
		selected_cards.erase(card_button)
	_set_card_lifted(card_button, pressed)
	_refresh_selection()


func _play_sfx(stream: AudioStream, volume_db := 0.0) -> void:
	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.volume_db = volume_db
	add_child(player)
	player.finished.connect(player.queue_free)
	player.play()


func _set_card_lifted(card_button: Button, lifted: bool) -> void:
	if card_button.has_meta("lift_tween"):
		var previous: Tween = card_button.get_meta("lift_tween")
		if previous != null and previous.is_valid():
			previous.kill()
	var tween := card_button.create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(card_button, "position:y", 0.0 if lifted else SELECT_LIFT, 0.18)
	card_button.set_meta("lift_tween", tween)


func _play_deal_animation() -> void:
	_dealing = true
	var piles: Array[Control] = [$playerCards, $opponentCards]
	var rows: Array[BoxContainer] = [player_cards_container, opponent_cards_container]
	var off_screen_y: Array[float] = [DEAL_OFFSCREEN, -DEAL_OFFSCREEN]
	var peek_y: Array[float] = [-DEAL_PEEK, DEAL_PEEK]
	var end_separation: Array[int] = [
		_hand_separation(player_card_buttons.size(), CARD_SIZE.x, player_cards_container),
		_hand_separation(opponent_count, OPPONENT_CARD_SIZE.x, opponent_cards_container),
	]
	var deck_x := get_viewport_rect().size.x * 0.5 - 100.0

	var locked: Array[Button] = []
	for row in rows:
		for child in row.get_children():
			var button: Button = child.get_meta("button") if child.has_meta("button") else child as Button
			if button != null and not button.disabled:
				button.disabled = true
				locked.append(button)

	_play_sfx(SFX_SHUFFLE)
	var finish: Tween
	for index in range(piles.size()):
		var pile := piles[index]
		var row := rows[index]
		var rest := pile.position
		row.add_theme_constant_override("separation", DEAL_STACK_SEPARATION)
		pile.position = rest + Vector2(deck_x, off_screen_y[index])
		var tween := pile.create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tween.tween_property(pile, "position", rest + Vector2(deck_x, peek_y[index]), DEAL_SLIDE_IN)
		tween.tween_interval(DEAL_HOLD)
		tween.tween_callback(_play_sfx.bind(SFX_DEAL, -6.0))
		tween.tween_property(pile, "position", rest, DEAL_SETTLE)
		tween.parallel().tween_method(
			func(value: float) -> void: row.add_theme_constant_override("separation", roundi(value)),
			float(DEAL_STACK_SEPARATION), float(end_separation[index]), DEAL_SPREAD
		).set_ease(Tween.EASE_IN_OUT)
		finish = tween

	playerHeading.show()
	opponentHeading.show()

	await finish.finished
	for card in locked:
		if is_instance_valid(card):
			card.disabled = has_submitted or game_finished
	_dealing = false
	_fit_hands()
	_fit_layout()


func _default_param(card_name: String) -> int:
	return Rules.JACK_DELTA if card_name == "jack" else 5


func _played_cards() -> Array:
	var cards: Array = []
	for card_button in selected_cards:
		var card: Dictionary = (card_button.get_meta("card") as Dictionary).duplicate()
		var card_name := str(card["name"])
		if card_name == "king" or card_name == "jack":
			card["param"] = int(card_params.get(card["uid"], _default_param(card_name)))
		cards.append(card)
	return cards


func _refresh_selection() -> void:
	for card_button in player_card_buttons:
		var selected_index := selected_cards.find(card_button)
		var badge := card_button.get_node("OrderBadge") as Label
		badge.visible = selected_index != -1
		badge.text = str(selected_index + 1)
		if card_button.has_meta("param_control"):
			var param_control: Control = card_button.get_meta("param_control")
			var show_control := selected_index != -1
			if show_control and not param_control.visible:
				param_control.modulate.a = 0.0
				param_control.create_tween().tween_property(param_control, "modulate:a", 1.0, 0.15)
			param_control.visible = show_control
			card_button.z_index = 2 if show_control else 0

	equation_label.text = _equation_text()
	player_heading.text = "Your hand. (%d selected)" % selected_cards.size()


func _equation_text() -> String:
	if selected_cards.is_empty():
		return "Pick cards to build your equation"
	var parts: Array[String] = []
	var previous_was_operand := false
	for card in _played_cards():
		var is_operand := not Rules.is_operator(str(card["name"]))
		if is_operand and previous_was_operand:
			parts.append("+")
		parts.append(Rules.card_label(card))
		previous_was_operand = is_operand
	var text := " ".join(parts)
	if not Global.hard_mode:
		var preview_cards := _played_cards()
		if Rules.has_queen(preview_cards):
			preview_cards = Rules.void_for_queen(preview_cards)
		var evaluation := Rules.evaluate(preview_cards)
		if bool(evaluation["valid"]):
			text += " = %s" % Rules.format_number(float(evaluation["value"]))
	return text


func _on_submit_pressed() -> void:
	_submit_current_hand(false)


func _submit_current_hand(auto_submit: bool) -> void:
	if has_submitted or game_finished:
		return
	var cards := _played_cards()
	if auto_submit:
		while not cards.is_empty() and Rules.is_operator(str(cards.back()["name"])):
			cards.pop_back()

	var picks: Array = []
	for card in cards:
		picks.append({"uid": card["uid"], "param": card.get("param", 0)})
	has_submitted = true
	time_left = -1.0
	timer_label.text = ""
	_lock_hand()
	round_counter.text = "You submitted. Waiting for opponent."
	_send(1, &"_host_receive_submit", [picks])


func _lock_hand() -> void:
	for card_button in player_card_buttons:
		card_button.disabled = true
		if card_button.has_meta("param_control"):
			_set_param_control_locked(card_button.get_meta("param_control"), true)
	submit_button.disabled = true
	_update_pickup_button()


func _show_restart_button() -> void:
	if restart_button == null:
		restart_button = Button.new()
		restart_button.text = "Play again"
		restart_button.pressed.connect(_on_restart_pressed)
		add_child(restart_button)
		DevilStyle.style_primary(restart_button, 38)
		restart_button.size = Vector2(280, 68)
		var view_size := get_viewport_rect().size
		restart_button.position = Vector2((view_size.x - restart_button.size.x) / 2.0, view_size.y * 0.66)
	restart_button.disabled = false
	restart_button.show()


func _on_restart_pressed() -> void:
	restart_button.disabled = true
	_send(1, &"_host_restart", [])


@rpc("any_peer", "call_remote", "reliable")
func _host_restart() -> void:
	if not multiplayer.is_server() or not game_finished:
		return
	_broadcast(&"_return_to_board", [])


@rpc("authority", "call_remote", "reliable")
func _return_to_board() -> void:
	var error := get_tree().change_scene_to_file(DRAW_SCENE)
	if error != OK:
		push_error("Could not open the draw scene: %s" % error_string(error))

# ------------------------------------------------------- hand layout (fit)

func _prepare_hand_rows() -> void:
	var rows: Array[BoxContainer] = [player_cards_container, opponent_cards_container]
	for row in rows:
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		var scroll := row.get_parent() as ScrollContainer
		scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	(player_cards_container.get_parent() as Control).custom_minimum_size.y = CARD_SIZE.y + SELECT_LIFT + 4.0
	(opponent_cards_container.get_parent() as Control).custom_minimum_size.y = OPPONENT_CARD_SIZE.y + 4.0


# When a hand is too wide for the screen, cards overlap like a fanned hand
# instead of running off the edge.
func _hand_separation(count: int, card_width: float, container: Control) -> int:
	if count <= 1:
		return HAND_SEPARATION
	var scroll := container.get_parent() as Control
	var available := scroll.size.x - 12.0
	if available <= 0.0:
		return HAND_SEPARATION
	var natural := float(count) * card_width + float(count - 1) * HAND_SEPARATION
	if natural <= available:
		return HAND_SEPARATION
	var fitted := int(floorf((available - float(count) * card_width) / float(count - 1)))
	return maxi(fitted, -int(card_width) + 24)


func _fit_hands() -> void:
	if _dealing:
		return
	player_cards_container.add_theme_constant_override(
		"separation",
		_hand_separation(player_card_buttons.size(), CARD_SIZE.x, player_cards_container)
	)
	opponent_cards_container.add_theme_constant_override(
		"separation",
		_hand_separation(opponent_count, OPPONENT_CARD_SIZE.x, opponent_cards_container)
	)


# Slides each hand back on screen if it sits past the top or bottom edge.
func _fit_layout() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if _dealing or not is_inside_tree():
		return
	_nudge_into_view($opponentCards, opponent_cards_container, OPPONENT_CARD_SIZE.y)
	_nudge_into_view($playerCards, player_cards_container, CARD_SIZE.y + SELECT_LIFT)


func _nudge_into_view(pile: Control, container: Control, content_height: float) -> void:
	var top := container.get_global_rect().position.y
	var bottom := top + content_height
	var view_height := get_viewport_rect().size.y
	var shift := 0.0
	if top < EDGE_MARGIN:
		shift = EDGE_MARGIN - top
	elif bottom > view_height - EDGE_MARGIN:
		shift = (view_height - EDGE_MARGIN) - bottom
	if absf(shift) < 1.0:
		return
	var tween := pile.create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(pile, "position:y", pile.position.y + shift, 0.25)


func _on_viewport_resized() -> void:
	_fit_hands()
	_fit_layout()

# ------------------------------------------------------------ table look

func _flash_ring(color: Color, strength := 1.0) -> void:
	_flash_color = color
	_flash = strength


func _animate_table(delta: float) -> void:
	var target_heat := 0.0
	if time_left >= 0.0 and time_left <= LOW_TIME:
		target_heat = 0.3 + 0.7 * (1.0 - time_left / LOW_TIME)
	heat = move_toward(heat, target_heat, delta * 1.0)
	_clock += delta
	_ring_spin += delta * (0.15 + heat * 0.7)
	_flash = move_toward(_flash, 0.0, delta * 0.4)
	_pulse_phase += delta * lerpf(PULSE_SLOW, PULSE_FAST, heat)
	_pulse = 0.5 + 0.5 * sin(_pulse_phase)

	var center := target_num_label.get_global_rect().get_center()
	_ring.global_position = center - _ring.size / 2.0
	_ring.queue_redraw()
	_sparks.global_position = center
	_sparks.speed_scale = 1.0 + heat
	_sparks.modulate = Color.WHITE.lerp(Color(1.0, 0.3, 0.2), heat)
	_heat_overlay.modulate.a = heat * (HEAT_OVERLAY_MAX - 0.2 + 0.2 * _pulse)

	timer_label.pivot_offset = timer_label.size / 2.0
	timer_label.scale = Vector2.ONE * (1.0 + 0.05 * heat * _pulse)
	timer_label.rotation = sin(_clock * 14.0) * 0.01 * heat


func _draw_ring(canvas: Control) -> void:
	var center := canvas.size / 2.0
	var radius := minf(canvas.size.x, canvas.size.y) / 2.0 - 8.0
	var tint := RING_CALM.lerp(RING_HOT, heat).lerp(_flash_color, _flash * 0.7)
	var glow := Color(tint.r, tint.g, tint.b, (0.10 + 0.12 * _pulse) * (1.0 + 0.6 * heat))
	var faint := Color(tint.r, tint.g, tint.b, 0.55)

	canvas.draw_arc(center, radius, 0.0, TAU, 128, glow, 16.0, true)
	canvas.draw_arc(center, radius, 0.0, TAU, 128, tint, 3.0, true)
	canvas.draw_arc(center, radius * 0.9, 0.0, TAU, 128, faint, 1.5, true)
	canvas.draw_arc(center, radius * 0.36, 0.0, TAU, 96, faint, 1.5, true)

	var ticks := 72
	for i in range(ticks):
		var angle := _ring_spin * 0.6 + TAU * float(i) / float(ticks)
		var direction := Vector2.RIGHT.rotated(angle)
		var major := i % 6 == 0
		var from_radius := radius * (0.92 if major else 0.95)
		canvas.draw_line(
			center + direction * from_radius,
			center + direction * radius * 0.99,
			faint,
			2.0 if major else 1.0,
			true
		)

	var star := PackedVector2Array()
	var order: Array[int] = [0, 2, 4, 1, 3, 0]
	for k in order:
		var star_angle := -_ring_spin - PI / 2.0 + TAU * float(k) / 5.0
		star.append(center + Vector2.RIGHT.rotated(star_angle) * radius * 0.8)
	canvas.draw_polyline(star, Color(tint.r, tint.g, tint.b, 0.35 + 0.3 * heat), 2.0, true)


func _add_back(node: Control, index: int, margin := 0) -> int:
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(node)
	node.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, margin)
	move_child(node, index)
	return index + 1


func _build_table_look() -> void:
	var t := DevilStyle.make_theme()
	t.set_stylebox("scroll", "HScrollBar", DevilStyle.box(Color(0.05, 0.01, 0.02), DevilStyle.COL_BLOOD, 1, 4, 2))
	t.set_stylebox("grabber", "HScrollBar", DevilStyle.box(DevilStyle.COL_BLOOD, DevilStyle.COL_EMBER, 1, 4, 2))
	t.set_stylebox("grabber_highlight", "HScrollBar", DevilStyle.box(Color(0.7, 0.1, 0.08), DevilStyle.COL_EMBER, 1, 4, 2))
	t.set_stylebox("grabber_pressed", "HScrollBar", DevilStyle.box(DevilStyle.COL_EMBER, DevilStyle.COL_EMBER, 1, 4, 2))
	theme = t

	var old_board := get_node_or_null("BG") as CanvasItem
	if old_board != null:
		old_board.hide()

	var index := 0

	# Blood-red felt: black base, crimson centre, soft grain.
	var base := ColorRect.new()
	base.color = Color(0.02, 0.0, 0.01)
	index = _add_back(base, index)

	var felt_gradient := Gradient.new()
	felt_gradient.set_color(0, Color(0.32, 0.04, 0.07, 1.0))
	felt_gradient.set_color(1, Color(0.0, 0.0, 0.0, 0.0))
	felt_gradient.add_point(0.65, Color(0.12, 0.015, 0.03, 0.9))
	var felt_texture := GradientTexture2D.new()
	felt_texture.gradient = felt_gradient
	felt_texture.fill = GradientTexture2D.FILL_RADIAL
	felt_texture.fill_from = Vector2(0.5, 0.5)
	felt_texture.fill_to = Vector2(1.0, 0.5)
	felt_texture.width = 512
	felt_texture.height = 512
	var felt := TextureRect.new()
	felt.texture = felt_texture
	felt.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	felt.stretch_mode = TextureRect.STRETCH_SCALE
	index = _add_back(felt, index)

	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.35
	var grain_texture := NoiseTexture2D.new()
	grain_texture.noise = noise
	grain_texture.width = 256
	grain_texture.height = 256
	grain_texture.seamless = true
	var grain := TextureRect.new()
	grain.texture = grain_texture
	grain.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	grain.stretch_mode = TextureRect.STRETCH_TILE
	grain.modulate = Color(1, 1, 1, 0.08)
	index = _add_back(grain, index)

	# Table rim: dark thick edge with a thin blood-red inlay.
	var rim := Panel.new()
	rim.add_theme_stylebox_override("panel", DevilStyle.box(Color(0, 0, 0, 0), Color(0.16, 0.03, 0.03), 16, 22, 0))
	index = _add_back(rim, index, 6)
	var inlay := Panel.new()
	inlay.add_theme_stylebox_override("panel", DevilStyle.box(Color(0, 0, 0, 0), DevilStyle.COL_BLOOD, 2, 12, 0))
	index = _add_back(inlay, index, 26)

	# Summoning circle that sits behind the target number.
	var view_size := get_viewport_rect().size
	var ring_size := minf(view_size.x, view_size.y) * 0.5
	_ring = Control.new()
	_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ring.size = Vector2(ring_size, ring_size)
	_ring.draw.connect(_draw_ring.bind(_ring))
	add_child(_ring)
	move_child(_ring, index)
	index += 1

	# Sparks that bleed off the circle.
	_sparks = CPUParticles2D.new()
	_sparks.amount = 70
	_sparks.lifetime = 3.2
	_sparks.preprocess = 3.2
	_sparks.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE_SURFACE
	_sparks.emission_sphere_radius = ring_size * 0.48
	_sparks.direction = Vector2(0, -1)
	_sparks.spread = 180.0
	_sparks.gravity = Vector2(0, -25)
	_sparks.initial_velocity_min = 8.0
	_sparks.initial_velocity_max = 35.0
	_sparks.radial_accel_min = 15.0
	_sparks.radial_accel_max = 60.0
	_sparks.scale_amount_min = 1.5
	_sparks.scale_amount_max = 3.5
	var spark_fade := Gradient.new()
	spark_fade.set_color(0, Color(1.0, 0.6, 0.2, 0.0))
	spark_fade.set_color(1, Color(0.8, 0.1, 0.05, 0.0))
	spark_fade.add_point(0.2, Color(1.0, 0.5, 0.15, 0.9))
	_sparks.color_ramp = spark_fade
	add_child(_sparks)
	move_child(_sparks, index)


func _add_heat_overlay() -> void:
	var gradient := Gradient.new()
	gradient.set_color(0, Color(0.8, 0.0, 0.0, 0.0))
	gradient.set_color(1, Color(0.95, 0.04, 0.02, 0.85))
	gradient.add_point(0.55, Color(0.8, 0.0, 0.0, 0.0))
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	texture.width = 512
	texture.height = 512
	_heat_overlay = TextureRect.new()
	_heat_overlay.texture = texture
	_heat_overlay.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_heat_overlay.stretch_mode = TextureRect.STRETCH_SCALE
	_heat_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_heat_overlay.modulate.a = 0.0
	add_child(_heat_overlay)
	_heat_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _style_table_text() -> void:
	round_counter.add_theme_color_override("font_color", DevilStyle.COL_BONE)
	target_num_label.add_theme_color_override("font_color", DevilStyle.COL_EMBER)
	target_num_label.add_theme_color_override("font_outline_color", Color(0.12, 0.0, 0.0))
	target_num_label.add_theme_constant_override("outline_size", 10)
	DevilStyle.use_body_font(information, 24)
	DevilStyle.use_body_font(equation_label, 26)
	for heading in [playerHeading, opponentHeading]:
		heading.add_theme_font_size_override("font_size", 30)
		heading.add_theme_color_override("font_color", DevilStyle.COL_EMBER)
	DevilStyle.style_primary(submit_button, 32)
	pickup_button.add_theme_font_size_override("font_size", 26)


func _tidy_ui() -> void:
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 8)
	add_child(box)
	box.anchor_left = 0.5
	box.anchor_right = 0.5
	box.anchor_top = 0.5
	box.anchor_bottom = 0.5
	box.offset_left = -450.0
	box.offset_right = 450.0
	box.offset_top = -300.0
	box.offset_bottom = -270.0
	box.grow_vertical = Control.GROW_DIRECTION_END

	# Find the static "Target Number" title label so it joins the column.
	var target_title: Label = null
	for node in $UI.find_children("*", "Label", true, false):
		var label := node as Label
		if label != target_num_label and label.text.strip_edges() == "Target Number":
			target_title = label

	var ordered: Array[Label] = [round_counter, timer_label]
	if target_title != null:
		ordered.append(target_title)
	ordered.append(target_num_label)
	ordered.append(information)

	for label in ordered:
		label.reparent(box)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if label != information:
			label.autowrap_mode = TextServer.AUTOWRAP_OFF
	information.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	round_counter.add_theme_font_size_override("font_size", 32)
	timer_label.add_theme_font_size_override("font_size", 44)
	timer_label.custom_minimum_size = Vector2(0, 56)
	if target_title != null:
		target_title.add_theme_font_size_override("font_size", 28)
		target_title.add_theme_color_override("font_color", DevilStyle.COL_DIM)
	target_num_label.add_theme_font_size_override("font_size", 110)
