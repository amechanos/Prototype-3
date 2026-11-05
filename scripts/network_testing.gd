extends Control

const PORT := 7000
const MAX_REMOTE_PLAYERS := 1

const FONT_PATH := "res://Assets/JimNightshade-Regular.ttf" # 
const BODY_FONT_PATH := "res://Assets/Cinzel-VariableFont_wght.ttf" # 
const GAME_TITLE := "white jack" # 
const COL_BG := Color(0.03, 0.0, 0.02)
const COL_PANEL := Color(0.08, 0.015, 0.025, 0.94)
const COL_BLOOD := Color(0.5, 0.04, 0.06)
const COL_EMBER := Color(1.0, 0.4, 0.12)
const COL_BONE := Color(0.93, 0.86, 0.74)
const COL_DIM := Color(0.55, 0.45, 0.42)

var _panel_style: StyleBoxFlat

var _connection_active := false

var _public_ip_request: HTTPRequest

@onready var host_button: Button = %HostButton
@onready var join_address: LineEdit = %JoinAddress
@onready var join_button: Button = %JoinButton
@onready var disconnect_button: Button = %DisconnectButton
@onready var play_button: Button = %PlayButton
@onready var hard_mode_button: CheckButton = %HardModeButton
@onready var status_label: Label = %Status
@onready var players_label: Label = %Players
@onready var ip_label: Label = %IP

func get_my_local_ip() -> String:
	var fallback_ipv4 := ""
	for ip in IP.get_local_addresses():
		if ip.contains(".") and not ip.begins_with("127."):
			if fallback_ipv4.is_empty():
				fallback_ipv4 = ip
			if ip.begins_with("192.168.") or ip.begins_with("10."):
				return ip
			if ip.begins_with("172."):
				var octets := ip.split(".")
				if octets.size() == 4 and int(octets[1]) >= 16 and int(octets[1]) <= 31:
					return ip

	return fallback_ipv4 if not fallback_ipv4.is_empty() else "No network IPv4 found"

func _ready() -> void:
	_add_embers()
	ip_label.text = "Your network IPv4: %s\nYour public IPv4: Looking up..." % get_my_local_ip()
	_public_ip_request = HTTPRequest.new()
	_public_ip_request.timeout = 10.0
	_public_ip_request.request_completed.connect(_on_public_ip_request_completed)
	add_child(_public_ip_request)
	var request_error := _public_ip_request.request("https://api4.ipify.org")
	if request_error != OK:
		ip_label.text = "Your network IPv4: %s\nPublic IPv4 lookup failed: %s" % [
			get_my_local_ip(),
			error_string(request_error)
		]
	
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func _on_public_ip_request_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray
) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		ip_label.text = "Your network IPv4: %s\nPublic IPv4 lookup failed (request result %d)." % [
			get_my_local_ip(),
			result
		]
		return
	if response_code != 200:
		ip_label.text = "Your network IPv4: %s\nPublic IPv4 lookup failed (HTTP %d)." % [
			get_my_local_ip(),
			response_code
		]
		return

	var public_ip := body.get_string_from_utf8().strip_edges()
	#if not IP.is_valid_ip_address(public_ip):
		#ip_label.text = "Your network IPv4: %s\nPublic IPv4 lookup returned an invalid address." % get_my_local_ip()
		#return

	ip_label.text = "Your network IPv4: %s\nYour public IPv4: %s\nForward UDP port %d for internet play." % [
		get_my_local_ip(),
		public_ip,
		PORT
	]

func _on_host_pressed() -> void:
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_server(PORT, MAX_REMOTE_PLAYERS)
	if error != OK:
		_set_status("Could not host on port %d: %s" % [PORT, error_string(error)], true)
		return

	multiplayer.multiplayer_peer = peer
	_connection_active = true
	_set_connected_controls(true)
	_set_status("Hosting on UDP port %d. For internet play, share your public IPv4 and forward UDP %d." % [
		PORT,
		PORT
	])
	_update_players()

func _on_join_pressed() -> void:
	var address := join_address.text.strip_edges()
	if address.is_empty():
		_set_status("Enter the host's LAN or public IPv4 address before joining.", true)
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

func _on_play_pressed() -> void:
	if multiplayer.multiplayer_peer == null:
		_open_card_board()
	elif multiplayer.is_server():
		if multiplayer.get_peers().is_empty():
			_set_status("Wait for another player to join before starting.", true)
			return
		_start_card_board.rpc(Global.hard_mode)
	else:
		_set_status("Wait for the host to start the shared board.")

func _on_hard_mode_toggled(pressed: bool) -> void:
	Global.hard_mode = pressed

func _open_card_board() -> void:
	var error := get_tree().change_scene_to_file("res://board.tscn")
	if error != OK:
		push_error("Could not open the card board: %s" % error_string(error))

@rpc("authority", "call_local", "reliable")
func _start_card_board(hard_mode: bool) -> void:
	Global.hard_mode = hard_mode
	_open_card_board()

func _on_peer_connected(peer_id: int) -> void:
	_update_players()
	_set_connected_controls(_connection_active)
	if multiplayer.is_server():
		_set_status("Player %d joined. The room is ready." % peer_id)

