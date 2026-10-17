extends Control

const Rules = preload("res://rules.gd")
const RESULT_PAUSE := 4.0
const DEADLINE_GRACE := 1.5

@onready var target_num_label: Label = $TargetNumber
@onready var player_cards_container: HBoxContainer = $playerCards/HandLayout/ScrollContainer/HBoxContainer
@onready var opponent_cards_container: HBoxContainer = $opponentCards/HandLayout/ScrollContainer2/HBoxContainer
@onready var player_heading: Label = $playerCards/HandLayout/HandHeading
@onready var opponent_heading: Label = $opponentCards/HandLayout/HandHeading

var my_id := 1
var names: Dictionary = {}
var player_ids: Array[int] = []

# Host-only state.
var hands: Dictionary = {}
var ready_peers: Array[int] = []
var submissions: Dictionary = {}
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
var time_left := -1.0
var equation_flow: HFlowContainer
var equation_label: Label
var timer_label: Label
var submit_button: Button
var status_label: Label
var opponent_played_label: Label
var back_button: Button


func _ready() -> void:
	my_id = multiplayer.get_unique_id()
	for player_data in Global.game_players:
		var peer_id := int(player_data.get("peer_id", -1))
		player_ids.append(peer_id)
		names[peer_id] = str(player_data.get("name", "Player %d" % peer_id))
	_build_ui()
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
		hands[int(player_data.get("peer_id", -1))] = hand
	_host_start_round()


func _host_start_round() -> void:
	if game_finished:
		return
	round_number += 1
	base_target = Rules.roll_target()
	submissions.clear()
	round_active = true
	var counts := {}
	for peer_id in player_ids:
		counts[peer_id] = (hands[peer_id] as Array).size()
	for peer_id in player_ids:
		_send(peer_id, &"_receive_round", [hands[peer_id], counts, base_target, round_number])
	_host_deadline(round_number, Rules.ROUND_LIMIT_SECONDS)


@rpc("any_peer", "call_remote", "reliable")
func _host_receive_submit(picks: Array) -> void:
	if not multiplayer.is_server() or not round_active:
		return
	var sender := _sender()
	if not player_ids.has(sender) or submissions.has(sender):
		return

	var played := _build_played_cards(sender, picks)
	submissions[sender] = played
	_broadcast(&"_show_submission", [sender, played])
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
	_set_status("The host disconnected.")
	_lock_hand()
	back_button.visible = true

# ------------------------------------------------------------ client: rounds

@rpc("authority", "call_remote", "reliable")
func _receive_round(hand: Array, counts: Dictionary, target: int, round_no: int) -> void:
	my_hand = hand.duplicate(true)
	target_number = target
	target_num_label.text = str(target)
	has_submitted = false
	time_left = Rules.ROUND_LIMIT_SECONDS
	timer_label.text = ""
	opponent_played_label.text = ""
	opponent_played_cards = []
	opponent_count = 0
	for peer_id in counts:
		if int(peer_id) != my_id:
			opponent_count += int(counts[peer_id])
	selected_cards.clear()
	_render_hand()
	_render_opponent()
	_refresh_equation()
	_set_status("Round %d: select cards left to right, then submit your hand." % round_no)


@rpc("authority", "call_remote", "reliable")
func _show_submission(peer_id: int, cards: Array) -> void:
	if peer_id == my_id:
		return
	opponent_played_cards = cards
	var evaluation := Rules.evaluate(cards)
	if bool(evaluation["valid"]):
		opponent_played_label.text = "%s played: %s = %s" % [
			names.get(peer_id, "Opponent"),
			evaluation["text"],
			Rules.format_number(float(evaluation["value"])),
		]
	else:
		opponent_played_label.text = "%s played nothing valid." % names.get(peer_id, "Opponent")
	_update_evaluation()


