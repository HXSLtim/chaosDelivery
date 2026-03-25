extends CanvasLayer

const HUD_NETWORK_FORMATTER := preload("res://src/ui/hud_network_formatter.gd")
const HUD_SIGNAL_BINDER := preload("res://src/ui/hud_signal_binder.gd")

const UNKNOWN_TEXT := "N/A"
const PROTOTYPE_CONTROLS_TEXT := "Controls: Mouse Look  WASD Move  E Grab/Drop  F Throw  Esc Cursor"
const NETWORK_CONTROLS_TEXT := "Network: F5 Host LAN  F6 Join localhost  F7 Leave"

@onready var _player_label: Label = $Panel/Content/PlayerLabel
@onready var _phase_label: Label = $Panel/Content/PhaseLabel
@onready var _gold_label: Label = $Panel/Content/GoldLabel
@onready var _score_label: Label = $Panel/Content/ScoreLabel
@onready var _network_label: Label = $Panel/Content/NetworkLabel
@onready var _network_detail_label: Label = $Panel/Content/NetworkDetailLabel
@onready var _orders_label: Label = $Panel/Content/OrdersLabel
@onready var _delivery_feedback_label: Label = $Panel/Content/DeliveryFeedbackLabel
@onready var _controls_label: Label = $Panel/Content/ControlsLabel
@onready var _network_controls_label: Label = $Panel/Content/NetworkControlsLabel

var _refresh_interval: float = 0.2
var _refresh_timer: float = 0.0
var _order_manager: Node = null
var _event_bus: Node = null
var _game_state: Node = null
var _network_manager: Node = null
var _pending_orders_hint: int = -1
var _last_delivery_feedback: String = "Delivery: Waiting for first result."
var _last_completed_orders: int = -1
var _last_failed_orders: int = -1
var _bound_event_bus: Node = null
var _bound_order_manager: Node = null


func _ready() -> void:
	_bind_tree_signals()
	_resolve_and_bind_dependencies()
	_refresh_labels()


func _process(delta: float) -> void:
	_refresh_timer -= delta
	if _refresh_timer > 0.0:
		return

	_refresh_timer = _refresh_interval
	_resolve_and_bind_dependencies()
	_refresh_labels()


func _exit_tree() -> void:
	var tree := get_tree()
	if tree != null and tree.node_added.is_connected(_on_tree_node_added):
		tree.node_added.disconnect(_on_tree_node_added)
	_rebind_event_bus(null)
	_rebind_order_manager(null)


func _refresh_labels() -> void:
	var game_state := _game_state
	if game_state == null or not is_instance_valid(game_state):
		game_state = get_node_or_null("/root/GameState")
		_game_state = game_state

	var network_manager := _network_manager
	if network_manager == null or not is_instance_valid(network_manager):
		network_manager = get_node_or_null("/root/NetworkManager")
		_network_manager = network_manager

	_player_label.text = "Player: %s" % _to_text(_read_prop(game_state, "local_player_name"))
	_phase_label.text = "Phase: %s" % _format_phase(_read_prop(game_state, "current_phase"))
	_gold_label.text = "Gold: %s" % _to_text(_read_prop(game_state, "current_gold"))
	_score_label.text = "Score: %s" % _to_text(_read_prop(game_state, "current_score"))
	_network_label.text = "Network: %s" % _format_network_status(network_manager)
	_network_detail_label.text = _format_network_detail(network_manager)
	_orders_label.text = _format_order_status(game_state)
	_delivery_feedback_label.text = _format_delivery_feedback(game_state)
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
	var connection_state := _network_link_state(network_manager)
	var local_peer_id := _network_local_peer_id(network_manager)
	var is_connecting = _read_prop(network_manager, "is_connecting")
	var last_connection_error = _read_prop(network_manager, "last_connection_error")
	return HUD_NETWORK_FORMATTER.format_status(
		connected,
		host,
		peer_count,
		local_peer_id,
		connection_state,
		is_connecting,
		last_connection_error
	)


func _to_text(value: Variant) -> String:
	if value == null:
		return UNKNOWN_TEXT
	return str(value)


func _format_order_status(game_state: Node) -> String:
	var pending = _resolve_pending_orders()
	var completed = _to_int_or_na(_read_prop(game_state, "completed_orders"))
	var failed = _to_int_or_na(_read_prop(game_state, "failed_orders"))
	return "Orders: Pending %s  Completed %s  Failed %s" % [pending, completed, failed]


