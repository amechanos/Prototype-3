extends Control

const Rules = preload("res://rules.gd")
const RESULT_PAUSE := 10.0
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
const CARD_SIZE := Vector2(100, 136)
const PILL_COLOR_BG := Color(0.1, 0.1, 0.1, 0.85)
const PILL_COLOR_NEUTRAL := Color(0.35, 0.35, 0.4, 0.9)
const PILL_COLOR_RAISE := Color(0.25, 0.6, 0.35, 0.95)
const PILL_COLOR_LOWER := Color(0.7, 0.28, 0.28, 0.95)
const DEBUG_DECK_CARD_COUNTS := {
	"1": 3, "2": 3, "3": 3, "4": 3, "5": 3,
	"6": 3, "7": 3, "8": 3, "9": 3, "10": 3,
	"jack": 3, "queen": 3, "king": 3, "joker": 2,
	"minus": 3, "multiplication": 3, "division": 3,
}

const DEBUG_OPPONENT_CARDS := 10

const SFX_SHUFFLE := preload("res://SFX/Insane shuffle.wav")
const SFX_DEAL := preload("res://SFX/Card place down.wav")
const SFX_PICK := preload("res://SFX/Card Pick.mp3")

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

func _ready() -> void:
	playerHeading.hide()
	opponentHeading.hide()
	_update_pickup_button()
	information.text = " "
	my_id = multiplayer.get_unique_id()
	if multiplayer.multiplayer_peer == null and Global.game_players.is_empty():
		Global.game_players = [{
			"peer_id": my_id,
			"name": "Debug Player",
			"cards": [],
		}]
	for player_data in Global.game_players:
		var peer_id := int(player_data.get("peer_id", -1))
		player_ids.append(peer_id)
		names[peer_id] = str(player_data.get("name", "Player %d" % peer_id))
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	if multiplayer.is_server():
		_host_mark_ready()
	else:
		_send(1, &"_host_mark_ready", [])

func _process(delta: float) -> void:
	if time_left < 0.0:
		return
	time_left = maxf(0.0, time_left - delta)
	timer_label.text = "Time left: %.1f" % time_left
	if time_left == 0.0:
		time_left = -1.0
		if not has_submitted:
			_submit_current_hand(true)

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
	for player_data in Global.game_players:
		var hand: Array = []
		for card_variant in player_data.get("cards", []):
			var card: Dictionary = card_variant
			hand.append({
				"uid": next_uid,
				"name": str(card.get("name", "")).to_lower(),
				"value": int(card.get("value", 1)),
			})
			next_uid += 1
		if OS.is_debug_build() and player_ids.size() == 1 and hand.is_empty():
			hand = _make_debug_player_deck()
		hands[int(player_data.get("peer_id", -1))] = hand
	_host_start_round()

func _is_debug_solo() -> bool:
	return OS.is_debug_build() and player_ids.size() == 1

func _make_debug_player_deck() -> Array:
	var deck: Array = []
	for card_name in DEBUG_DECK_CARD_COUNTS:
		for _copy_index in range(DEBUG_DECK_CARD_COUNTS[card_name]):
			deck.append({
				"uid": next_uid,
				"name": card_name,
				"value": int(card_name) if card_name.is_valid_int() else 1,
			})
			next_uid += 1
	return deck

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
		_broadcast(&"_start_countdown", [Rules.ROUND_SECONDS])
		_host_deadline(round_number, Rules.ROUND_SECONDS)

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
	opponent_heading.text = ""
	opponent_played_cards = []
	opponent_count = 0
	for peer_id in counts:
		if int(peer_id) != my_id:
			opponent_count += int(counts[peer_id])
	if _is_debug_solo():
		opponent_count = DEBUG_OPPONENT_CARDS
	selected_cards.clear()
	_render_hand()
	_render_opponent()
	_refresh_selection()
	round_counter.text = "Round %d" % round_no
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

	var lines: Array[String] = []
	if int(result["target"]) != target_number:
		lines.append("Jacks moved the target to %d." % int(result["target"]))
	if bool(result["swapped"]):
		lines.append("A Joker swapped the hands!")
	lines.append("You: %s%s" % [
		Rules.format_number(float(score[mine])),
		" (bust)" if bool(bust[mine]) else "",
	])
	if int(peers[other]) != -1:
		lines.append("%s: %s%s" % [
			names.get(int(peers[other]), "Opponent"),
			Rules.format_number(float(score[other])),
			" (bust)" if bool(bust[other]) else "",
		])
	var winner := int(result["winner"])
	var discard_mine: Array = result["discard"][mine]
	var discard_other: Array = result["discard"][other]
	if winner == -1:
		lines.append("Draw - nobody discards the cards they played.")
	elif winner == mine:
		lines.append("You win the round!")
	else:
		lines.append("You lose the round and keep your cards.")
	lines.append("You discard %d card(s)." % discard_mine.size())
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
	#information.text = " "