@rpc("authority", "call_remote", "reliable")
func _start_countdown(seconds: float) -> void:
	if has_submitted:
		return
	time_left = seconds if time_left < 0.0 else minf(seconds, time_left)
	_set_status("Your opponent submitted! Submit within %d seconds or your current selection is sent." % ceili(time_left))


@rpc("authority", "call_remote", "reliable")
func _show_result(result: Dictionary) -> void:
	time_left = -1.0
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
	_set_status("\n".join(lines))

	my_hand = my_hand.filter(
		func(card: Dictionary) -> bool: return not discard_mine.has(int(card["uid"]))
	)
	opponent_count = maxi(0, opponent_count - discard_other.size())
	has_submitted = true
	selected_cards.clear()
	_render_hand()
	_render_opponent()
	_refresh_equation()


@rpc("authority", "call_remote", "reliable")
func _game_over(winner_peer: int, note: String) -> void:
	game_finished = true
	time_left = -1.0
	timer_label.text = ""
	has_submitted = true
	selected_cards.clear()
	_render_hand()
	_refresh_equation()
	var message := note
	if winner_peer == my_id:
		message += " You win - you disposed of all your cards!" if note == "" else " You win!"
	else:
		message = "%s disposed of all their cards. You lose." % names.get(winner_peer, "Your opponent")
	_set_status(message.strip_edges())
	submit_button.disabled = true
	back_button.visible = true

# ----------------------------------------------------------------- client: UI

func _build_ui() -> void:
	var equation_title := Label.new()
	equation_title.text = "Equation (left to right, x and / first, neighbouring numbers add)"
	_place(equation_title, Vector2(12, 196), Vector2(560, 24))

	equation_flow = HFlowContainer.new()
	equation_flow.add_theme_constant_override("h_separation", 6)
	equation_flow.add_theme_constant_override("v_separation", 6)
	_place(equation_flow, Vector2(12, 224), Vector2(560, 150))

	equation_label = Label.new()
	equation_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_place(equation_label, Vector2(12, 380), Vector2(560, 64))

	timer_label = Label.new()
	_place(timer_label, Vector2(700, 196), Vector2(440, 24))

	submit_button = Button.new()
	submit_button.text = "Submit hand"
	submit_button.disabled = true
	submit_button.pressed.connect(_on_submit_pressed)
	_place(submit_button, Vector2(700, 224), Vector2(180, 40))

	back_button = Button.new()
	back_button.text = "Back to lobby"
	back_button.visible = false
	back_button.pressed.connect(_on_back_pressed)
	_place(back_button, Vector2(900, 224), Vector2(180, 40))

	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_place(status_label, Vector2(700, 272), Vector2(440, 110))

	opponent_played_label = Label.new()
	opponent_played_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_place(opponent_played_label, Vector2(700, 388), Vector2(440, 56))

	target_num_label.text = "?"
	_set_status("Waiting for all players to load...")


func _place(control: Control, pos: Vector2, control_size: Vector2) -> void:
	add_child(control)
	control.position = pos
	control.size = control_size


func _set_status(message: String) -> void:
	status_label.text = message


func _render_hand() -> void:
	for child in player_cards_container.get_children():
		child.queue_free()
	player_card_buttons.clear()
	for card_variant in my_hand:
		var card: Dictionary = card_variant
		var card_button := Button.new()
		card_button.set_meta("card", card)
		card_button.toggle_mode = true
		card_button.custom_minimum_size = Vector2(100, 136)
		card_button.disabled = has_submitted or game_finished
		card_button.toggled.connect(_on_card_toggled.bind(card_button))
		card_button.text = _card_title(card)
		player_cards_container.add_child(card_button)
		player_card_buttons.append(card_button)


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
		var card_back := Button.new()
		card_back.text = "?"
		card_back.custom_minimum_size = Vector2(100, 136)
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
	else:
		selected_cards.erase(card_button)
	_refresh_equation()


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


