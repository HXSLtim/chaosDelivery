extends RefCounted

const HUD_SCENE := preload("res://scenes/ui/hud.tscn")
const WAREHOUSE_SCENE := preload("res://scenes/levels/warehouse_test.tscn")

var _tree: SceneTree
var _failures: Array[String] = []
var _saved_game_state: Dictionary = {}


func run(tree: SceneTree) -> Array[String]:
	_tree = tree
	_failures.clear()
	_capture_game_state()

	await _test_game_state_emits_profile_and_totals_signals()
	await _test_game_state_emits_delivery_feedback_signal()
	await _test_hud_refreshes_immediately_when_game_state_changes()
	await _test_session_spawn_emits_local_player_profile_signal()
	await _test_session_profile_signal_uses_stable_slot_labels_for_remote_peers()
	await _test_session_profile_signal_keeps_host_on_slot_one_when_remote_peers_exist()

	_restore_game_state()
	return _failures


func _test_game_state_emits_profile_and_totals_signals() -> void:
	var event_bus := _event_bus()
	var game_state := _game_state()

	_assert(event_bus != null, "EventBus should exist for game-state signal tests")
	_assert(event_bus != null and event_bus.has_signal("local_player_profile_changed"), "EventBus should expose local_player_profile_changed")
	_assert(event_bus != null and event_bus.has_signal("session_totals_changed"), "EventBus should expose session_totals_changed")
	_assert(game_state.has_method("set_local_player_profile"), "GameState should expose set_local_player_profile")
	_assert(game_state.has_method("set_session_totals"), "GameState should expose set_session_totals")
	if event_bus == null or not game_state.has_method("set_local_player_profile") or not game_state.has_method("set_session_totals"):
		return

	var profile_events: Array[Dictionary] = []
	var totals_events: Array[Dictionary] = []
	var on_profile := func(player_id: int, player_name: String) -> void:
		profile_events.append({"id": player_id, "name": player_name})
	var on_totals := func(completed_orders: int, failed_orders: int, gold: int, score: int) -> void:
		totals_events.append({
			"completed": completed_orders,
			"failed": failed_orders,
			"gold": gold,
			"score": score
		})

	event_bus.local_player_profile_changed.connect(on_profile)
	event_bus.session_totals_changed.connect(on_totals)

	game_state.set_local_player_profile(9, "Signal Tester")
	game_state.set_session_totals(3, 1, 120, 450)

	_assert(profile_events == [{"id": 9, "name": "Signal Tester"}], "profile signal should emit one event with latest profile")
	_assert(
		totals_events == [{"completed": 3, "failed": 1, "gold": 120, "score": 450}],
		"totals signal should emit one event with latest totals"
	)

	if event_bus.local_player_profile_changed.is_connected(on_profile):
		event_bus.local_player_profile_changed.disconnect(on_profile)
	if event_bus.session_totals_changed.is_connected(on_totals):
		event_bus.session_totals_changed.disconnect(on_totals)


func _test_game_state_emits_delivery_feedback_signal() -> void:
	var event_bus := _event_bus()
	var game_state := _game_state()

	_assert(event_bus != null and event_bus.has_signal("delivery_feedback_changed"), "EventBus should expose delivery_feedback_changed")
	_assert(game_state.has_method("set_delivery_feedback"), "GameState should expose set_delivery_feedback")
	_assert(game_state.has_method("clear_delivery_feedback"), "GameState should expose clear_delivery_feedback")
	if event_bus == null or not event_bus.has_signal("delivery_feedback_changed") or not game_state.has_method("set_delivery_feedback"):
		return

	var feedback_events: Array[Dictionary] = []
	var on_feedback := func(status: String, message: String, package_id: String, order_id: String) -> void:
		feedback_events.append({
			"status": status,
			"message": message,
			"package_id": package_id,
			"order_id": order_id
		})

	event_bus.delivery_feedback_changed.connect(on_feedback)

	game_state.set_delivery_feedback("success", "Delivered package.", "pkg_001", "order_123")

	_assert(
		feedback_events == [{
			"status": "success",
			"message": "Delivered package.",
			"package_id": "pkg_001",
			"order_id": "order_123"
		}],
		"delivery feedback signal should emit the latest explicit feedback payload"
	)

	if game_state.has_method("clear_delivery_feedback"):
		game_state.clear_delivery_feedback()

	if event_bus.delivery_feedback_changed.is_connected(on_feedback):
		event_bus.delivery_feedback_changed.disconnect(on_feedback)


func _test_hud_refreshes_immediately_when_game_state_changes() -> void:
	_reset_network_baseline()

	var root := Node3D.new()
	root.name = "HudImmediateRefreshRoot"
	_tree.root.add_child(root)

	var hud = HUD_SCENE.instantiate()
	root.add_child(hud)
	await _tree.process_frame

	var game_state := _game_state()
	_assert(game_state.has_method("set_local_player_profile"), "GameState should expose set_local_player_profile for HUD refresh")
	_assert(game_state.has_method("set_session_totals"), "GameState should expose set_session_totals for HUD refresh")
	if not game_state.has_method("set_local_player_profile") or not game_state.has_method("set_session_totals"):
		root.queue_free()
		await _tree.process_frame
		return

	game_state.set_local_player_profile(5, "Immediate HUD")
	game_state.set_session_totals(2, 1, 90, 180)

	_assert(_label_text(hud, "PlayerLabel") == "Player: Immediate HUD", "HUD should refresh player label immediately from profile signal")
	_assert(_label_text(hud, "GoldLabel") == "Gold: 90", "HUD should refresh gold immediately from totals signal")
	_assert(_label_text(hud, "ScoreLabel") == "Score: 180", "HUD should refresh score immediately from totals signal")
	_assert(_label_text(hud, "OrdersLabel") == "Orders: Pending N/A  Completed 2  Failed 1", "HUD should refresh totals immediately without waiting for polling")

	root.queue_free()
	await _tree.process_frame


