extends RefCounted

const HUD_SCENE := preload("res://scenes/ui/hud.tscn")
const WAREHOUSE_SCENE := preload("res://scenes/levels/warehouse_test.tscn")
const PACKAGE_SCENE := preload("res://scenes/entities/package.tscn")
const ORDER_MANAGER_SCRIPT := preload("res://src/systems/order_manager.gd")
const EVENT_BUS_SCRIPT := preload("res://src/autoload/event_bus.gd")

class FakeClientNetworkManager extends Node:
	var is_connected: bool = true
	var is_host: bool = false
	var is_connecting: bool = false
	var connection_state: int = 2
	var last_connection_error: int = int(OK)
	# 大型 peer id 用来模拟 ENet 生成的远端连接标识，而不是稳定的本地槽位编号。
	var connected_peers: Dictionary = {1: true, 1096654874: true}

	func get_peer_slot(peer_id: int) -> int:
		var peer_ids: Array = connected_peers.keys()
		peer_ids.sort()
		return peer_ids.find(peer_id) + 1

	func get_local_peer_slot() -> int:
		return 2

var _tree: SceneTree
var _failures: Array[String] = []
var _saved_game_state: Dictionary = {}
var _saved_network_state: Dictionary = {}


func run(tree: SceneTree) -> Array[String]:
	_tree = tree
	_failures.clear()
	_capture_global_state()

	await _test_hud_reflects_state_and_formats_labels()
	await _test_hud_network_feedback_includes_connecting_and_error_metadata()
	await _test_hud_network_status_uses_stable_slot_for_local_client_id()
	await _test_hud_process_refreshes_after_interval_when_game_state_changes()
	await _test_hud_order_status_falls_back_when_no_order_manager_exists()
	await _test_hud_order_status_updates_immediately_when_orders_are_cleared()
	await _test_hud_rebind_disconnects_previous_order_manager_signals()
	await _test_hud_delivery_feedback_prefers_explicit_game_state_feedback()
	await _test_delivery_tracking_resets_when_session_requests_reset()
	await _test_rejected_delivery_increments_failed_orders_and_respawns_package()
	await _test_session_spawns_offline_world_with_default_offline_peer()
	await _test_spawn_positions_use_peer_roster_slots_instead_of_raw_peer_ids()
	await _test_local_player_profile_uses_peer_slot_labels()
	await _test_hud_player_label_reflects_stable_slot_profiles()
	await _test_host_network_state_rebuilds_world_with_slot_one_profile()
	await _test_disconnect_network_state_respawns_offline_world()
	await _test_session_request_resolution_rejects_mismatched_sender_peer_id()
	await _test_clear_world_detaches_nodes_before_deferred_free()
	await _test_warehouse_camera_frames_spawn_area()
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


func _test_hud_network_feedback_includes_connecting_and_error_metadata() -> void:
	_set_network_disconnected_baseline()

	var root := Node3D.new()
	root.name = "HudNetworkFeedbackRoot"
	_tree.root.add_child(root)

	var hud = HUD_SCENE.instantiate()
	root.add_child(hud)
	await _tree.process_frame

	var network_manager := _network_manager()
	network_manager.set("is_connected", false)
	network_manager.set("is_host", false)
	network_manager.set("is_connecting", true)
	network_manager.set("last_connection_error", int(OK))
	network_manager.set("connected_peers", {})
	hud._refresh_labels()
	_assert(
		_label_text(hud, "NetworkLabel").begins_with("Network: Connecting (Client"),
		"HUD should explicitly show connecting status for readability while link is in progress"
	)

	network_manager.set("is_connecting", false)
	network_manager.set("last_connection_error", int(ERR_CANT_CONNECT))
	hud._refresh_labels()
	var disconnected_label := _label_text(hud, "NetworkLabel")
	_assert(
		disconnected_label.begins_with("Network: Disconnected (Client"),
		"HUD should return to disconnected status once connecting flag is cleared"
	)
	_assert(
		disconnected_label.contains("last_error="),
		"HUD should include last connection error metadata to aid failure readability"
	)

	var missing_flags_node := Node.new()
	var unknown_label: String = String(hud._format_network_status(missing_flags_node))
	missing_flags_node.free()
	_assert(
		unknown_label == "Unknown (Missing is_connected)",
		"HUD should provide deterministic fallback copy when network manager shape is incomplete"
	)

	root.queue_free()
	await _tree.process_frame