func _format_delivery_feedback(game_state: Node) -> String:
	var explicit_feedback := _read_delivery_feedback(game_state)
	if not explicit_feedback.is_empty():
		var explicit_message := _non_empty_text(explicit_feedback.get("message", null))
		var explicit_order_id := _non_empty_text(explicit_feedback.get("order_id", null))
		var next_pending := _describe_next_pending_order()
		if explicit_order_id != UNKNOWN_TEXT:
			return "Delivery: %s (%s)  Next: %s" % [explicit_message, explicit_order_id, next_pending]
		return "Delivery: %s  Next: %s" % [explicit_message, next_pending]

	var completed := _read_count(game_state, "completed_orders")
	var failed := _read_count(game_state, "failed_orders")
	_update_delivery_outcome_feedback(completed, failed)
	var next_pending := _describe_next_pending_order()
	return "%s  Next: %s" % [_last_delivery_feedback, next_pending]


func _format_network_detail(network_manager: Node) -> String:
	if network_manager == null:
		return "Net Detail: NetworkManager missing. F5 host / F6 join localhost."

	var connected = _read_prop(network_manager, "is_connected")
	var host = _read_prop(network_manager, "is_host")
	var is_connecting = _read_prop(network_manager, "is_connecting")
	var peer_count := _peer_count(network_manager)
	var state_name := _network_connection_state_name(_read_prop(network_manager, "connection_state"))
	var last_error = _read_prop(network_manager, "last_connection_error")
	return HUD_NETWORK_FORMATTER.format_detail(
		connected,
		host,
		peer_count,
		state_name,
		is_connecting,
		last_error
	)


func _resolve_pending_orders() -> String:
	var order_manager := _resolve_order_manager()
	if order_manager == null:
		_pending_orders_hint = -1
		return UNKNOWN_TEXT

	if order_manager.has_method("get_pending_order_count"):
		var pending_value: Variant = order_manager.call("get_pending_order_count")
		if pending_value is int:
			_pending_orders_hint = int(pending_value)
			return str(_pending_orders_hint)
		if pending_value is float:
			_pending_orders_hint = int(pending_value)
			return str(_pending_orders_hint)

	if not _has_property(order_manager, "active_orders"):
		if _pending_orders_hint >= 0:
			return str(_pending_orders_hint)
		return UNKNOWN_TEXT

	var active_orders = order_manager.get("active_orders")
	if active_orders is Array:
		var pending_count := 0
		for order in active_orders:
			if order is Dictionary and not bool(order.get("is_completed", false)):
				pending_count += 1
		_pending_orders_hint = pending_count
		return str(pending_count)

	if _pending_orders_hint >= 0:
		return str(_pending_orders_hint)

	return UNKNOWN_TEXT


func _describe_next_pending_order() -> String:
	var order_manager := _resolve_order_manager()
	if order_manager == null:
		if _pending_orders_hint == 0:
			return "None"
		if _pending_orders_hint > 0:
			return "%d pending" % _pending_orders_hint
		return UNKNOWN_TEXT

	var pending_order := _read_first_pending_order(order_manager)
	if pending_order.is_empty():
		var pending_count_text := _resolve_pending_orders()
		if pending_count_text == "0":
			return "None"
		if pending_count_text == UNKNOWN_TEXT:
			return UNKNOWN_TEXT
		return "%s pending" % pending_count_text

	var package_type := _non_empty_text(pending_order.get("package_type", null))
	var destination := _non_empty_text(pending_order.get("destination", null))
	var order_id := _non_empty_text(pending_order.get("id", null))
	return "%s -> %s (%s)" % [package_type, destination, order_id]


func _read_first_pending_order(order_manager: Node) -> Dictionary:
	if order_manager == null:
		return {}
	if order_manager.has_method("get_first_pending_order"):
		var first_pending: Variant = order_manager.call("get_first_pending_order")
		if first_pending is Dictionary:
			return first_pending
	if _has_property(order_manager, "active_orders"):
		var active_orders = order_manager.get("active_orders")
		if active_orders is Array:
			for order in active_orders:
				if order is Dictionary and not bool(order.get("is_completed", false)):
					return order
	return {}


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


func _read_count(node: Node, prop: StringName) -> int:
	var value: Variant = _read_prop(node, prop)
	if value is int:
		return int(value)
	if value is float:
		return int(value)
	if value is String and String(value).is_valid_int():
		return int(value)
	return -1


func _non_empty_text(value: Variant) -> String:
	if value == null:
		return UNKNOWN_TEXT
	var text := str(value).strip_edges()
	if text == "":
		return UNKNOWN_TEXT
	return text


