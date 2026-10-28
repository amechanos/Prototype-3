extends RefCounted

const TARGET_WEIGHTS := {
	12: 0.025,
	15: 0.125,
	18: 0.225,
	21: 0.250,
	24: 0.225,
	27: 0.125,
	30: 0.025,
}
const KING_MIN := 1
const KING_MAX := 10
const JACK_DELTA := 3
const QUEEN_VOID_COUNT := 2
const ROUND_SECONDS := 10.0
const ROUND_LIMIT_SECONDS := 90.0
const OPERATORS: Array[String] = ["minus", "multiplication", "division"]
const OPERATOR_SYMBOLS := {"minus": "-", "multiplication": "x", "division": "/"}

static func roll_target() -> int:
	var roll := randf()
	var cumulative := 0.0
	for target in TARGET_WEIGHTS:
		cumulative += float(TARGET_WEIGHTS[target])
		if roll <= cumulative:
			return int(target)
	return 21

static func is_operator(card_name: String) -> bool:
	return OPERATORS.has(card_name)

static func discard_priority(card_name: String) -> int:
	if card_name in ["jack", "queen", "king", "joker"]:
		return 0
	if is_operator(card_name):
		return 1
	return 2

static func operand_value(card: Dictionary) -> int:
	var card_name := str(card.get("name", ""))
	match card_name:
		"king":
			return clampi(int(card.get("param", KING_MIN)), KING_MIN, KING_MAX)
		"jack":
			return 10
		"queen", "joker":
			return 1
	return int(card.get("value", 1))

static func card_label(card: Dictionary) -> String:
	var card_name := str(card.get("name", "?"))
	match card_name:
		"king":
			return "K(%d)" % operand_value(card)
		"jack":
			return "J(%+d)" % int(card.get("param", JACK_DELTA))
		"queen":
			return "Q"
		"joker":
			return "Joker"
	if is_operator(card_name):
		return str(OPERATOR_SYMBOLS[card_name])
	return str(operand_value(card))

# Cards read left to right. Two operands in a row are added together, and
# multiply/divide bind tighter than add/minus (BODMAS without brackets).
static func evaluate(cards: Array) -> Dictionary:
	var result := {"valid": false, "value": 0.0, "text": "", "error": ""}
	if cards.is_empty():
		result["error"] = "Select at least one card."
		return result

	var total := 0.0
	var term := 0.0
	var sign_of_term := 1.0
	var has_term := false
	var pending_op := ""
	var previous_was_operator := false
	var parts: Array[String] = []

	for card_variant in cards:
		var card: Dictionary = card_variant
		var card_name := str(card.get("name", ""))
		if is_operator(card_name):
			if not has_term or previous_was_operator:
				result["error"] = "An operator must come after a number."
				return result
			pending_op = card_name
			previous_was_operator = true
			parts.append(card_label(card))
			continue

		var operand := float(operand_value(card))
		if not has_term:
			term = operand
			has_term = true
		elif pending_op == "multiplication":
			term *= operand
		elif pending_op == "division":
			term = roundf(term / operand)
		elif pending_op == "minus":
			total += sign_of_term * term
			sign_of_term = -1.0
			term = operand
		else:
			if not parts.is_empty():
				parts.append("+")
			total += sign_of_term * term
			sign_of_term = 1.0
			term = operand
		pending_op = ""
		previous_was_operator = false
		parts.append(card_label(card))

	if previous_was_operator:
		result["error"] = "The hand cannot end on an operator."
		return result

	total += sign_of_term * term
	result["valid"] = true
	result["value"] = snappedf(total, 0.0001)
	result["text"] = " ".join(parts)
	return result
	
static func has_queen(cards: Array) -> bool:
	return _count_named(cards, "queen") > 0


