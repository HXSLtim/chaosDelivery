extends CanvasLayer

const UNKNOWN_TEXT := "N/A"
const PROTOTYPE_CONTROLS_TEXT := "Controls: WASD Move  E Grab/Drop  F Throw"
const NETWORK_CONTROLS_TEXT := "Network: F5 Host LAN  F6 Join localhost  F7 Leave"

@onready var _player_label: Label = $Panel/Content/PlayerLabel
@onready var _phase_label: Label = $Panel/Content/PhaseLabel
@onready var _gold_label: Label = $Panel/Content/GoldLabel
@onready var _network_label: Label = $Panel/Content/NetworkLabel
@onready var _orders_label: Label = $Panel/Content/OrdersLabel
@onready var _controls_label: Label = $Panel/Content/ControlsLabel
@onready var _network_controls_label: Label = $Panel/Content/NetworkControlsLabel

var _refresh_interval: float = 0.2
var _refresh_timer: float = 0.0


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
	_phase_label.text = "Phase: %s" % _to_text(_read_prop(game_state, "current_phase"))
	_gold_label.text = "Gold: %s" % _to_text(_read_prop(game_state, "current_gold"))
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
	var peer_count = _peer_count(network_manager)

	if connected == null:
		return "Unknown (Missing is_connected)"
	if host == null:
		return "Connected (Role Unknown, peers=%d)" % peer_count

	if connected == true and host == true:
		return "Connected (Host, peers=%d)" % peer_count
	if connected == true:
		return "Connected (Client, peers=%d)" % peer_count
	return "Disconnected"


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
	var root := get_tree().root
	if root == null:
		return UNKNOWN_TEXT

	for node in root.find_children("*", "Node", true, false):
		if _has_property(node, "active_orders"):
			var active_orders = node.get("active_orders")
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


func _has_property(node: Object, prop_name: StringName) -> bool:
	for property_info in node.get_property_list():
		if property_info.get("name", "") == String(prop_name):
			return true
	return false
