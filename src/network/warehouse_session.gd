extends Node3D

const RuntimeLog := preload("res://src/utils/runtime_log.gd")
const PLAYER_SCENE := preload("res://scenes/entities/player.tscn")
const PACKAGE_SCENE := preload("res://scenes/entities/package.tscn")
const LOCALHOST_ADDRESS := "127.0.0.1"
const PACKAGE_NODE_NAME := "package_1"
const DEFAULT_DESTINATION := "A"
const DEFAULT_PACKAGE_TYPE := "normal"
const PACKAGE_SYNC_INTERVAL := 0.1  # 10Hz 的包裹快照足够覆盖原型联机同步，避免每帧广播。
const DELIVERY_REWARD_GOLD := 25
const DELIVERY_REWARD_SCORE := 100

enum SessionTransition {
	NONE,
	HOSTING,
	JOINING,
	LEAVING
}

@onready var _players: Node3D = $Players
@onready var _packages: Node3D = $Packages
@onready var _player_spawn: Marker3D = $SpawnPoints/PlayerSpawn
@onready var _package_spawn: Marker3D = $SpawnPoints/PackageSpawn
@onready var _order_manager: Node = $Gameplay/OrderManager
@onready var _delivery_zone: Area3D = $Gameplay/DeliveryZone

var _package_sync_timer: float = 0.0
var _next_package_id: int = 1
var _network_action_cooldown: float = 0.0
var _session_transition: SessionTransition = SessionTransition.NONE


func _ready() -> void:
	add_to_group("warehouse_session")
	RuntimeLog.info("Session", "warehouse session ready", {
		"node": name
	})
	EventBus.player_joined.connect(_on_player_joined)
	EventBus.player_left.connect(_on_player_left)
	EventBus.network_state_changed.connect(_on_network_state_changed)

	if _delivery_zone != null:
		_delivery_zone.package_delivered.connect(_on_package_delivered)
		_delivery_zone.delivery_rejected.connect(_on_delivery_rejected)

	_spawn_offline_world()


func _process(delta: float) -> void:
	_network_action_cooldown = maxf(0.0, _network_action_cooldown - delta)

	if not NetworkManager.is_connected or not NetworkManager.is_host:
		return

	_package_sync_timer -= delta
	if _package_sync_timer > 0.0:
		return

	_package_sync_timer = PACKAGE_SYNC_INTERVAL
	_broadcast_all_package_snapshots()


func _unhandled_input(event: InputEvent) -> void:
	if event is not InputEventKey:
		return
	if not event.pressed or event.echo:
		return

	match event.keycode:
		KEY_F5:
			_host_local_session()
		KEY_F6:
			_join_local_session()
		KEY_F7:
			_leave_session()


func request_player_grab(player: Node3D) -> bool:
	if player == null:
		return false

	if NetworkManager.is_connected and not NetworkManager.is_host:
		_request_grab.rpc_id(1, int(player.get_multiplayer_authority()))
		return true

	return _host_try_grab(player)


func request_player_drop(player: Node3D) -> bool:
	if player == null:
		return false

	if NetworkManager.is_connected and not NetworkManager.is_host:
		_request_drop.rpc_id(1, int(player.get_multiplayer_authority()), Vector3.ZERO)
		return true

	return _host_try_drop(player, Vector3.ZERO)


func request_player_throw(player: Node3D, impulse: Vector3) -> bool:
	if player == null:
		return false

	if NetworkManager.is_connected and not NetworkManager.is_host:
		_request_drop.rpc_id(1, int(player.get_multiplayer_authority()), impulse)
		return true

	return _host_try_drop(player, impulse)


func _host_local_session() -> void:
	if NetworkManager.is_connected:
		RuntimeLog.info("Session", "host skipped: already connected", {})
		return
	if _network_action_cooldown > 0.0:
		RuntimeLog.info("Session", "host skipped: cooldown active", {
			"cooldown_left": _network_action_cooldown
		})
		return
	if _is_network_transition_in_progress():
		RuntimeLog.info("Session", "host skipped: transition in progress", {
			"transition": _session_transition
		})
		return

	_session_transition = SessionTransition.HOSTING
	RuntimeLog.info("Session", "hosting local session", {
		"transition": _session_transition
	})
	_clear_world()
	_configure_delivery_zone(false)
	var err := NetworkManager.host_game()
	if err != OK:
		_session_transition = SessionTransition.NONE
		_network_action_cooldown = 0.8
		push_warning(RuntimeLog.warning_text("Session", "host LAN session failed", {
			"port": NetworkManager.DEFAULT_PORT,
			"error": error_string(err)
		}))
		_spawn_offline_world()
		return


