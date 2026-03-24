extends CanvasLayer

const HUD_NETWORK_FORMATTER := preload("res://src/ui/hud_network_formatter.gd")

const TOGGLE_KEY := KEY_F8
const REFRESH_INTERVAL := 0.2  # 控制台只面向开发调试，5Hz 刷新足够且不会制造多余噪音。

@onready var _snapshot_label: Label = $Panel/Content/SnapshotLabel

var _refresh_timer: float = 0.0


func _ready() -> void:
	visible = false
	_refresh_console()


func _process(delta: float) -> void:
	if not visible:
		return

	_refresh_timer -= delta
	if _refresh_timer > 0.0:
		return

	_refresh_timer = REFRESH_INTERVAL
	_refresh_console()


func _unhandled_input(event: InputEvent) -> void:
	if event is not InputEventKey:
		return
	if not event.pressed or event.echo:
		return
	if event.keycode != TOGGLE_KEY:
		return
	_toggle_console()


func _toggle_console() -> void:
	visible = not visible
	_refresh_timer = 0.0
	if visible:
		_refresh_console()


func _refresh_console() -> void:
	if _snapshot_label == null:
		return
	_snapshot_label.text = "\n".join(_build_snapshot_lines())


func _build_snapshot_lines() -> Array[String]:
	var lines: Array[String] = [
		"Developer Console",
		"Toggle: F8"
	]

	var game_state := get_node_or_null("/root/GameState")
	var network_manager := get_node_or_null("/root/NetworkManager")
	var session := _resolve_session()

	lines.append("Phase: %s" % _format_phase(game_state))
	lines.append("Network: %s" % _format_network_status(network_manager))
	lines.append("Players: %d" % _count_group_nodes("players"))
	lines.append("Packages: %d" % _count_group_nodes("packages"))
	lines.append("Pending Orders: %s" % _pending_orders_text(session))

	if game_state != null:
		lines.append("Gold: %d  Score: %d" % [int(game_state.get("current_gold")), int(game_state.get("current_score"))])

	return lines


func _format_phase(game_state: Node) -> String:
	if game_state == null:
		return "N/A"
	var phase_value: Variant = game_state.get("current_phase")
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
	return HUD_NETWORK_FORMATTER.humanize_token(str(phase_value))


func _format_network_status(network_manager: Node) -> String:
	if network_manager == null:
		return "Offline"

	var connected = network_manager.get("is_connected")
	var host = network_manager.get("is_host")
	var is_connecting = network_manager.get("is_connecting")
	var last_error = network_manager.get("last_connection_error")
	var local_peer_id := -1
	if network_manager.has_method("get_local_peer_slot"):
		local_peer_id = int(network_manager.call("get_local_peer_slot"))

	var peer_count := 0
	var peers = network_manager.get("connected_peers")
	if peers is Dictionary:
		peer_count = peers.size()

	var link_state := ""
	var multiplayer_api = network_manager.get_multiplayer()
	if multiplayer_api != null and multiplayer_api.multiplayer_peer != null and multiplayer_api.multiplayer_peer.has_method("get_connection_status"):
		link_state = HUD_NETWORK_FORMATTER.connection_state_name(int(multiplayer_api.multiplayer_peer.get_connection_status()))

	return HUD_NETWORK_FORMATTER.format_status(
		connected,
		host,
		peer_count,
		local_peer_id,
		link_state,
		is_connecting,
		last_error
	)


func _pending_orders_text(session: Node) -> String:
	if session == null:
		return "N/A"
	var order_manager := session.get_node_or_null("Gameplay/OrderManager")
	if order_manager == null or not order_manager.has_method("get_pending_order_count"):
		return "N/A"
	return str(order_manager.call("get_pending_order_count"))


func _count_group_nodes(group_name: StringName) -> int:
	var tree := get_tree()
	if tree == null:
		return 0

	var count := 0
	for node in tree.get_nodes_in_group(group_name):
		if node is Node and node.is_inside_tree():
			count += 1
	return count


func _resolve_session() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	for node in tree.get_nodes_in_group("warehouse_session"):
		if node is Node and node.is_inside_tree():
			return node
	return null
