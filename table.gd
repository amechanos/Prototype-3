extends Control

@onready var players_container: VBoxContainer = $MarginContainer/Layout/Players
@onready var status_label: Label = $MarginContainer/Layout/Status


func _ready() -> void:
	for player_data in Global.game_players:
		var player_panel := PanelContainer.new()
		players_container.add_child(player_panel)

		var player_layout := VBoxContainer.new()
		player_panel.add_child(player_layout)

		var player_heading := Label.new()
		player_heading.text = "%s (Player %d)" % [
			str(player_data.get("name", "Player")),
			int(player_data.get("peer_id", 0)),
		]
		player_layout.add_child(player_heading)

		var cards: Array = player_data.get("cards", [])
		var card_names: Array[String] = []
		for card in cards:
			card_names.append(str(card.get("name", "Unknown card")))

		var inventory := Label.new()
		inventory.text = "Cards: %s" % (
			", ".join(card_names) if not card_names.is_empty() else "None"
		)
		inventory.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		player_layout.add_child(inventory)

		var score_label := Label.new()
		score_label.text = "Score: %d" % int(player_data.get("score", 0))
		player_layout.add_child(score_label)

	status_label.text = "Table ready." if not Global.game_players.is_empty() else (
		"No player data was received."
	)