func _join_local_session() -> void:
	if NetworkManager.is_connected:
		RuntimeLog.info("Session", "join skipped: already connected", {})
		return
	if _network_action_cooldown > 0.0:
		RuntimeLog.info("Session", "join skipped: cooldown active", {
			"cooldown_left": _network_action_cooldown
		})
		return
	if _is_network_transition_in_progress():
		RuntimeLog.info("Session", "join skipped: transition in progress", {
			"transition": _session_transition
		})
		return

	_session_transition = SessionTransition.JOINING
	RuntimeLog.info("Session", "joining local session", {
		"address": LOCALHOST_ADDRESS,
		"transition": _session_transition
	})
	_clear_world()
	_configure_delivery_zone(false)
	var err := NetworkManager.join_game(LOCALHOST_ADDRESS)
	if err != OK:
		_session_transition = SessionTransition.NONE
		_network_action_cooldown = 0.4
		push_warning(RuntimeLog.warning_text("Session", "join LAN session failed", {
			"address": LOCALHOST_ADDRESS,
			"error": error_string(err)
		}))
		_spawn_offline_world()


func _leave_session() -> void:
	_session_transition = SessionTransition.LEAVING
	RuntimeLog.info("Session", "leave requested", {
		"connected": NetworkManager.is_connected,
		"has_peer": _has_active_network_peer()
	})
	if NetworkManager.is_connected or _has_active_network_peer():
		NetworkManager.leave_game()
	else:
		_session_transition = SessionTransition.NONE
		_spawn_offline_world()


func _on_player_joined(peer_id: int) -> void:
	if not NetworkManager.is_host:
		return
	if peer_id == multiplayer.get_unique_id():
		return

	var spawn_position := _player_spawn_position_for_peer(peer_id)
	RuntimeLog.info("Session", "player joined", {
		"peer_id": peer_id,
		"spawn_position": spawn_position
	})
	_spawn_player_local(peer_id, spawn_position)
	_spawn_player_for_peer.rpc(peer_id, spawn_position)
	_sync_world_to_peer(peer_id)


func _on_player_left(peer_id: int) -> void:
	RuntimeLog.info("Session", "player left", {
		"peer_id": peer_id
	})
	var player := _find_player_by_peer_id(peer_id)
	if player != null:
		player.queue_free()


func _on_network_state_changed(connected: bool, host: bool) -> void:
	_session_transition = SessionTransition.NONE
	RuntimeLog.info("Session", "network state changed", {
		"connected": connected,
		"host": host,
		"peer_id": _safe_local_peer_id()
	})
	_configure_delivery_zone(not connected or host)

	if not connected:
		_spawn_offline_world()
		return

	if host:
		_build_host_world()
	else:
		_clear_world()
		_update_local_player_profile(multiplayer.get_unique_id())
		RuntimeLog.info("Session", "building client world", {
			"local_peer_id": multiplayer.get_unique_id()
		})
		if multiplayer.get_unique_id() != 1:
			_spawn_player_local(1, _player_spawn_position_for_peer(1))
		_spawn_player_local(multiplayer.get_unique_id(), _player_spawn_position_for_peer(multiplayer.get_unique_id()))
		_request_full_state.rpc_id(1)
		GameState.set_phase(EventBus.GamePhase.WORKING)


func _on_package_delivered(package_id: String, _order_id: String) -> void:
	if NetworkManager.is_connected and not NetworkManager.is_host:
		return

	RuntimeLog.info("Session", "package delivered", {
		"package_id": package_id,
		"order_id": _order_id
	})
	_increment_completed_orders(1)
	GameState.add_gold(DELIVERY_REWARD_GOLD)
	GameState.add_score(DELIVERY_REWARD_SCORE)
	GameState.set_delivery_feedback("success", "Package delivered.", package_id, _order_id)

	var package: Node = _find_package_by_id(package_id)
	if package == null:
		package = _packages.get_node_or_null(PACKAGE_NODE_NAME)

	_seed_orders()
	_respawn_package(package)
	_broadcast_order_state()