func _on_peer_disconnected(peer_id: int) -> void:
	_update_players()
	_set_connected_controls(_connection_active)
	if multiplayer.is_server():
		_set_status("Player %d disconnected. Waiting for another player." % peer_id)

func _on_connected_to_server() -> void:
	_set_connected_controls(_connection_active)
	_set_status("Connected to the host. Waiting for the game to start.")
	_update_players()

func _on_connection_failed() -> void:
	_reset_connection()
	_set_status("Connection failed. Check the address, host firewall, UDP port forwarding, and network restrictions.", true)

func _on_server_disconnected() -> void:
	_reset_connection()
	_set_status("The host disconnected.", true)

func _reset_connection() -> void:
	multiplayer.multiplayer_peer = null
	_connection_active = false
	_set_connected_controls(false)
	_update_players()

func _set_connected_controls(connected: bool) -> void:
	hard_mode_button.visible = connected and multiplayer.is_server()
	if not connected:
		hard_mode_button.button_pressed = false
	host_button.disabled = connected
	join_button.disabled = connected
	join_address.editable = not connected
	disconnect_button.disabled = not connected
	play_button.disabled = connected and (
		not multiplayer.is_server() or multiplayer.get_peers().is_empty()
	)

func _set_status(message: String, is_error: bool = false) -> void:
	status_label.text = message
	var color := Color(1.0, 0.3, 0.25) if is_error else COL_BONE
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
	
func _box(bg: Color, border: Color, border_width := 2, radius := 4, margin := 10) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = bg
	box.border_color = border
	box.set_border_width_all(border_width)
	box.set_corner_radius_all(radius)
	box.set_content_margin_all(margin)
	return box


func _build_theme() -> Theme:
	_panel_style = _box(COL_PANEL, COL_BLOOD, 3, 6, 0)
	_panel_style.shadow_color = Color(0.9, 0.15, 0.05, 0.5)
	_panel_style.shadow_size = 16

	var t := Theme.new()
	if ResourceLoader.exists(FONT_PATH):
		var font := load(FONT_PATH) as Font
		if font != null:
			t.default_font = font
	t.default_font_size = 24

	t.set_color("font_color", "Label", COL_BONE)
	t.set_stylebox("panel", "PanelContainer", _panel_style)

	var line := StyleBoxLine.new()
	line.color = COL_BLOOD
	line.thickness = 2
	t.set_stylebox("separator", "HSeparator", line)
	t.set_constant("separation", "HSeparator", 14)

	t.set_font_size("font_size", "Button", 28)
	t.set_color("font_color", "Button", COL_BONE)
	t.set_color("font_hover_color", "Button", Color.WHITE)
	t.set_color("font_pressed_color", "Button", COL_EMBER)
	t.set_color("font_focus_color", "Button", COL_BONE)
	t.set_color("font_disabled_color", "Button", COL_DIM)
	t.set_stylebox("normal", "Button", _box(Color(0.16, 0.03, 0.04), COL_BLOOD))
	t.set_stylebox("hover", "Button", _box(Color(0.3, 0.05, 0.05), COL_EMBER))
	t.set_stylebox("pressed", "Button", _box(Color(0.08, 0.0, 0.0), COL_EMBER))
	t.set_stylebox("disabled", "Button", _box(Color(0.08, 0.04, 0.04, 0.8), Color(0.22, 0.12, 0.12)))
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())

	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		t.set_stylebox(state, "CheckButton", StyleBoxEmpty.new())

	t.set_font_size("font_size", "LineEdit", 24)
	t.set_color("font_color", "LineEdit", COL_BONE)
	t.set_color("font_placeholder_color", "LineEdit", COL_DIM)
	t.set_color("caret_color", "LineEdit", COL_EMBER)
	t.set_color("selection_color", "LineEdit", COL_BLOOD)
	t.set_stylebox("normal", "LineEdit", _box(Color(0.04, 0.01, 0.01), COL_BLOOD))
	t.set_stylebox("focus", "LineEdit", _box(Color(0.06, 0.01, 0.01), COL_EMBER))
	return t

func _add_embers() -> void:
	var view_size := get_viewport_rect().size
	var embers := CPUParticles2D.new()
	embers.amount = 70
	embers.lifetime = 7.0
	embers.preprocess = 7.0
	embers.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	embers.emission_rect_extents = Vector2(view_size.x / 2.0, 10.0)
	embers.position = Vector2(view_size.x / 2.0, view_size.y + 10.0)
	embers.direction = Vector2(0, -1)
	embers.spread = 25.0
	embers.gravity = Vector2.ZERO
	embers.initial_velocity_min = 30.0
	embers.initial_velocity_max = 90.0
	embers.scale_amount_min = 1.5
	embers.scale_amount_max = 4.0

	var fade := Gradient.new()
	fade.set_color(0, Color(1.0, 0.6, 0.2, 0.0))
	fade.set_color(1, Color(0.8, 0.1, 0.05, 0.0))
	fade.add_point(0.2, Color(1.0, 0.5, 0.15, 0.9))
	embers.color_ramp = fade

	add_child(embers)
	move_child(embers, 2)
