extends RefCounted

const HUD_SCENE := preload("res://scenes/ui/hud.tscn")
const WAREHOUSE_SCENE := preload("res://scenes/levels/warehouse_test.tscn")
const PACKAGE_SCENE := preload("res://scenes/entities/package.tscn")
const ORDER_MANAGER_SCRIPT := preload("res://src/systems/order_manager.gd")
const EVENT_BUS_SCRIPT := preload("res://src/autoload/event_bus.gd")

var _tree: SceneTree
var _failures: Array[String] = []
var _saved_game_state: Dictionary = {}
var _saved_network_state: Dictionary = {}


func run(tree: SceneTree) -> Array[String]:
	_tree = tree
	_failures.clear()
	_capture_global_state()

	await _test_hud_reflects_state_and_formats_labels()
	await _test_hud_order_status_falls_back_when_no_order_manager_exists()
	await _test_delivery_tracking_resets_when_session_requests_reset()
	await _test_apply_order_state_local_filters_and_copies_snapshot()

	_restore_global_state()
	return _failures


func _test_hud_reflects_state_and_formats_labels() -> void:
	_set_network_disconnected_baseline()

	var root := Node3D.new()
	root.name = "HudStateReflectionRoot"
	_tree.root.add_child(root)

	var manager = ORDER_MANAGER_SCRIPT.new()
	manager.name = "HudOrders"
	root.add_child(manager)
	await _tree.process_frame

	manager.clear_orders()
	manager.create_order("normal", "A")
	manager.create_order("fragile", "B")
	manager.complete_order("order_2")

	var game_state := _game_state()
	game_state.local_player_name = "Worker 4"
	game_state.current_phase = EVENT_BUS_SCRIPT.GamePhase.WORKING
	game_state.current_gold = 250
	game_state.current_score = 420
	game_state.completed_orders = 4
	game_state.failed_orders = 1

	var network_manager := _network_manager()
	network_manager.set("is_connected", true)
	network_manager.set("is_host", true)
	network_manager.set("is_connecting", false)
	network_manager.set("last_connection_error", int(OK))
	network_manager.set("connected_peers", {1: true, 2: true, 3: true})

	var hud = HUD_SCENE.instantiate()
	root.add_child(hud)
	await _tree.process_frame

	hud._refresh_labels()

	_assert(_label_text(hud, "PlayerLabel") == "Player: Worker 4", "HUD should reflect local player name")
	_assert(_label_text(hud, "PhaseLabel") == "Phase: Working", "HUD should humanize current phase value")
	_assert(_label_text(hud, "GoldLabel") == "Gold: 250", "HUD should reflect current gold")
	_assert(_label_text(hud, "ScoreLabel") == "Score: 420", "HUD should reflect current score")
	var network_label := _label_text(hud, "NetworkLabel")
	_assert(
		network_label.begins_with("Network: Connected (Host, peers=3, remote=2"),
		"HUD should format connected host network state with richer peer summary"
	)
	_assert(network_label.contains("link="), "HUD should include link state metadata")
	_assert(
		_label_text(hud, "OrdersLabel") == "Orders: Pending 1  Completed 4  Failed 1",
		"HUD should combine pending order scan with completed and failed counters"
	)

	root.queue_free()
	await _tree.process_frame


func _test_hud_order_status_falls_back_when_no_order_manager_exists() -> void:
	_set_network_disconnected_baseline()

	var root := Node3D.new()
	root.name = "HudNoOrderManagerRoot"
	_tree.root.add_child(root)

	var hud = HUD_SCENE.instantiate()
	root.add_child(hud)
	await _tree.process_frame

	var game_state := _game_state()
	game_state.completed_orders = 7
	game_state.failed_orders = 3
	hud._refresh_labels()
	_assert(
		_label_text(hud, "OrdersLabel") == "Orders: Pending N/A  Completed 7  Failed 3",
		"HUD should keep pending as N/A when no order manager exists in scene tree"
	)

	root.queue_free()
	await _tree.process_frame


func _test_delivery_tracking_resets_when_session_requests_reset() -> void:
	_set_network_disconnected_baseline()

	var session = WAREHOUSE_SCENE.instantiate()
	session.name = "SessionDeliveryReset"
	_tree.root.add_child(session)
	await _tree.process_frame
	await _tree.process_frame

	var zone = session.get_node("Gameplay/DeliveryZone")
	var package = session.get_node_or_null("Packages/package_1")
	if package == null:
		package = _find_first_package_in_session(session)
	if package == null:
		package = PACKAGE_SCENE.instantiate()
		package.name = "package_reset"
		package.package_id = "pkg_reset_001"
		package.package_type = "normal"
		session.get_node("Packages").add_child(package)
		await _tree.process_frame

	var manager = session.get_node("Gameplay/OrderManager")
	manager.clear_orders()
	manager.create_order("normal", "A")

	zone._on_body_entered(package)
	_assert(not zone._delivered_cache.is_empty(), "delivery should populate zone tracking cache before reset")

	session._reset_delivery_zone_state()
	_assert(zone._delivered_cache.is_empty(), "session reset_delivery_zone_state should clear delivery tracking cache")

	session.queue_free()
	await _tree.process_frame