func _on_delivery_rejected(package_id: String, _reason: String) -> void:
	if NetworkManager.is_connected and not NetworkManager.is_host:
		return

	RuntimeLog.info("Session", "delivery rejected", {
		"package_id": package_id,
		"reason": _reason
	})
	_increment_failed_orders(1)
	GameState.set_delivery_feedback("rejected", _delivery_rejection_message(_reason), package_id, "")

	var package: Node = _find_package_by_id(package_id)
	if package == null:
		package = _packages.get_node_or_null(PACKAGE_NODE_NAME)
	_respawn_package(package)
	_broadcast_order_state()


func _spawn_offline_world() -> void:
	if NetworkManager.is_connected or _has_active_network_peer():
		RuntimeLog.info("Session", "spawn_offline_world skipped: active network peer", {
			"connected": NetworkManager.is_connected,
			"has_peer": _has_active_network_peer()
		})
		return

	RuntimeLog.info("Session", "spawning offline world", {})
	_clear_world()
	_reset_delivery_zone_state()
	_next_package_id = 1
	_update_local_player_profile(1)
	_spawn_player_local(1, _player_spawn.global_position)
	_spawn_package_local(PACKAGE_NODE_NAME, _package_spawn.global_position, _allocate_package_id())
	GameState.reset_session("warehouse_test")
	GameState.set_phase(EventBus.GamePhase.WORKING)
	_seed_orders()


func _delivery_rejection_message(reason: String) -> String:
	match reason:
		"destination_mismatch":
			return "Wrong destination."
		"package_type_mismatch":
			return "Wrong package type."
		"no_pending_order":
			return "No pending order."
		"package_state_held":
			return "Drop the package before delivery."
		"package_state_frozen":
			return "Package is not ready for delivery."
		"package_state_thrown":
			return "Wait for the package to land."
		"missing_order_manager":
			return "Order system unavailable."
		"invalid_order_manager":
			return "Order system invalid."
		"invalid_validation_result":
			return "Delivery validation failed."
		_:
			return "Delivery rejected."


func _has_active_network_peer() -> bool:
	return NetworkManager.has_active_peer()


func _is_network_transition_in_progress() -> bool:
	if _session_transition != SessionTransition.NONE:
		return true
	return not NetworkManager.is_connected and _has_active_network_peer()


func _build_host_world() -> void:
	RuntimeLog.info("Session", "building host world", {})
	_clear_world()
	_reset_delivery_zone_state()
	_next_package_id = 1
	var peer_id := multiplayer.get_unique_id()
	_update_local_player_profile(peer_id)
	_spawn_player_local(peer_id, _player_spawn_position_for_peer(peer_id))
	_spawn_package_local(PACKAGE_NODE_NAME, _package_spawn.global_position, _allocate_package_id())
	GameState.reset_session("warehouse_test")
	GameState.set_phase(EventBus.GamePhase.WORKING)
	_seed_orders()
	_broadcast_order_state()


func _sync_world_to_peer(peer_id: int) -> void:
	for player in _get_all_players():
		_spawn_player_for_peer.rpc_id(peer_id, int(player.name), player.global_position)

	for package in _get_all_packages():
		_spawn_package_for_peer.rpc_id(peer_id, String(package.name), package.global_position)
		if package.has_method("get_network_snapshot"):
			_apply_package_snapshot.rpc_id(peer_id, String(package.name), package.get_network_snapshot())

	_sync_order_state.rpc_id(
		peer_id,
		_make_orders_snapshot(),
		GameState.completed_orders,
		GameState.failed_orders,
		GameState.current_gold,
		GameState.current_score
	)


func _spawn_player_local(peer_id: int, spawn_position: Vector3) -> void:
	var existing_player := _find_player_by_peer_id(peer_id)
	if existing_player != null:
		existing_player.global_position = spawn_position
		RuntimeLog.info("Session", "repositioned existing player", {
			"peer_id": peer_id,
			"spawn_position": spawn_position
		})
		return

	var node_name := str(peer_id)
	var player := PLAYER_SCENE.instantiate()
	player.name = node_name
	player.set_multiplayer_authority(peer_id)
	_players.add_child(player, true)
	player.global_position = spawn_position
	_apply_player_debug_tint(player, peer_id)
	var is_local_player := true if _safe_local_peer_id() < 0 else player.is_multiplayer_authority()
	RuntimeLog.info("Session", "spawned player", {
		"peer_id": peer_id,
		"node": node_name,
		"spawn_position": spawn_position,
		"authority": player.get_multiplayer_authority(),
		"local": is_local_player,
		"local_peer_id": _safe_local_peer_id()
	})