# With a Queen in play, the Queen and the last two number cards stop counting.
# A removed number also takes the operator in front of it (or the one after it,
# if it was the first card) so the equation stays valid.
static func void_for_queen(cards: Array) -> Array:
	var voided: Array[int] = []
	var numbers_left := QUEEN_VOID_COUNT
	for index in range(cards.size() - 1, -1, -1):
		var card_name := str((cards[index] as Dictionary).get("name", ""))
		if card_name == "queen":
			voided.append(index)
		elif numbers_left > 0 and card_name.is_valid_int():
			voided.append(index)
			numbers_left -= 1

	var removed := {}
	for index in voided:
		removed[index] = true
		if index > 0 and is_operator(str((cards[index - 1] as Dictionary).get("name", ""))):
			removed[index - 1] = true
		elif index == 0 and cards.size() > 1 and is_operator(str((cards[1] as Dictionary).get("name", ""))):
			removed[1] = true

	var kept: Array = []
	for index in range(cards.size()):
		if not removed.has(index):
			kept.append(cards[index])
	while not kept.is_empty() and is_operator(str((kept[0] as Dictionary).get("name", ""))):
		kept.pop_front()
	while not kept.is_empty() and is_operator(str((kept[kept.size() - 1] as Dictionary).get("name", ""))):
		kept.pop_back()
	return kept

static func format_number(value: float) -> String:
	if is_equal_approx(value, roundf(value)):
		return str(int(roundf(value)))
	return "%.2f" % value

static func adjusted_target(base_target: int, cards_a: Array, cards_b: Array) -> int:
	var delta := 0
	for card_variant in cards_a + cards_b:
		var card: Dictionary = card_variant
		if str(card.get("name", "")) == "jack":
			delta += JACK_DELTA if int(card.get("param", JACK_DELTA)) >= 0 else -JACK_DELTA
	return maxi(1, base_target + delta)

static func _count_named(cards: Array, card_name: String) -> int:
	var count := 0
	for card_variant in cards:
		var card: Dictionary = card_variant
		if str(card.get("name", "")) == card_name:
			count += 1
	return count


# Queens and Jokers are always discarded after a round. The winner also
# discards the rest of the hand they played.
static func _discard_uids(cards: Array, is_winner: bool) -> Array[int]:
	var discards: Array[int] = []
	for card_variant in cards:
		var card: Dictionary = card_variant
		var card_name := str(card.get("name", ""))
		if is_winner or card_name == "queen" or card_name == "joker":
			discards.append(int(card["uid"]))
	return discards

# Returns winner as 0 (player A), 1 (player B) or -1 (draw).
static func resolve(base_target: int, cards_a: Array, cards_b: Array) -> Dictionary:
	var target := adjusted_target(base_target, cards_a, cards_b)
	var queen_active := has_queen(cards_a) or has_queen(cards_b)
	var eval_a := evaluate(void_for_queen(cards_a) if queen_active else cards_a)
	var eval_b := evaluate(void_for_queen(cards_b) if queen_active else cards_b)
	var score_a := float(eval_a["value"]) if bool(eval_a["valid"]) else 0.0
	var score_b := float(eval_b["value"]) if bool(eval_b["valid"]) else 0.0
	var used_a := cards_a.size()
	var used_b := cards_b.size()

	var joker_a := _count_named(cards_a, "joker") % 2 == 1
	var joker_b := _count_named(cards_b, "joker") % 2 == 1
	var swapped := joker_a != joker_b
	if swapped:
		var temp_score := score_a
		score_a = score_b
		score_b = temp_score
		var temp_used := used_a
		used_a = used_b
		used_b = temp_used

	var bust_a := score_a > target
	var bust_b := score_b > target
	var winner := -1
	if bust_a != bust_b:
		winner = 1 if bust_a else 0
	elif not bust_a and not is_equal_approx(score_a, score_b):
		winner = 0 if score_a > score_b else 1
	elif used_a != used_b:
		winner = 0 if used_a > used_b else 1

	return {
		"winner": winner,
		"target": target,
		"score": [score_a, score_b],
		"bust": [bust_a, bust_b],
		"used": [used_a, used_b],
		"swapped": swapped,
		"queen_active": queen_active,
		"discard": [
			_discard_uids(cards_a, winner == 0),
			_discard_uids(cards_b, winner == 1),
		],
	}