func _test_apply_order_state_local_filters_and_copies_snapshot() -> void:
	_set_network_disconnected_baseline()

	var session = WAREHOUSE_SCENE.instantiate()
	session.name = "SessionOrderStateEdge"
	_tree.root.add_child(session)
	await _tree.process_frame

	var manager = session.get_node("Gameplay/OrderManager")
	var original_order := {
		"id": "remote_1",
		"package_type": "fragile",
		"destination": "B",
		"is_completed": false
	}
	var second_order := {
		"id": "remote_2",
		"package_type": "normal",
		"destination": "A",
		"is_completed": true
	}

	session._apply_order_state_local([original_order, "bad_entry", second_order], 5, 2, 80, 420)
	original_order["destination"] = "Z"
	second_order["is_completed"] = false

	_assert(manager.active_orders.size() == 2, "order sync should ignore non-dictionary entries")
	_assert(
		String(manager.active_orders[0].get("destination", "")) == "B",
		"order sync should deep-copy incoming dictionaries instead of keeping shared references"
	)
	_assert(
		bool(manager.active_orders[1].get("is_completed", false)),
		"order sync should preserve copied completion flag even when source snapshot mutates later"
	)
	_assert(_game_state().completed_orders == 5, "order sync should update completed_orders total")
	_assert(_game_state().failed_orders == 2, "order sync should update failed_orders total")
	_assert(_game_state().current_gold == 80, "order sync should update gold total")
	_assert(_game_state().current_score == 420, "order sync should update score total")
	_assert(
		int(_game_state().current_phase) == int(EVENT_BUS_SCRIPT.GamePhase.WORKING),
		"order sync should force phase to WORKING after applying snapshot"
	)

	session.queue_free()
	await _tree.process_frame


func _capture_global_state() -> void:
	var game_state := _game_state()
	_saved_game_state = {
		"current_phase": int(game_state.current_phase),
		"current_level": game_state.current_level,
		"local_player_id": game_state.local_player_id,
		"local_player_name": game_state.local_player_name,
		"current_gold": game_state.current_gold,
		"current_score": game_state.current_score,
		"completed_orders": game_state.completed_orders,
		"failed_orders": game_state.failed_orders
	}

	var network_manager := _network_manager()
	_saved_network_state = {
		"is_host": network_manager.is_host,
		"is_connected": network_manager.is_connected,
		"is_connecting": network_manager.is_connecting,
		"connection_state": network_manager.connection_state,
		"last_connection_error": int(network_manager.last_connection_error),
		"connected_peers": network_manager.connected_peers.duplicate(true)
	}


func _restore_global_state() -> void:
	var game_state := _game_state()
	game_state.current_phase = _saved_game_state.get("current_phase", int(EVENT_BUS_SCRIPT.GamePhase.LOBBY))
	game_state.current_level = String(_saved_game_state.get("current_level", ""))
	game_state.local_player_id = int(_saved_game_state.get("local_player_id", -1))
	game_state.local_player_name = String(_saved_game_state.get("local_player_name", "Player"))
	game_state.current_gold = int(_saved_game_state.get("current_gold", 0))
	game_state.current_score = int(_saved_game_state.get("current_score", 0))
	game_state.completed_orders = int(_saved_game_state.get("completed_orders", 0))
	game_state.failed_orders = int(_saved_game_state.get("failed_orders", 0))

	var network_manager := _network_manager()
	network_manager.set("is_host", bool(_saved_network_state.get("is_host", false)))
	network_manager.set("is_connected", bool(_saved_network_state.get("is_connected", false)))
	network_manager.set("is_connecting", bool(_saved_network_state.get("is_connecting", false)))
	network_manager.set("connection_state", int(_saved_network_state.get("connection_state", 0)))
	network_manager.set("last_connection_error", int(_saved_network_state.get("last_connection_error", int(OK))))
	network_manager.set("connected_peers", _saved_network_state.get("connected_peers", {}).duplicate(true))


func _set_network_disconnected_baseline() -> void:
	var network_manager := _network_manager()
	network_manager.set("is_host", false)
	network_manager.set("is_connected", false)
	network_manager.set("is_connecting", false)
	network_manager.set("connection_state", 0)
	network_manager.set("last_connection_error", int(OK))
	network_manager.set("connected_peers", {})


func _label_text(hud: Node, label_name: String) -> String:
	var label := hud.get_node("Panel/Content/%s" % label_name) as Label
	if label == null:
		return ""
	return label.text


func _find_first_package_in_session(session: Node) -> Node:
	for node in _tree.get_nodes_in_group("packages"):
		if node is Node and session.is_ancestor_of(node):
			return node
	return null


func _game_state() -> Node:
	return _tree.root.get_node("GameState")


func _network_manager() -> Node:
	return _tree.root.get_node("NetworkManager")


func _assert(condition: bool, message: String) -> void:
	if condition:
		return
	_failures.append(message)
