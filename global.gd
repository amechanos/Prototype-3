extends Node

# Dictionary to store connected players: { peer_id: { "name": "Alice", "score": 0 } }
var players = {}
var game_players: Array[Dictionary] = []
#var player_scene = preload("res://player.tscn")

# Called on the server when a peer connects
func _on_peer_connected(id):
	print("Player connected: ", id)

# When a player sends their profile info to the server
@rpc("any_peer", "reliable")
func register_player(player_name: String):
	var sender_id = multiplayer.get_remote_sender_id()
	players[sender_id] = {
		"name": player_name,
		"score": 0
	}
	# Sync this list to all other clients if needed
	sync_player_list.rpc(players)

@rpc("authority", "reliable")
func sync_player_list(new_players):
	players = new_players