func _update_delivery_outcome_feedback(completed: int, failed: int) -> void:
	if completed < 0 or failed < 0:
		return

	if _last_completed_orders < 0 or _last_failed_orders < 0:
		_last_completed_orders = completed
		_last_failed_orders = failed
		if completed == 0 and failed == 0:
			_last_delivery_feedback = "Delivery: Waiting for first result."
		else:
			_last_delivery_feedback = "Delivery: Session totals synced."
		return

	var completed_delta := completed - _last_completed_orders
	var failed_delta := failed - _last_failed_orders
	if completed_delta > 0 and failed_delta > 0:
		_last_delivery_feedback = "Delivery: Mixed updates (+%d completed, +%d failed)." % [completed_delta, failed_delta]
	elif completed_delta > 0:
		_last_delivery_feedback = "Delivery: Success (+%d completed)." % completed_delta
	elif failed_delta > 0:
		_last_delivery_feedback = "Delivery: Rejected (+%d failed)." % failed_delta
	elif completed_delta < 0 or failed_delta < 0:
		_last_delivery_feedback = "Delivery: Counters reset."

	_last_completed_orders = completed
	_last_failed_orders = failed


func _network_connection_state_name(state_value: Variant) -> String:
	return HUD_NETWORK_FORMATTER.connection_state_name(state_value)


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
	return HUD_NETWORK_FORMATTER.humanize_token(value)


func _resolve_order_manager() -> Node:
	if _order_manager != null and is_instance_valid(_order_manager):
		return _order_manager

	var tree := get_tree()
	if tree == null:
		return null

	_order_manager = tree.get_first_node_in_group("order_manager")
	_update_pending_orders_hint(_order_manager)
	return _order_manager


func _network_local_peer_id(network_manager: Node) -> int:
	if network_manager == null:
		return -1
	if network_manager.has_method("get_local_peer_slot"):
		var local_slot_value: Variant = network_manager.call("get_local_peer_slot")
		if local_slot_value is int:
			return int(local_slot_value)
		if local_slot_value is float:
			return int(local_slot_value)
	var multiplayer_api: Variant = _get_multiplayer_api(network_manager)
	if multiplayer_api == null:
		return -1
	if multiplayer_api.multiplayer_peer == null:
		return -1
	return multiplayer_api.get_unique_id()


func _network_link_state(network_manager: Node) -> String:
	if network_manager == null:
		return ""
	var multiplayer_api: Variant = _get_multiplayer_api(network_manager)
	if multiplayer_api == null:
		return ""
	var peer = multiplayer_api.multiplayer_peer
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


func _get_multiplayer_api(node: Node):
	if node == null or not node.has_method("get_multiplayer"):
		return null
	return node.get_multiplayer()


func _bind_tree_signals() -> void:
	var tree := get_tree()
	if tree == null:
		return
	if not tree.node_added.is_connected(_on_tree_node_added):
		tree.node_added.connect(_on_tree_node_added)


func _resolve_and_bind_dependencies() -> void:
	_game_state = get_node_or_null("/root/GameState")
	_network_manager = get_node_or_null("/root/NetworkManager")
	_rebind_event_bus(get_node_or_null("/root/EventBus"))
	_order_manager = _resolve_order_manager()
	_update_pending_orders_hint(_order_manager)
	_rebind_order_manager(_order_manager)


func _bind_event_bus_signals(event_bus: Node) -> void:
	_bound_event_bus = HUD_SIGNAL_BINDER.rebind(_bound_event_bus, event_bus, _event_bus_signal_specs())
	_event_bus = _bound_event_bus


func _bind_order_manager_signals(order_manager: Node) -> void:
	_bound_order_manager = HUD_SIGNAL_BINDER.rebind(_bound_order_manager, order_manager, _order_manager_signal_specs())
	_order_manager = _bound_order_manager


func _on_tree_node_added(node: Node) -> void:
	if node == null:
		return
	if not node.is_in_group("order_manager"):
		return
	_order_manager = node
	_rebind_order_manager(_order_manager)
	_update_pending_orders_hint(_order_manager)
	_refresh_labels()


func _on_phase_changed(_new_phase: int, _old_phase: int) -> void:
	_refresh_labels()


func _on_network_state_changed(_is_connected: bool, _is_host: bool) -> void:
	_refresh_labels()


func _on_player_roster_changed(_peer_id: int) -> void:
	_refresh_labels()


func _on_order_event_changed(_order_id: String) -> void:
	_refresh_labels()


func _on_local_player_profile_changed(_player_id: int, _player_name: String) -> void:
	_refresh_labels()


func _on_session_totals_changed(_completed_orders: int, _failed_orders: int, _gold: int, _score: int) -> void:
	_refresh_labels()


func _on_delivery_feedback_changed(_status: String, _message: String, _package_id: String, _order_id: String) -> void:
	_refresh_labels()


