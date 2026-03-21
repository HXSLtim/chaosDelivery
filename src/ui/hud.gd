extends CanvasLayer

const UNKNOWN_TEXT := "N/A"
const PROTOTYPE_CONTROLS_TEXT := "Controls: WASD Move  E Grab/Drop  F Throw"
const NETWORK_CONTROLS_TEXT := "Network: F5 Host LAN  F6 Join localhost  F7 Leave"

@onready var _player_label: Label = $Panel/Content/PlayerLabel
@onready var _phase_label: Label = $Panel/Content/PhaseLabel
@onready var _gold_label: Label = $Panel/Content/GoldLabel
@onready var _score_label: Label = $Panel/Content/ScoreLabel
@onready var _network_label: Label = $Panel/Content/NetworkLabel
@onready var _orders_label: Label = $Panel/Content/OrdersLabel
@onready var _controls_label: Label = $Panel/Content/ControlsLabel
@onready var _network_controls_label: Label = $Panel/Content/NetworkControlsLabel

var _refresh_interval: float = 0.2
var _refresh_timer: float = 0.0
var _order_manager: Node = null


func _ready() -> void:
	_refresh_labels()


func _process(delta: float) -> void:
	_refresh_timer -= delta
	if _refresh_timer > 0.0:
		return

	_refresh_timer = _refresh_interval
	_refresh_labels()


func _refresh_labels() -> void:
	var game_state := get_node_or_null("/root/GameState")
	var network_manager := get_node_or_null("/root/NetworkManager")

	_player_label.text = "Player: %s" % _to_text(_read_prop(game_state, "local_player_name"))
	_phase_label.text = "Phase: %s" % _format_phase(_read_prop(game_state, "current_phase"))
	_gold_label.text = "Gold: %s" % _to_text(_read_prop(game_state, "current_gold"))
	_score_label.text = "Score: %s" % _to_text(_read_prop(game_state, "current_score"))
	_network_label.text = "Network: %s" % _format_network_status(network_manager)
	_orders_label.text = _format_order_status(game_state)
	_controls_label.text = PROTOTYPE_CONTROLS_TEXT
	_network_controls_label.text = NETWORK_CONTROLS_TEXT


func _read_prop(node: Node, prop: StringName):
	if node == null:
		return null
	if not _has_property(node, prop):
		return null
	return node.get(prop)


func _format_network_status(network_manager: Node) -> String:
	if network_manager == null:
		return "Offline (No NetworkManager)"

	var connected = _read_prop(network_manager, "is_connected")
	var host = _read_prop(network_manager, "is_host")
	var peer_count := _peer_count(network_manager)
	var remote_count: int = maxi(peer_count - 1, 0)
	var connection_state := _network_link_state(network_manager)
	var local_peer_id := _network_local_peer_id(network_manager)

	if connected == null:
		return "Unknown (Missing is_connected)"

	var role := "Role Unknown"
	if host == true:
		role = "Host"
	elif host == false:
		role = "Client"

	var parts: Array[String] = [role, "peers=%d" % peer_count, "remote=%d" % remote_count]
	if local_peer_id > 0:
		parts.append("id=%d" % local_peer_id)
	if connection_state != "":
		parts.append("link=%s" % connection_state)

	var is_connecting = _read_prop(network_manager, "is_connecting")
	var status := "Disconnected"
	if is_connecting == true:
		status = "Connecting"
	elif connected == true:
		status = "Connected"

	var last_connection_error = _read_prop(network_manager, "last_connection_error")
	if status == "Disconnected" and last_connection_error is int and int(last_connection_error) != OK:
		parts.append("last_error=%s" % error_string(int(last_connection_error)))

	return "%s (%s)" % [status, ", ".join(parts)]


func _to_text(value: Variant) -> String:
	if value == null:
		return UNKNOWN_TEXT
	return str(value)


func _format_order_status(game_state: Node) -> String:
	var pending = _resolve_pending_orders()
	var completed = _to_int_or_na(_read_prop(game_state, "completed_orders"))
	var failed = _to_int_or_na(_read_prop(game_state, "failed_orders"))
	return "Orders: Pending %s  Completed %s  Failed %s" % [pending, completed, failed]


func _resolve_pending_orders() -> String:
	var order_manager := _resolve_order_manager()
	if order_manager == null:
		return UNKNOWN_TEXT

	if not _has_property(order_manager, "active_orders"):
		return UNKNOWN_TEXT

	var active_orders = order_manager.get("active_orders")
	if active_orders is Array:
		var pending_count := 0
		for order in active_orders:
			if order is Dictionary and not bool(order.get("is_completed", false)):
				pending_count += 1
		return str(pending_count)

	return UNKNOWN_TEXT


func _peer_count(network_manager: Node) -> int:
	var peers = _read_prop(network_manager, "connected_peers")
	if peers is Dictionary:
		return peers.size()
	return 0


func _to_int_or_na(value: Variant) -> String:
	if value == null:
		return UNKNOWN_TEXT
	if value is int:
		return str(value)
	return str(value)


func _format_phase(phase_value: Variant) -> String:
	if phase_value == null:
		return UNKNOWN_TEXT
	if phase_value is int:
		match int(phase_value):
			0:
				return "Lobby"
			1:
				return "Preparation"
			2:
				return "Working"
			3:
				return "Settlement"
			4:
				return "Paused"
	if phase_value is String and phase_value.is_valid_int():
		return _format_phase(int(phase_value))
	return _humanize_token(str(phase_value))


func _humanize_token(value: String) -> String:
	var words := value.replace("_", " ").replace("-", " ").split(" ", false)
	var humanized_words: Array[String] = []
	for word in words:
		humanized_words.append(word.capitalize())
	if humanized_words.is_empty():
		return value
	return " ".join(humanized_words)


func _resolve_order_manager() -> Node:
	if _order_manager != null and is_instance_valid(_order_manager):
		return _order_manager

	var tree := get_tree()
	if tree == null:
		return null

	_order_manager = tree.get_first_node_in_group("order_manager")
	return _order_manager


func _network_local_peer_id(network_manager: Node) -> int:
	if network_manager == null:
		return -1
	return network_manager.multiplayer.get_unique_id()


func _network_link_state(network_manager: Node) -> String:
	if network_manager == null:
		return ""
	var peer = network_manager.multiplayer.multiplayer_peer
	if peer == null:
		return "NoPeer"
	if not peer.has_method("get_connection_status"):
		return ""

	match int(peer.get_connection_status()):
		MultiplayerPeer.CONNECTION_DISCONNECTED:
			return "Disconnected"
		MultiplayerPeer.CONNECTION_CONNECTING:
			return "Connecting"
		MultiplayerPeer.CONNECTION_CONNECTED:
			return "Connected"
		_:
			return "Unknown"


func _has_property(node: Object, prop_name: StringName) -> bool:
	for property_info in node.get_property_list():
		if property_info.get("name", "") == String(prop_name):
			return true
	return false
