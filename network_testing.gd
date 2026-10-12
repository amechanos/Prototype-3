extends Control

const PORT := 7000
const MAX_REMOTE_PLAYERS := 1

var _connection_active := false

@onready var host_button: Button = %HostButton
@onready var join_address: LineEdit = %JoinAddress
@onready var join_button: Button = %JoinButton
@onready var disconnect_button: Button = %DisconnectButton
@onready var status_label: Label = %Status
@onready var players_label: Label = %Players
@onready var ip_label: Label = %IP

func get_my_local_ip() -> String:
	# Loop through all network interfaces (Wi-Fi, Ethernet, Loopback)
	for ip in IP.get_local_addresses():
		# Filter for IPv4 addresses and ignore the local loopback (127.0.0.1)
		if ip.contains(".") and not ip.begins_with("127."):
			# Common router subnets: 192.168.x.x, 10.x.x.x, 172.16.x.x
			if ip.begins_with("192.168.") or ip.begins_with("10.") or ip.begins_with("172."):
				return ip
				
	return "No LAN Connection Found"

func _ready() -> void:
	ip_label.text = "Your LAN IP: " + get_my_local_ip()
	
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func _on_host_pressed() -> void:
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_server(PORT, MAX_REMOTE_PLAYERS)
	if error != OK:
		_set_status("Could not host on port %d: %s" % [PORT, error_string(error)], true)
		return

	multiplayer.multiplayer_peer = peer
	_connection_active = true
	_set_connected_controls(true)
	var addresses := _get_lan_addresses()
	_set_status("Hosting on port %d. Give the other player this address: %s" % [
		PORT,
		", ".join(addresses)
	])
	_update_players()


func _on_join_pressed() -> void:
	var address := join_address.text.strip_edges()
	if address.is_empty():
		_set_status("Enter the host's LAN address before joining.", true)
		return

	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_client(address, PORT)
	if error != OK:
		_set_status("Could not connect to %s: %s" % [address, error_string(error)], true)
		return

	multiplayer.multiplayer_peer = peer
	_connection_active = true
	_set_connected_controls(true)
	_set_status("Connecting to %s on port %d..." % [address, PORT])


func _on_disconnect_pressed() -> void:
	_reset_connection()
	_set_status("Disconnected.")


func _on_peer_connected(peer_id: int) -> void:
	_update_players()
	if multiplayer.is_server():
		_set_status("Player %d joined. The 1v1 room is ready." % peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	_update_players()
	if multiplayer.is_server():
		_set_status("Player %d disconnected. Waiting for another player." % peer_id)


func _on_connected_to_server() -> void:
	_set_status("Connected to the host. Waiting for the game to start.")
	_update_players()


func _on_connection_failed() -> void:
	_reset_connection()
	_set_status("Connection failed. Check the address, port, and local network.", true)


func _on_server_disconnected() -> void:
	_reset_connection()
	_set_status("The host disconnected.", true)


func _reset_connection() -> void:
	multiplayer.multiplayer_peer = null
	_connection_active = false
	_set_connected_controls(false)
	_update_players()


func _set_connected_controls(connected: bool) -> void:
	host_button.disabled = connected
	join_button.disabled = connected
	join_address.editable = not connected
	disconnect_button.disabled = not connected


func _set_status(message: String, is_error: bool = false) -> void:
	status_label.text = message
	var color := Color(1.0, 0.45, 0.4) if is_error else Color(0.82, 0.88, 0.96)
	status_label.add_theme_color_override("font_color", color)


func _update_players() -> void:
	if not _connection_active:
		players_label.text = "Players: 0/2"
		return

	var remote_ids := multiplayer.get_peers()
	remote_ids.sort()
	var player_names := ["You (ID %d)" % multiplayer.get_unique_id()]
	for peer_id in remote_ids:
		player_names.append("Player ID %d" % peer_id)
	players_label.text = "Players (%d/2):\n%s" % [
		remote_ids.size() + 1,
		"\n".join(player_names)
	]


func _get_lan_addresses() -> PackedStringArray:
	var addresses := PackedStringArray()
	for address in IP.get_local_addresses():
		if address.contains(":") or address.begins_with("127.") or address == "0.0.0.0":
			continue
		if not addresses.has(address):
			addresses.append(address)

	if addresses.is_empty():
		addresses.append("No LAN IPv4 address found; check the network adapter.")
	return addresses