func _test_hud_network_status_uses_stable_slot_for_local_client_id() -> void:
	_set_network_disconnected_baseline()

	var root := Node3D.new()
	root.name = "HudStableClientSlotStatusRoot"
	_tree.root.add_child(root)

	var hud = HUD_SCENE.instantiate()
	root.add_child(hud)
	await _tree.process_frame

	var fake_network_manager := FakeClientNetworkManager.new()
	var network_text := String(hud._format_network_status(fake_network_manager))
	_assert(
		network_text.contains("id=2"),
		"HUD network status should show the stable local client slot instead of the raw peer id"
	)
	_assert(
		not network_text.contains("id=1096654874"),
		"HUD network status should not leak the raw large ENet peer id when a stable slot exists"
	)
	fake_network_manager.free()

	root.queue_free()
	await _tree.process_frame


func _test_hud_process_refreshes_after_interval_when_game_state_changes() -> void:
	_set_network_disconnected_baseline()

	var root := Node3D.new()
	root.name = "HudProcessRefreshRoot"
	_tree.root.add_child(root)

	var hud = HUD_SCENE.instantiate()
	root.add_child(hud)
	await _tree.process_frame

	var game_state := _game_state()
	game_state.current_gold = 10
	game_state.current_score = 20
	hud._refresh_labels()
	hud._refresh_timer = hud._refresh_interval

	game_state.current_gold = 99
	game_state.current_score = 123

	hud._process(0.05)
	_assert(_label_text(hud, "GoldLabel") == "Gold: 10", "HUD should not refresh before interval elapses")
	_assert(_label_text(hud, "ScoreLabel") == "Score: 20", "HUD score should remain stale before interval elapses")

	hud._process(0.16)
	_assert(_label_text(hud, "GoldLabel") == "Gold: 99", "HUD should refresh gold after interval elapses")
	_assert(_label_text(hud, "ScoreLabel") == "Score: 123", "HUD should refresh score after interval elapses")

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


func _test_hud_order_status_updates_immediately_when_orders_are_cleared() -> void:
	_set_network_disconnected_baseline()

	var root := Node3D.new()
	root.name = "HudOrderVisibilityRoot"
	_tree.root.add_child(root)

	var manager = ORDER_MANAGER_SCRIPT.new()
	manager.name = "HudVisibilityOrders"
	root.add_child(manager)
	await _tree.process_frame

	manager.clear_orders()
	manager.create_order("normal", "A")
	manager.create_order("fragile", "B")

	var game_state := _game_state()
	game_state.completed_orders = 3
	game_state.failed_orders = 1

	var hud = HUD_SCENE.instantiate()
	root.add_child(hud)
	await _tree.process_frame

	hud._refresh_labels()
	_assert(
		_label_text(hud, "OrdersLabel") == "Orders: Pending 2  Completed 3  Failed 1",
		"HUD should show initial pending count before clearing orders"
	)

	manager.clear_orders()

	_assert(
		_label_text(hud, "OrdersLabel") == "Orders: Pending 0  Completed 3  Failed 1",
		"HUD should update pending order visibility immediately after order manager clear_orders signal"
	)

	root.queue_free()
	await _tree.process_frame