func _refresh_equation() -> void:
	for child in equation_flow.get_children():
		child.queue_free()
	var selected_count := 0
	for card_button in player_card_buttons:
		var card: Dictionary = card_button.get_meta("card")
		var order := selected_cards.find(card_button) + 1
		card_button.text = _card_title(card) if order == 0 else "%d.\n%s" % [order, _card_title(card)]
		if order > 0:
			selected_count += 1
			equation_flow.add_child(_make_equation_entry(card, order))
	player_heading.text = "Your hand - click cards in the order to play them (%d selected)" % selected_count
	_update_evaluation()


func _make_equation_entry(card: Dictionary, order: int) -> Control:
	var entry := VBoxContainer.new()
	var title := Label.new()
	title.text = "%d. %s" % [order, _card_title(card).replace("\n", " ")]
	entry.add_child(title)
	var card_name := str(card["name"])
	var uid: int = card["uid"]
	if card_name == "king":
		var spin := SpinBox.new()
		spin.min_value = Rules.KING_MIN
		spin.max_value = Rules.KING_MAX
		spin.value = int(card_params.get(uid, _default_param(card_name)))
		spin.editable = not has_submitted
		spin.value_changed.connect(_on_king_changed.bind(uid))
		entry.add_child(spin)
	elif card_name == "jack":
		var choice := OptionButton.new()
		choice.add_item("Target +3", 0)
		choice.add_item("Target -3", 1)
		choice.selected = 0 if int(card_params.get(uid, _default_param(card_name))) >= 0 else 1
		choice.disabled = has_submitted
		choice.item_selected.connect(_on_jack_changed.bind(uid))
		entry.add_child(choice)
	return entry


func _on_king_changed(value: float, uid: int) -> void:
	card_params[uid] = int(value)
	_update_evaluation()


func _on_jack_changed(index: int, uid: int) -> void:
	card_params[uid] = Rules.JACK_DELTA if index == 0 else -Rules.JACK_DELTA
	_update_evaluation()


func _update_evaluation() -> void:
	var cards := _played_cards()
	var evaluation := Rules.evaluate(cards)
	var live_target := Rules.adjusted_target(target_number, cards, opponent_played_cards)
	var text := ""
	if cards.is_empty():
		text = "No cards selected."
	elif bool(evaluation["valid"]):
		var value := float(evaluation["value"])
		text = "%s = %s (target %d)" % [evaluation["text"], Rules.format_number(value), live_target]
		if value > live_target:
			text += " - BUST"
	else:
		text = str(evaluation["error"])
	for card in cards:
		if card["name"] == "joker":
			text += "\nJoker: your hand and your opponent's hand swap results."
			break
	equation_label.text = text
	submit_button.disabled = (
		has_submitted or game_finished or not bool(evaluation["valid"])
	)


func _on_submit_pressed() -> void:
	_submit_current_hand(false)


func _submit_current_hand(auto_submit: bool) -> void:
	if has_submitted or game_finished:
		return
	var cards := _played_cards()
	if auto_submit:
		while not cards.is_empty() and Rules.is_operator(str(cards.back()["name"])):
			cards.pop_back()
	if not bool(Rules.evaluate(cards)["valid"]):
		if not auto_submit:
			return
		cards = []

	var picks: Array = []
	for card in cards:
		picks.append({"uid": card["uid"], "param": card.get("param", 0)})
	has_submitted = true
	time_left = -1.0
	timer_label.text = ""
	_lock_hand()
	_set_status("Hand submitted. Waiting for the round to finish...")
	_send(1, &"_host_receive_submit", [picks])


func _lock_hand() -> void:
	for card_button in player_card_buttons:
		card_button.disabled = true
	for child in equation_flow.get_children():
		for part in child.get_children():
			if part is SpinBox:
				part.editable = false
			elif part is OptionButton:
				part.disabled = true
	submit_button.disabled = true


func _on_back_pressed() -> void:
	multiplayer.multiplayer_peer = null
	get_tree().change_scene_to_file("res://network_testing.tscn")