@rpc("authority", "call_remote", "reliable")
func _game_over(winner_peer: int, note: String) -> void:
	game_finished = true
	time_left = -1.0
	timer_label.text = ""
	has_submitted = true
	selected_cards.clear()
	_render_hand()
	_refresh_selection()
	_update_pickup_button()
	var message := note
	if winner_peer == my_id:
		message += " You win - you disposed of all your cards!" if note == "" else " You win!"
	else:
		message = "%s disposed of all their cards. You lose." % names.get(winner_peer, "Your opponent")
	round_counter.text = message.strip_edges()
	submit_button.disabled = true
	_update_pickup_button()

# ----------------------------------------------------------------- client: UI
func _render_hand() -> void:
	for child in player_cards_container.get_children():
		child.queue_free()
	player_card_buttons.clear()
	for card_variant in my_hand:
		var card: Dictionary = card_variant
		var slot := Control.new()
		slot.custom_minimum_size = CARD_SIZE + Vector2(0, SELECT_LIFT)
		var card_button := Button.new()
		card_button.set_meta("card", card)
		card_button.toggle_mode = true
		card_button.size = CARD_SIZE
		card_button.position = Vector2(0, SELECT_LIFT)
		card_button.disabled = has_submitted or game_finished
		card_button.toggled.connect(_on_card_toggled.bind(card_button))
		card_button.text = _card_title(card)
		card_button.add_child(_make_order_badge())
		var param_control := _make_param_control(card)
		if param_control != null:
			card_button.add_child(param_control)
			card_button.set_meta("param_control", param_control)
		slot.add_child(card_button)
		slot.set_meta("button", card_button)
		player_cards_container.add_child(slot)
		player_card_buttons.append(card_button)

func _make_order_badge() -> Label:
	var badge := Label.new()
	badge.name = "OrderBadge"
	badge.custom_minimum_size = Vector2(24, 24)
	badge.position = Vector2(6, 6)
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
		if _is_debug_solo():
			opponent_names.append("Debug Opponent")
		else:
			opponent_heading.text = "No opponent (practice round)"
			return
	opponent_heading.text = "%s (%d cards, face down)" % [", ".join(opponent_names), opponent_count]
	for _index in range(opponent_count):
		var card_back := Button.new()
		card_back.text = "?"
		card_back.custom_minimum_size = CARD_SIZE
		card_back.disabled = true
		opponent_cards_container.add_child(card_back)

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
	var piles: Array[Control] = [$playerCards, $opponentCards]
	var rows: Array[BoxContainer] = [player_cards_container, opponent_cards_container]
	var off_screen_y: Array[float] = [DEAL_OFFSCREEN, -DEAL_OFFSCREEN]
	var peek_y: Array[float] = [-DEAL_PEEK, DEAL_PEEK]
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
			float(DEAL_STACK_SEPARATION), float(HAND_SEPARATION), DEAL_SPREAD
		).set_ease(Tween.EASE_IN_OUT)
		finish = tween
		
	playerHeading.show()
	opponentHeading.show()

	await finish.finished
	for card in locked:
		if is_instance_valid(card):
			card.disabled = has_submitted or game_finished

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
	return " ".join(parts)

func _on_submit_pressed() -> void:
	_submit_current_hand(false)

func _submit_current_hand(auto_submit: bool) -> void:
	if has_submitted or game_finished:
		return
	var cards := _played_cards()
	if auto_submit:
		while not cards.is_empty() and Rules.is_operator(str(cards.back()["name"])):
			cards.pop_back()
		cards = []

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