func _spawn_package_local(package_name: String, spawn_position: Vector3, package_id: String = "") -> Node3D:
	var package: Node3D
	package = _find_package_by_name(package_name)
	if package == null:
		package = PACKAGE_SCENE.instantiate()
		package.name = package_name
		_packages.add_child(package, true)
		RuntimeLog.info("Session", "instantiated package", {
			"package_name": package_name
		})

	package.global_position = spawn_position
	package.global_basis = Basis.IDENTITY
	if package.has_method("set"):
		package.set("package_id", package_id if not package_id.is_empty() else package_name)
		package.set("package_type", DEFAULT_PACKAGE_TYPE)
	RuntimeLog.info("Session", "spawned package", {
		"package_id": package_id if not package_id.is_empty() else package_name,
		"package_name": package_name,
		"spawn_position": spawn_position
	})
	return package


func _clear_world() -> void:
	RuntimeLog.info("Session", "clearing world", {
		"players": _get_all_players().size(),
		"packages": _get_all_packages().size()
	})
	for child in _get_all_players():
		if child != null and is_instance_valid(child):
			var parent: Node = child.get_parent()
			if parent != null:
				parent.remove_child(child)
			child.queue_free()

	for child in _get_all_packages():
		if child != null and is_instance_valid(child):
			var parent: Node = child.get_parent()
			if parent != null:
				parent.remove_child(child)
			child.queue_free()


func _update_local_player_profile(peer_id: int) -> void:
	var player_slot := 1
	if NetworkManager != null and NetworkManager.has_method("get_peer_slot"):
		player_slot = int(NetworkManager.get_peer_slot(peer_id))
	var player_name := "Player %d" % player_slot
	RuntimeLog.info("Session", "updating local player profile", {
		"peer_id": peer_id,
		"player_slot": player_slot,
		"player_name": player_name
	})
	if GameState.has_method("set_local_player_profile"):
		GameState.set_local_player_profile(player_slot, player_name)
		return
	if GameState.has_method("update_local_player_profile"):
		GameState.update_local_player_profile(player_slot, player_name)
		return
	if GameState.has_method("set_local_player_identity"):
		GameState.set_local_player_identity(player_slot, player_name)
		return

	GameState.set("local_player_id", player_slot)
	GameState.set("local_player_name", player_name)


func _increment_completed_orders(amount: int) -> void:
	if amount == 0:
		return

	if GameState.has_method("add_completed_orders"):
		GameState.add_completed_orders(amount)
		return
	if GameState.has_method("increment_completed_orders"):
		GameState.increment_completed_orders(amount)
		return
	if GameState.has_method("update_completed_orders"):
		GameState.update_completed_orders(amount)
		return

	GameState.apply_session_totals(
		GameState.completed_orders + amount,
		GameState.failed_orders,
		GameState.current_gold,
		GameState.current_score
	)


func _increment_failed_orders(amount: int) -> void:
	if amount == 0:
		return

	if GameState.has_method("add_failed_orders"):
		GameState.add_failed_orders(amount)
		return
	if GameState.has_method("increment_failed_orders"):
		GameState.increment_failed_orders(amount)
		return
	if GameState.has_method("update_failed_orders"):
		GameState.update_failed_orders(amount)
		return

	GameState.apply_session_totals(
		GameState.completed_orders,
		GameState.failed_orders + amount,
		GameState.current_gold,
		GameState.current_score
	)


func _apply_player_debug_tint(player: Node, peer_id: int) -> void:
	var visual_root := player.get_node_or_null("VisualRoot")
	var visual := _find_mesh_instance(visual_root)
	if visual == null:
		return

	var material := visual.get_active_material(0)
	if material == null:
		return

	var override_material := material.duplicate()
	if override_material is StandardMaterial3D:
		var tint_palette := [
			Color(0.301961, 0.564706, 0.913725, 1),
			Color(0.929412, 0.431373, 0.270588, 1),
			Color(0.286275, 0.764706, 0.470588, 1),
			Color(0.952941, 0.788235, 0.266667, 1)
		]
		override_material.albedo_color = tint_palette[(peer_id - 1) % tint_palette.size()]
	visual.set_surface_override_material(0, override_material)


func _find_mesh_instance(node: Node) -> MeshInstance3D:
	if node == null:
		return null
	if node is MeshInstance3D:
		return node as MeshInstance3D
	for child in node.get_children():
		var visual := _find_mesh_instance(child)
		if visual != null:
			return visual
	return null