func _test_hud_rebind_disconnects_previous_order_manager_signals() -> void:
	_set_network_disconnected_baseline()

	var root := Node3D.new()
	root.name = "HudRebindDisconnectRoot"
	_tree.root.add_child(root)

	var first_manager = ORDER_MANAGER_SCRIPT.new()
	first_manager.name = "HudFirstOrders"
	root.add_child(first_manager)

	var second_manager = ORDER_MANAGER_SCRIPT.new()
	second_manager.name = "HudSecondOrders"
	root.add_child(second_manager)
	await _tree.process_frame

	var hud = HUD_SCENE.instantiate()
	root.add_child(hud)
	await _tree.process_frame

	hud._order_manager = first_manager
	hud._resolve_and_bind_dependencies()
	_assert(
		first_manager.is_connected("orders_changed", Callable(hud, "_on_order_manager_orders_changed")),
		"HUD should bind to the initial order manager"
	)

	hud._order_manager = second_manager
	hud._resolve_and_bind_dependencies()

	_assert(
		not first_manager.is_connected("orders_changed", Callable(hud, "_on_order_manager_orders_changed")),
		"HUD should disconnect old order manager signals when rebinding to a new manager"
	)
	_assert(
		second_manager.is_connected("orders_changed", Callable(hud, "_on_order_manager_orders_changed")),
		"HUD should connect the new order manager after rebinding"
	)

	root.queue_free()
	await _tree.process_frame


func _test_hud_delivery_feedback_prefers_explicit_game_state_feedback() -> void:
	_set_network_disconnected_baseline()

	var root := Node3D.new()
	root.name = "HudExplicitDeliveryFeedbackRoot"
	_tree.root.add_child(root)

	var hud = HUD_SCENE.instantiate()
	root.add_child(hud)
	await _tree.process_frame

	var game_state := _game_state()
	_assert(game_state.has_method("set_delivery_feedback"), "GameState should expose set_delivery_feedback for HUD delivery feedback")
	if not game_state.has_method("set_delivery_feedback"):
		root.queue_free()
		await _tree.process_frame
		return

	game_state.set_delivery_feedback("rejected", "Wrong destination.", "pkg_404", "")

	_assert(
		_label_text(hud, "DeliveryFeedbackLabel").begins_with("Delivery: Wrong destination."),
		"HUD should prefer explicit delivery feedback message over inferred counter copy"
	)

	if game_state.has_method("clear_delivery_feedback"):
		game_state.clear_delivery_feedback()

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


func _test_rejected_delivery_increments_failed_orders_and_respawns_package() -> void:
	_set_network_disconnected_baseline()

	var session = WAREHOUSE_SCENE.instantiate()
	session.name = "SessionRejectedDeliveryAccounting"
	_tree.root.add_child(session)
	await _tree.process_frame
	await _tree.process_frame

	var package = session.get_node_or_null("Packages/package_1")
	if package == null:
		package = _find_first_package_in_session(session)
	if package == null:
		package = PACKAGE_SCENE.instantiate()
		package.name = "package_rejected"
		package.package_id = "pkg_rejected_001"
		package.package_type = "normal"
		session.get_node("Packages").add_child(package)
		await _tree.process_frame

	var previous_failed: int = int(_game_state().failed_orders)
	var previous_completed: int = int(_game_state().completed_orders)
	var previous_package_id := String(package.get("package_id"))

	session._on_delivery_rejected(previous_package_id, "destination_mismatch")

	_assert(
		_game_state().failed_orders == previous_failed + 1,
		"rejected delivery should increment failed_orders exactly once"
	)
	_assert(
		_game_state().completed_orders == previous_completed,
		"rejected delivery should not change completed_orders"
	)
	_assert(
		String(package.get("package_id")) != previous_package_id,
		"rejected delivery should respawn package with a new deterministic package_id"
	)

	session.queue_free()
	await _tree.process_frame


func _test_session_spawns_offline_world_with_default_offline_peer() -> void:
	_set_network_disconnected_baseline()

	var session = WAREHOUSE_SCENE.instantiate()
	session.name = "SessionOfflineSpawnDefaultPeer"
	_tree.root.add_child(session)
	await _tree.process_frame
	await _tree.process_frame

	var players := session.get_node_or_null("Players")
	var packages := session.get_node_or_null("Packages")
	_assert(players != null and players.get_child_count() == 1, "warehouse session should spawn one offline player on startup")
	_assert(packages != null and packages.get_child_count() == 1, "warehouse session should spawn one offline package on startup")

	session.queue_free()
	await _tree.process_frame


