extends Node3D

const PLAYER_SCENE := preload("res://scenes/entities/player.tscn")
const PACKAGE_SCENE := preload("res://scenes/entities/package.tscn")
const LOCALHOST_ADDRESS := "127.0.0.1"
const PACKAGE_NODE_NAME := "package_1"
const DEFAULT_DESTINATION := "A"
const DEFAULT_PACKAGE_TYPE := "normal"
const PACKAGE_SYNC_INTERVAL := 0.1
const DELIVERY_REWARD_GOLD := 25
const DELIVERY_REWARD_SCORE := 100

@onready var _players: Node3D = $Players
@onready var _packages: Node3D = $Packages
@onready var _player_spawn: Marker3D = $SpawnPoints/PlayerSpawn
@onready var _package_spawn: Marker3D = $SpawnPoints/PackageSpawn
@onready var _order_manager: Node = $Gameplay/OrderManager
@onready var _delivery_zone: Area3D = $Gameplay/DeliveryZone

var _package_sync_timer: float = 0.0
var _next_package_id: int = 1


func _ready() -> void:
	add_to_group("warehouse_session")
	EventBus.player_joined.connect(_on_player_joined)
	EventBus.player_left.connect(_on_player_left)
	EventBus.network_state_changed.connect(_on_network_state_changed)

	if _delivery_zone != null:
		_delivery_zone.package_delivered.connect(_on_package_delivered)
		_delivery_zone.delivery_rejected.connect(_on_delivery_rejected)

	_spawn_offline_world()


func _process(delta: float) -> void:
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
		_request_grab.rpc_id(1)
		return true

	return _host_try_grab(player)


func request_player_drop(player: Node3D) -> bool:
	if player == null:
		return false

	if NetworkManager.is_connected and not NetworkManager.is_host:
		_request_drop.rpc_id(1, Vector3.ZERO)
		return true

	return _host_try_drop(player, Vector3.ZERO)


func request_player_throw(player: Node3D, impulse: Vector3) -> bool:
	if player == null:
		return false

	if NetworkManager.is_connected and not NetworkManager.is_host:
		_request_drop.rpc_id(1, impulse)
		return true

	return _host_try_drop(player, impulse)


func _host_local_session() -> void:
	if NetworkManager.is_connected:
		return

	_clear_world()
	var err := NetworkManager.host_game()
	if err != OK:
		push_warning("Failed to host LAN session: %s" % error_string(err))
		_spawn_offline_world()
		return


func _join_local_session() -> void:
	if NetworkManager.is_connected:
		return

	_clear_world()
	_configure_delivery_zone(false)
	var err := NetworkManager.join_game(LOCALHOST_ADDRESS)
	if err != OK:
		push_warning("Failed to join LAN session: %s" % error_string(err))
		_spawn_offline_world()


func _leave_session() -> void:
	if NetworkManager.is_connected:
		NetworkManager.leave_game()
	else:
		_spawn_offline_world()


func _on_player_joined(peer_id: int) -> void:
	if not NetworkManager.is_host:
		return
	if peer_id == multiplayer.get_unique_id():
		return

	var spawn_position := _player_spawn_position_for_peer(peer_id)
	_spawn_player_local(peer_id, spawn_position)
	_spawn_player_for_peer.rpc(peer_id, spawn_position)
	_sync_world_to_peer(peer_id)


func _on_player_left(peer_id: int) -> void:
	var player := _players.get_node_or_null(str(peer_id))
	if player != null:
		player.queue_free()


func _on_network_state_changed(connected: bool, host: bool) -> void:
	_configure_delivery_zone(not connected or host)

	if not connected:
		_spawn_offline_world()
		return

	if host:
		_build_host_world()
	else:
		_update_local_player_profile(multiplayer.get_unique_id())
		_spawn_player_local(multiplayer.get_unique_id(), _player_spawn_position_for_peer(multiplayer.get_unique_id()))
		_request_full_state.rpc_id(1)
		GameState.set_phase(EventBus.GamePhase.WORKING)