func _player_spawn_position_for_peer(peer_id: int) -> Vector3:
	var spawn_index := _player_spawn_slot_for_peer(peer_id)
	return _player_spawn.global_position + Vector3(spawn_index * 1.6, 0.0, 0.0)


func _player_spawn_slot_for_peer(peer_id: int) -> int:
	var connected_peer_ids: Array[int] = []
	if NetworkManager != null and NetworkManager.has_method("get_connected_peer_ids"):
		var peer_ids_value: Variant = NetworkManager.get_connected_peer_ids()
		if peer_ids_value is Array:
			for value in peer_ids_value:
				if value is int:
					connected_peer_ids.append(int(value))

	if connected_peer_ids.is_empty():
		return maxi(0, peer_id - 1) if peer_id > 0 and peer_id <= 4 else 0

	if not connected_peer_ids.has(peer_id):
		connected_peer_ids.append(peer_id)
	connected_peer_ids.sort()

	var slot_index := connected_peer_ids.find(peer_id)
	return maxi(slot_index, 0)


func _seed_orders() -> void:
	if _order_manager == null:
		return

	_order_manager.clear_orders()
	_order_manager.ensure_static_order(DEFAULT_PACKAGE_TYPE, DEFAULT_DESTINATION)


func _configure_delivery_zone(active: bool) -> void:
	if _delivery_zone == null:
		return

	_delivery_zone.monitoring = active
	_delivery_zone.monitorable = active


func _reset_delivery_zone_state() -> void:
	if _delivery_zone == null:
		return
	if _delivery_zone.has_method("reset_delivery_tracking"):
		_delivery_zone.reset_delivery_tracking()


func _host_try_grab(player: Node3D) -> bool:
	var package: Node = _find_grabbable_package_near(player)
	if package == null:
		return false

	if package.request_grab(player, player.get_multiplayer_authority()):
		_broadcast_package_snapshot(package)
		return true
	return false


func _host_try_drop(player: Node3D, impulse: Vector3) -> bool:
	var package: Node = _find_package_held_by_player(player)
	if package == null:
		return false

	if package.request_drop(impulse):
		_broadcast_package_snapshot(package)
		return true
	return false


func _find_grabbable_package_near(player: Node3D):
	var nearest_package = null
	var max_distance_squared := _player_grab_range(player) * _player_grab_range(player)

	for package in _get_all_packages():
		if not package.has_method("can_accept_grab_request"):
			continue
		if not package.can_accept_grab_request(player, player.get_multiplayer_authority(), _player_grab_range(player)):
			continue

		var distance_squared := player.global_position.distance_squared_to(package.global_position)
		if distance_squared > max_distance_squared:
			continue

		nearest_package = package
		max_distance_squared = distance_squared

	return nearest_package


func _find_package_held_by_player(player: Node3D):
	for package in _get_all_packages():
		if package.get("holder") == player:
			return package
	return null


func _find_package_by_id(package_id: String):
	for package in _get_all_packages():
		if String(package.get("package_id")) == package_id:
			return package
	return null


func _player_grab_range(player: Node3D) -> float:
	var value = player.get("grab_range")
	if value is float:
		return value
	if value is int:
		return float(value)
	return 2.0


func _respawn_package(package: Node3D) -> void:
	if package == null:
		package = _spawn_package_local(PACKAGE_NODE_NAME, _package_spawn.global_position, _allocate_package_id())
	else:
		if package.has_method("request_drop") and package.get("holder") != null:
			package.request_drop()
		if package.has_method("apply_network_snapshot"):
			package.apply_network_snapshot({
				"package_id": _allocate_package_id(),
				"state": 0,
				"authority_peer_id_hint": 1,
				"holder_path": "",
				"position": _package_spawn.global_position,
				"basis": Basis.IDENTITY,
				"linear_velocity": Vector3.ZERO,
				"angular_velocity": Vector3.ZERO,
				"freeze": false
			})
		else:
			package.global_position = _package_spawn.global_position

	_broadcast_package_snapshot(package)


func _safe_local_peer_id() -> int:
	var peer := multiplayer.multiplayer_peer
	if peer == null or peer is OfflineMultiplayerPeer:
		return -1
	return multiplayer.get_unique_id()


func _allocate_package_id() -> String:
	var package_id := "pkg_%03d" % _next_package_id
	_next_package_id += 1
	return package_id


func _broadcast_all_package_snapshots() -> void:
	for package in _get_all_packages():
		_broadcast_package_snapshot(package)