func _test_session_spawn_emits_local_player_profile_signal() -> void:
	_reset_network_baseline()

	var event_bus := _event_bus()
	_assert(event_bus != null, "EventBus should exist for session profile signal test")
	_assert(event_bus != null and event_bus.has_signal("local_player_profile_changed"), "EventBus should expose local_player_profile_changed for session integration")
	if event_bus == null or not event_bus.has_signal("local_player_profile_changed"):
		return

	var profile_events: Array[Dictionary] = []
	var on_profile := func(player_id: int, player_name: String) -> void:
		profile_events.append({"id": player_id, "name": player_name})
	event_bus.local_player_profile_changed.connect(on_profile)

	var session = WAREHOUSE_SCENE.instantiate()
	session.name = "SessionProfileSignal"
	_tree.root.add_child(session)
	await _tree.process_frame
	await _tree.process_frame

	_assert(not profile_events.is_empty(), "warehouse session spawn should emit local player profile change")
	if not profile_events.is_empty():
		_assert(profile_events[-1] == {"id": 1, "name": "Player 1"}, "session profile signal should describe the spawned offline player")

	if event_bus.local_player_profile_changed.is_connected(on_profile):
		event_bus.local_player_profile_changed.disconnect(on_profile)

	session.queue_free()
	await _tree.process_frame


func _test_session_profile_signal_uses_stable_slot_labels_for_remote_peers() -> void:
	_reset_network_baseline()

	var event_bus := _event_bus()
	var network_manager := _tree.root.get_node_or_null("NetworkManager")
	_assert(event_bus != null and network_manager != null, "EventBus and NetworkManager should exist for stable slot profile signal test")
	if event_bus == null or network_manager == null:
		return

	network_manager.connected_peers = {
		1: true,
		1096654874: true
	}

	var profile_events: Array[Dictionary] = []
	var on_profile := func(player_id: int, player_name: String) -> void:
		profile_events.append({"id": player_id, "name": player_name})
	event_bus.local_player_profile_changed.connect(on_profile)

	var session = WAREHOUSE_SCENE.instantiate()
	session.name = "SessionStableSlotProfileSignal"
	_tree.root.add_child(session)
	await _tree.process_frame
	await _tree.process_frame

	session._update_local_player_profile(1096654874)

	_assert(
		not profile_events.is_empty() and profile_events[-1] == {"id": 2, "name": "Player 2"},
		"session profile signal should map large remote peer ids to stable slot labels"
	)

	if event_bus.local_player_profile_changed.is_connected(on_profile):
		event_bus.local_player_profile_changed.disconnect(on_profile)

	session.queue_free()
	await _tree.process_frame


func _test_session_profile_signal_keeps_host_on_slot_one_when_remote_peers_exist() -> void:
	_reset_network_baseline()

	var event_bus := _event_bus()
	var network_manager := _tree.root.get_node_or_null("NetworkManager")
	_assert(event_bus != null and network_manager != null, "EventBus and NetworkManager should exist for host slot stability test")
	if event_bus == null or network_manager == null:
		return

	network_manager.connected_peers = {
		2147483640: true,
		1: true,
		1096654874: true
	}

	var profile_events: Array[Dictionary] = []
	var on_profile := func(player_id: int, player_name: String) -> void:
		profile_events.append({"id": player_id, "name": player_name})
	event_bus.local_player_profile_changed.connect(on_profile)

	var session = WAREHOUSE_SCENE.instantiate()
	session.name = "SessionHostSlotOneProfileSignal"
	_tree.root.add_child(session)
	await _tree.process_frame
	await _tree.process_frame

	session._update_local_player_profile(1)

	_assert(
		not profile_events.is_empty() and profile_events[-1] == {"id": 1, "name": "Player 1"},
		"host profile signal should stay on stable slot P1 even when remote peers are present"
	)

	if event_bus.local_player_profile_changed.is_connected(on_profile):
		event_bus.local_player_profile_changed.disconnect(on_profile)

	session.queue_free()
	await _tree.process_frame


func _capture_game_state() -> void:
	_reset_network_baseline()

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


func _restore_game_state() -> void:
	var game_state := _game_state()
	game_state.current_phase = _saved_game_state.get("current_phase", 0)
	game_state.current_level = String(_saved_game_state.get("current_level", ""))
	game_state.local_player_id = int(_saved_game_state.get("local_player_id", -1))
	game_state.local_player_name = String(_saved_game_state.get("local_player_name", "Player"))
	game_state.current_gold = int(_saved_game_state.get("current_gold", 0))
	game_state.current_score = int(_saved_game_state.get("current_score", 0))
	game_state.completed_orders = int(_saved_game_state.get("completed_orders", 0))
	game_state.failed_orders = int(_saved_game_state.get("failed_orders", 0))

	var network_manager := _tree.root.get_node_or_null("NetworkManager")
	if network_manager != null and network_manager.has_method("leave_game"):
		network_manager.leave_game()


func _label_text(hud: Node, label_name: String) -> String:
	var label := hud.get_node("Panel/Content/%s" % label_name) as Label
	if label == null:
		return ""
	return label.text


func _game_state() -> Node:
	return _tree.root.get_node("GameState")


func _event_bus() -> Node:
	return _tree.root.get_node_or_null("EventBus")


func _reset_network_baseline() -> void:
	var network_manager := _tree.root.get_node_or_null("NetworkManager")
	if network_manager != null and network_manager.has_method("leave_game"):
		network_manager.leave_game()


func _assert(condition: bool, message: String) -> void:
	if condition:
		return
	_failures.append(message)