func _on_package_delivered(package_id: String, _order_id: String) -> void:
	if NetworkManager.is_connected and not NetworkManager.is_host:
		return

	GameState.completed_orders += 1
	GameState.add_gold(DELIVERY_REWARD_GOLD)
	GameState.add_score(DELIVERY_REWARD_SCORE)

	var package: Node = _find_package_by_id(package_id)
	if package == null:
		package = _packages.get_node_or_null(PACKAGE_NODE_NAME)

	_seed_orders()
	_respawn_package(package)
	_broadcast_order_state()


func _on_delivery_rejected(_package_id: String, _reason: String) -> void:
	pass


func _spawn_offline_world() -> void:
	if NetworkManager.is_connected:
		return

	_clear_world()
	_next_package_id = 1
	_update_local_player_profile(1)
	_spawn_player_local(1, _player_spawn.global_position)
	_spawn_package_local(PACKAGE_NODE_NAME, _package_spawn.global_position, _allocate_package_id())
	GameState.reset_session("warehouse_test")
	GameState.set_phase(EventBus.GamePhase.WORKING)
	_seed_orders()


func _build_host_world() -> void:
	_clear_world()
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
	for player in _players.get_children():
		_spawn_player_for_peer.rpc_id(peer_id, int(player.name), player.global_position)

	for package in _packages.get_children():
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
	var node_name := str(peer_id)
	if _players.has_node(NodePath(node_name)):
		var existing_player := _players.get_node(NodePath(node_name)) as Node3D
		existing_player.global_position = spawn_position
		return

	var player := PLAYER_SCENE.instantiate()
	player.name = node_name
	player.set_multiplayer_authority(peer_id)
	_players.add_child(player, true)
	player.global_position = spawn_position
	_apply_player_debug_tint(player, peer_id)


func _spawn_package_local(package_name: String, spawn_position: Vector3, package_id: String = "") -> Node3D:
	var package: Node3D
	if _packages.has_node(NodePath(package_name)):
		package = _packages.get_node(NodePath(package_name)) as Node3D
	else:
		package = PACKAGE_SCENE.instantiate()
		package.name = package_name
		_packages.add_child(package, true)

	package.global_position = spawn_position
	package.global_basis = Basis.IDENTITY
	if package.has_method("set"):
		package.set("package_id", package_id if not package_id.is_empty() else package_name)
		package.set("package_type", DEFAULT_PACKAGE_TYPE)
	return package


func _clear_world() -> void:
	for child in _players.get_children():
		child.free()

	for child in _packages.get_children():
		child.free()


func _update_local_player_profile(peer_id: int) -> void:
	GameState.local_player_id = peer_id
	GameState.local_player_name = "Player %d" % peer_id


func _apply_player_debug_tint(player: Node, peer_id: int) -> void:
	var visual := player.get_node_or_null("VisualRoot") as MeshInstance3D
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


func _player_spawn_position_for_peer(peer_id: int) -> Vector3:
	var spawn_index := maxi(0, peer_id - 1)
	return _player_spawn.global_position + Vector3(spawn_index * 1.6, 0.0, 0.0)


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

	for package in _packages.get_children():
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
	for package in _packages.get_children():
		if package.get("holder") == player:
			return package
	return null


func _find_package_by_id(package_id: String):
	for package in _packages.get_children():
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


func _allocate_package_id() -> String:
	var package_id := "pkg_%03d" % _next_package_id
	_next_package_id += 1
	return package_id


func _broadcast_all_package_snapshots() -> void:
	for package in _packages.get_children():
		_broadcast_package_snapshot(package)


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


@rpc("any_peer", "reliable")
func _request_grab() -> void:
	if not NetworkManager.is_host:
		return

	var sender_id := multiplayer.get_remote_sender_id()
	var player := _players.get_node_or_null(str(sender_id)) as Node3D
	if player != null:
		_host_try_grab(player)


@rpc("any_peer", "reliable")
func _request_drop(impulse: Vector3) -> void:
	if not NetworkManager.is_host:
		return

	var sender_id := multiplayer.get_remote_sender_id()
	var player := _players.get_node_or_null(str(sender_id)) as Node3D
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


@rpc("authority", "reliable")
func _sync_order_state(orders_snapshot: Array, completed_orders: int, failed_orders: int, gold: int, score: int) -> void:
	_apply_order_state_local(orders_snapshot, completed_orders, failed_orders, gold, score)