func _test_spawn_positions_use_peer_roster_slots_instead_of_raw_peer_ids() -> void:
	_set_network_disconnected_baseline()

	var session = WAREHOUSE_SCENE.instantiate()
	session.name = "SessionPeerRosterSpawnSlots"
	_tree.root.add_child(session)
	await _tree.process_frame
	await _tree.process_frame

	var network_manager := _network_manager()
	network_manager.connected_peers = {
		1: true,
		743291551: true
	}

	var second_spawn: Vector3 = session._player_spawn_position_for_peer(743291551)
	var player_spawn := session.get_node("SpawnPoints/PlayerSpawn") as Marker3D
	var expected_spawn := player_spawn.global_position + Vector3(1.6, 0.0, 0.0)
	_assert(
		second_spawn.distance_to(expected_spawn) < 0.01,
		"player spawn positions should use roster slot order instead of raw peer ids"
	)

	session.queue_free()
	await _tree.process_frame


func _test_local_player_profile_uses_peer_slot_labels() -> void:
	_set_network_disconnected_baseline()

	var session = WAREHOUSE_SCENE.instantiate()
	session.name = "SessionLocalProfileSlotLabels"
	_tree.root.add_child(session)
	await _tree.process_frame
	await _tree.process_frame

	var network_manager := _network_manager()
	network_manager.connected_peers = {
		1: true,
		1096654874: true
	}

	session._update_local_player_profile(1096654874)

	var game_state := _game_state()
	_assert(game_state.local_player_id == 2, "local player id should use stable peer slot index")
	_assert(game_state.local_player_name == "Player 2", "local player name should use stable peer slot label")

	session.queue_free()
	await _tree.process_frame


func _test_hud_player_label_reflects_stable_slot_profiles() -> void:
	_set_network_disconnected_baseline()

	var root := Node3D.new()
	root.name = "HudStableSlotPlayerLabelRoot"
	_tree.root.add_child(root)

	var hud = HUD_SCENE.instantiate()
	root.add_child(hud)
	await _tree.process_frame

	var game_state := _game_state()
	game_state.set_local_player_profile(2, "Player 2")

	_assert(
		_label_text(hud, "PlayerLabel") == "Player: Player 2",
		"HUD player label should reflect stable slot-based player profiles"
	)

	root.queue_free()
	await _tree.process_frame


func _test_host_network_state_rebuilds_world_with_slot_one_profile() -> void:
	_set_network_disconnected_baseline()

	var session = WAREHOUSE_SCENE.instantiate()
	session.name = "SessionHostWorldRebuild"
	_tree.root.add_child(session)
	await _tree.process_frame
	await _tree.process_frame

	var network_manager := _network_manager()
	network_manager.connected_peers = {
		1: true,
		1096654874: true
	}
	network_manager.set("is_connected", true)
	network_manager.set("is_host", true)
	network_manager.set("is_connecting", false)
	network_manager.set("connection_state", 2)

	session._clear_world()
	session._on_network_state_changed(true, true)

	var players := session.get_node("Players")
	var packages := session.get_node("Packages")
	var game_state := _game_state()
	_assert(players.get_child_count() == 1, "host network state rebuild should spawn exactly one local host player")
	_assert(packages.get_child_count() == 1, "host network state rebuild should respawn the local package")
	_assert(game_state.local_player_id == 1, "host rebuild should keep stable local player slot P1")
	_assert(game_state.local_player_name == "Player 1", "host rebuild should keep stable local player name")

	session.queue_free()
	await _tree.process_frame