func _get_all_players() -> Array:
	var players: Array = []
	for node in get_tree().get_nodes_in_group("players"):
		if node is Node3D and is_ancestor_of(node) and not node.is_queued_for_deletion():
			players.append(node)
	return players


func _get_all_packages() -> Array:
	var packages: Array = []
	for node in get_tree().get_nodes_in_group("packages"):
		if node is Node3D and is_ancestor_of(node) and not node.is_queued_for_deletion():
			packages.append(node)
	return packages


func _broadcast_package_snapshot(package: Node) -> void:
	if package == null or not NetworkManager.is_connected or not NetworkManager.is_host:
		return
	if not package.has_method("get_network_snapshot"):
		return

	_apply_package_snapshot.rpc(String(package.name), package.get_network_snapshot())


func _broadcast_order_state() -> void:
	if not NetworkManager.is_connected or not NetworkManager.is_host:
		return

	_sync_order_state.rpc(
		_make_orders_snapshot(),
		GameState.completed_orders,
		GameState.failed_orders,
		GameState.current_gold,
		GameState.current_score
	)


func _make_orders_snapshot() -> Array:
	var snapshot: Array = []
	if _order_manager == null:
		return snapshot

	for order in _order_manager.active_orders:
		if order is Dictionary:
			snapshot.append(order.duplicate(true))

	return snapshot


func _apply_order_state_local(orders_snapshot: Array, completed_orders: int, failed_orders: int, gold: int, score: int) -> void:
	if _order_manager != null:
		_order_manager.clear_orders()
		for order in orders_snapshot:
			if order is Dictionary:
				_order_manager.active_orders.append(order.duplicate(true))

	GameState.apply_session_totals(completed_orders, failed_orders, gold, score)
	GameState.set_phase(EventBus.GamePhase.WORKING)


func _resolve_request_player(sender_peer_id: int, requested_peer_id: int) -> Node3D:
	if sender_peer_id <= 0 or requested_peer_id <= 0:
		return null
	if sender_peer_id != requested_peer_id:
		RuntimeLog.info("Session", "rejected request with mismatched peer ids", {
			"sender_peer_id": sender_peer_id,
			"requested_peer_id": requested_peer_id
		})
		return null
	return _find_player_by_peer_id(requested_peer_id)


@rpc("any_peer", "reliable")
func _request_grab(requested_peer_id: int) -> void:
	if not NetworkManager.is_host:
		return

	var sender_id := multiplayer.get_remote_sender_id()
	var player := _resolve_request_player(sender_id, requested_peer_id)
	if player != null:
		_host_try_grab(player)


@rpc("any_peer", "reliable")
func _request_drop(requested_peer_id: int, impulse: Vector3) -> void:
	if not NetworkManager.is_host:
		return

	var sender_id := multiplayer.get_remote_sender_id()
	var player := _resolve_request_player(sender_id, requested_peer_id)
	if player != null:
		_host_try_drop(player, impulse)


@rpc("any_peer", "reliable")
func _request_full_state() -> void:
	if not NetworkManager.is_host:
		return

	var sender_id := multiplayer.get_remote_sender_id()
	_sync_world_to_peer(sender_id)


@rpc("authority", "reliable")
func _spawn_player_for_peer(peer_id: int, spawn_position: Vector3) -> void:
	_spawn_player_local(peer_id, spawn_position)


@rpc("authority", "reliable")
func _spawn_package_for_peer(package_name: String, spawn_position: Vector3) -> void:
	_spawn_package_local(package_name, spawn_position)


@rpc("authority", "unreliable")
func _apply_package_snapshot(package_name: String, snapshot: Dictionary) -> void:
	var package = _spawn_package_local(package_name, snapshot.get("position", _package_spawn.global_position))
	if package != null and package.has_method("apply_network_snapshot"):
		package.apply_network_snapshot(snapshot)


func _find_player_by_peer_id(peer_id: int) -> Node3D:
	var node_name := str(peer_id)
	for player in _get_all_players():
		if String(player.name) == node_name:
			return player as Node3D
	return null


func _find_package_by_name(package_name: String) -> Node3D:
	for package in _get_all_packages():
		if String(package.name) == package_name:
			return package as Node3D
	return null


@rpc("authority", "reliable")
func _sync_order_state(orders_snapshot: Array, completed_orders: int, failed_orders: int, gold: int, score: int) -> void:
	_apply_order_state_local(orders_snapshot, completed_orders, failed_orders, gold, score)