func _on_order_manager_orders_changed(reason: String, order_id: String, pending_count: int, _total_count: int) -> void:
	_pending_orders_hint = pending_count
	if reason == "created":
		_last_delivery_feedback = "Delivery: New order received."
	elif reason == "completed":
		_last_delivery_feedback = "Delivery: Order delivered (%s)." % _non_empty_text(order_id)
	elif reason == "cleared":
		_last_delivery_feedback = "Delivery: Orders cleared."
	_refresh_labels()


func _on_order_manager_pending_count_changed(pending_count: int) -> void:
	_pending_orders_hint = pending_count
	_refresh_labels()


func _on_order_manager_order_created(_order_id: String, _order: Dictionary) -> void:
	_update_pending_orders_hint(_order_manager)
	_refresh_labels()


func _on_order_manager_order_marked_completed(_order_id: String, _order: Dictionary) -> void:
	_update_pending_orders_hint(_order_manager)
	_refresh_labels()


func _on_order_manager_orders_cleared() -> void:
	_pending_orders_hint = 0
	_refresh_labels()


func _on_order_manager_changed(_payload: Variant = null) -> void:
	_update_pending_orders_hint(_order_manager)
	_refresh_labels()


func _update_pending_orders_hint(order_manager: Node) -> void:
	if order_manager == null:
		_pending_orders_hint = -1
		return
	if order_manager.has_method("get_pending_order_count"):
		var pending_value: Variant = order_manager.call("get_pending_order_count")
		if pending_value is int:
			_pending_orders_hint = int(pending_value)
			return
		if pending_value is float:
			_pending_orders_hint = int(pending_value)
			return
	if _has_property(order_manager, "active_orders"):
		var active_orders = order_manager.get("active_orders")
		if active_orders is Array:
			var pending_count := 0
			for order in active_orders:
				if order is Dictionary and not bool(order.get("is_completed", false)):
					pending_count += 1
			_pending_orders_hint = pending_count
			return
	_pending_orders_hint = -1


func _rebind_event_bus(event_bus: Node) -> void:
	_bind_event_bus_signals(event_bus)


func _rebind_order_manager(order_manager: Node) -> void:
	_bind_order_manager_signals(order_manager)


func _disconnect_event_bus_signals(event_bus: Node) -> void:
	_bound_event_bus = HUD_SIGNAL_BINDER.rebind(event_bus, null, _event_bus_signal_specs())
	_event_bus = _bound_event_bus


func _disconnect_order_manager_signals(order_manager: Node) -> void:
	_bound_order_manager = HUD_SIGNAL_BINDER.rebind(order_manager, null, _order_manager_signal_specs())
	_order_manager = _bound_order_manager


func _event_bus_signal_specs() -> Array[Dictionary]:
	return [
		{"signal_name": &"phase_changed", "callable": Callable(self, "_on_phase_changed")},
		{"signal_name": &"network_state_changed", "callable": Callable(self, "_on_network_state_changed")},
		{"signal_name": &"player_joined", "callable": Callable(self, "_on_player_roster_changed")},
		{"signal_name": &"player_left", "callable": Callable(self, "_on_player_roster_changed")},
		{"signal_name": &"order_added", "callable": Callable(self, "_on_order_event_changed")},
		{"signal_name": &"order_completed", "callable": Callable(self, "_on_order_event_changed")},
		{"signal_name": &"local_player_profile_changed", "callable": Callable(self, "_on_local_player_profile_changed")},
		{"signal_name": &"session_totals_changed", "callable": Callable(self, "_on_session_totals_changed")},
		{"signal_name": &"delivery_feedback_changed", "callable": Callable(self, "_on_delivery_feedback_changed")}
	]


func _order_manager_signal_specs() -> Array[Dictionary]:
	return [
		{"signal_name": &"orders_changed", "callable": Callable(self, "_on_order_manager_orders_changed")},
		{"signal_name": &"pending_count_changed", "callable": Callable(self, "_on_order_manager_pending_count_changed")},
		{"signal_name": &"order_created", "callable": Callable(self, "_on_order_manager_order_created")},
		{"signal_name": &"order_marked_completed", "callable": Callable(self, "_on_order_manager_order_marked_completed")},
		{"signal_name": &"orders_cleared", "callable": Callable(self, "_on_order_manager_orders_cleared")},
		{"signal_name": &"order_added", "callable": Callable(self, "_on_order_event_changed")},
		{"signal_name": &"order_completed", "callable": Callable(self, "_on_order_event_changed")}
	]


func _read_delivery_feedback(game_state: Node) -> Dictionary:
	if game_state == null:
		return {}
	if game_state.has_method("get_delivery_feedback"):
		var feedback_value: Variant = game_state.call("get_delivery_feedback")
		if feedback_value is Dictionary:
			var message := _non_empty_text(feedback_value.get("message", null))
			if message != UNKNOWN_TEXT:
				return feedback_value
	return {}