func _test_disconnect_network_state_respawns_offline_world() -> void:
	_set_network_disconnected_baseline()

	var session = WAREHOUSE_SCENE.instantiate()
	session.name = "SessionDisconnectRespawn"
	_tree.root.add_child(session)
	await _tree.process_frame
	await _tree.process_frame

	var network_manager := _network_manager()
	network_manager.set("is_connected", true)
	network_manager.set("is_host", false)
	network_manager.set("is_connecting", false)
	network_manager.set("connection_state", 2)
	session._clear_world()

	network_manager.set("is_connected", false)
	network_manager.set("is_host", false)
	network_manager.set("is_connecting", false)
	network_manager.set("connection_state", 0)
	session._on_network_state_changed(false, false)

	var players := session.get_node("Players")
	var packages := session.get_node("Packages")
	var game_state := _game_state()
	_assert(players.get_child_count() == 1, "disconnect transition should respawn an offline player")
	_assert(packages.get_child_count() == 1, "disconnect transition should respawn an offline package")
	_assert(game_state.local_player_id == 1, "disconnect transition should restore local slot P1")
	_assert(game_state.local_player_name == "Player 1", "disconnect transition should restore local player name")

	session.queue_free()
	await _tree.process_frame


func _test_session_request_resolution_rejects_mismatched_sender_peer_id() -> void:
	_set_network_disconnected_baseline()

	var session = WAREHOUSE_SCENE.instantiate()
	session.name = "SessionRequestResolution"
	_tree.root.add_child(session)
	await _tree.process_frame
	await _tree.process_frame

	session._spawn_player_local(2, session._player_spawn_position_for_peer(2))

	var mismatched_player = session._resolve_request_player(1, 2)
	var matching_player = session._resolve_request_player(2, 2)

	_assert(mismatched_player == null, "session should reject player requests when sender peer id does not match requested player authority")
	_assert(matching_player != null and int(matching_player.get_multiplayer_authority()) == 2, "session should resolve the matching requested player when sender peer id is valid")

	session.queue_free()
	await _tree.process_frame


func _test_clear_world_detaches_nodes_before_deferred_free() -> void:
	_set_network_disconnected_baseline()

	var session = WAREHOUSE_SCENE.instantiate()
	session.name = "SessionDeferredClearWorld"
	_tree.root.add_child(session)
	await _tree.process_frame
	await _tree.process_frame

	var players := session.get_node("Players")
	var packages := session.get_node("Packages")
	var player = players.get_child(0)
	var package = packages.get_child(0)

	session._clear_world()

	_assert(players.get_child_count() == 0, "_clear_world should detach player nodes immediately before deferred free")
	_assert(packages.get_child_count() == 0, "_clear_world should detach package nodes immediately before deferred free")
	_assert(is_instance_valid(player), "cleared player should remain valid until deferred free runs")
	_assert(is_instance_valid(package), "cleared package should remain valid until deferred free runs")
	if is_instance_valid(player):
		_assert(player.is_queued_for_deletion(), "cleared player should be queued for deferred deletion")
		_assert(not player.is_inside_tree(), "cleared player should no longer remain inside the scene tree")
	if is_instance_valid(package):
		_assert(package.is_queued_for_deletion(), "cleared package should be queued for deferred deletion")
		_assert(not package.is_inside_tree(), "cleared package should no longer remain inside the scene tree")

	session.queue_free()
	await _tree.process_frame


func _test_warehouse_camera_frames_spawn_area() -> void:
	_set_network_disconnected_baseline()

	var session = WAREHOUSE_SCENE.instantiate()
	session.name = "WarehouseCameraFraming"
	_tree.root.add_child(session)
	await _tree.process_frame
	await _tree.process_frame

	var camera := session.get_node_or_null("Camera3D") as Camera3D
	_assert(camera != null, "warehouse test scene should expose a camera")
	if camera == null:
		session.queue_free()
		await _tree.process_frame
		return

	var ground_target := Vector3(0.0, 1.0, 0.0)
	var camera_forward := -camera.global_basis.z.normalized()
	_assert(camera_forward.y < -0.05, "warehouse camera should tilt downward toward the spawn area")

	var reach_to_target_height := (ground_target.y - camera.global_position.y) / camera_forward.y
	var ground_focus_point := camera.global_position + camera_forward * reach_to_target_height
	_assert(
		ground_focus_point.distance_to(ground_target) < 8.0,
		"warehouse camera should frame the player/package spawn area near the scene origin"
	)

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
