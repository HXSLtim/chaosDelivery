extends CharacterBody3D

const RuntimeLog := preload("res://src/utils/runtime_log.gd")

@export var move_speed: float = 4.5
@export var acceleration: float = 18.0
@export var deceleration: float = 24.0
@export var gravity_scale: float = 1.0
@export var grab_range: float = 2.0
@export var throw_impulse_strength: float = 4.5
@export var interaction_cooldown: float = 0.12
@export var network_request_timeout: float = 0.35
@export var expected_player_count: int = 2

const LOCAL_COLOR := Color(0.329, 0.851, 0.557, 1.0)
const REMOTE_COLOR := Color(0.847, 0.482, 0.443, 1.0)
const WAITING_COLOR := Color(0.980, 0.792, 0.278, 1.0)
const COOLDOWN_COLOR := Color(0.627, 0.667, 0.980, 1.0)
const PLAYER_COUNT_REFRESH_INTERVAL := 0.25

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var _last_input: Vector2 = Vector2.ZERO
var _held_package: Package = null
var _predicted_held_package: Package = null
var _interaction_cooldown_left: float = 0.0
var _request_timeout_left: float = 0.0
var _waiting_for_network_action: bool = false
var _awaiting_grab_release: bool = false
var _last_holding_state: bool = false
var _last_identity_cache: String = ""
var _debug_material: StandardMaterial3D = null
var _session_cache: Node3D = null
var _cached_visible_players: int = 0
var _player_count_refresh_left: float = 0.0

@onready var _visual_root: MeshInstance3D = $VisualRoot
@onready var _debug_label: Label3D = $DebugLabel


func _physics_process(delta: float) -> void:
	_tick_runtime_state(delta)

	if _has_network_peer() and not is_multiplayer_authority():
		return

	var input_vector := _read_move_input()
	_last_input = input_vector

	var target_velocity := Vector3(input_vector.x, 0.0, input_vector.y) * move_speed
	var lerp_weight := acceleration if input_vector.length() > 0.0 else deceleration

	velocity.x = move_toward(velocity.x, target_velocity.x, lerp_weight * delta)
	velocity.z = move_toward(velocity.z, target_velocity.z, lerp_weight * delta)

	if not is_on_floor():
		velocity.y -= _gravity * gravity_scale * delta
	else:
		velocity.y = 0.0

	move_and_slide()
	_update_facing(delta)
	_handle_interactions()
	_broadcast_state()


func _ready() -> void:
	add_to_group("players")
	RuntimeLog.info("Player", "ready", {
		"node": name,
		"authority": get_multiplayer_authority(),
		"has_network_peer": _has_network_peer(),
		"local": _is_local_authority_safe(),
		"unique_id": multiplayer.get_unique_id() if _has_network_peer() else -1
	})


func _read_move_input() -> Vector2:
	var x := InputManager.get_move_vector().x
	var y := InputManager.get_move_vector().y

	# Fallback to built-in ui_* actions for early prototyping.
	if is_zero_approx(x):
		x = Input.get_action_strength("ui_right") - Input.get_action_strength("ui_left")
	if is_zero_approx(y):
		y = Input.get_action_strength("ui_down") - Input.get_action_strength("ui_up")

	var result := Vector2(x, y)
	if result.length() > 1.0:
		result = result.normalized()
	return result


func _update_facing(delta: float) -> void:
	if _last_input.length() <= 0.001:
		return

	var facing_target := Vector3(_last_input.x, 0.0, _last_input.y).normalized()
	var target_basis := Basis.looking_at(facing_target, Vector3.UP)
	basis = basis.slerp(target_basis, min(delta * 10.0, 1.0))


func _handle_interactions() -> void:
	_held_package = _resolve_held_package()
	var session := _get_session()
	if not _can_attempt_interaction():
		return

	var handled_grab_this_frame := false
	var grab_pressed := InputManager.is_grab_pressed()
	if _awaiting_grab_release:
		if not Input.is_action_pressed(String(InputManager.ACTION_GRAB)) and not grab_pressed:
			_awaiting_grab_release = false
		grab_pressed = false
	if grab_pressed:
		handled_grab_this_frame = true
		if _held_package != null:
			if session != null and session.has_method("request_player_drop"):
				if session.request_player_drop(self):
					_held_package = null
					_predicted_held_package = null
					_mark_network_request_sent()
				else:
					_start_cooldown()
			else:
				_drop_package()
				_start_cooldown()
		else:
			if session != null and session.has_method("request_player_grab"):
				var predicted_package: Package = _find_nearest_grabbable_package()
				if session.request_player_grab(self):
					_predicted_held_package = predicted_package
					_held_package = predicted_package
					_awaiting_grab_release = true
					_mark_network_request_sent()
				else:
					_predicted_held_package = null
					_held_package = null
					_awaiting_grab_release = false
					_start_cooldown()
			else:
				_try_grab_nearest_package()
				_start_cooldown()

	if handled_grab_this_frame:
		return

	if _held_package != null and InputManager.is_throw_pressed():
		if session != null and session.has_method("request_player_throw"):
			if session.request_player_throw(self, -basis.z.normalized() * throw_impulse_strength):
				_held_package = null
				_predicted_held_package = null
				_mark_network_request_sent()
			else:
				_start_cooldown()
		else:
			_throw_package()
			_start_cooldown()


func _try_grab_nearest_package() -> void:
	var nearest_package: Package = _find_nearest_grabbable_package()
	if nearest_package != null and nearest_package.request_grab(self, _local_requester_peer_id()):
		_held_package = nearest_package
		_predicted_held_package = null


func _find_nearest_grabbable_package() -> Package:
	var tree := get_tree()
	if tree == null:
		return null

	var nearest_package: Package = null
	var nearest_distance_squared := grab_range * grab_range

	for node in tree.get_nodes_in_group("packages"):
		if node == null or not is_instance_valid(node) or not node.is_inside_tree():
			continue
		if node is not Package:
			continue
		if not node.has_method("is_held") or not node.has_method("request_grab"):
			continue
		if node.is_held():
			continue

		var distance_squared := global_position.distance_squared_to(node.global_position)
		if distance_squared > nearest_distance_squared:
			continue

		nearest_package = node as Package
		nearest_distance_squared = distance_squared

	return nearest_package


func _drop_package() -> void:
	if _held_package == null or not is_instance_valid(_held_package):
		return

	if _held_package.has_method("request_drop"):
		_held_package.request_drop()
	_held_package = null
	_predicted_held_package = null


func _throw_package() -> void:
	if _held_package == null or not is_instance_valid(_held_package):
		return

	var throw_direction := -basis.z.normalized()
	if _held_package.has_method("request_drop"):
		_held_package.request_drop(throw_direction * throw_impulse_strength)
	_held_package = null
	_predicted_held_package = null


func _get_session() -> Node3D:
	if _session_cache != null and is_instance_valid(_session_cache) and _session_cache.is_inside_tree():
		return _session_cache

	var tree := get_tree()
	if tree == null:
		_session_cache = null
		return null

	for node in tree.get_nodes_in_group("warehouse_session"):
		if node is Node3D and node != null and is_instance_valid(node) and node.is_inside_tree():
			_session_cache = node as Node3D
			return _session_cache

	_session_cache = null
	return null


func _find_held_package_for_self() -> Package:
	var tree := get_tree()
	if tree == null:
		return null

	for node in tree.get_nodes_in_group("packages"):
		if node == null or not is_instance_valid(node) or not node.is_inside_tree():
			continue
		if node is not Package:
			continue
		if node.get("holder") == self:
			return node as Package
	return null


func _resolve_held_package() -> Package:
	if _held_package != null and is_instance_valid(_held_package) and _held_package.is_inside_tree():
		if _held_package.get("holder") == self:
			_predicted_held_package = null
			return _held_package

	var resolved_package: Package = _find_held_package_for_self()
	if resolved_package != null:
		_predicted_held_package = null
		return resolved_package

	if _predicted_held_package == null:
		return null
	if not is_instance_valid(_predicted_held_package) or not _predicted_held_package.is_inside_tree():
		_predicted_held_package = null
		return null

	var predicted_holder: Variant = _predicted_held_package.get("holder")
	if predicted_holder != null and predicted_holder != self:
		_predicted_held_package = null
		return null

	return _predicted_held_package


func _broadcast_state() -> void:
	if not _has_network_peer():
		return

	_sync_remote_state.rpc(global_position, basis, velocity)


@rpc("authority", "unreliable")
func _sync_remote_state(new_position: Vector3, new_basis: Basis, new_velocity: Vector3) -> void:
	if is_multiplayer_authority():
		return

	global_position = new_position
	basis = new_basis
	velocity = new_velocity


func _tick_runtime_state(delta: float) -> void:
	_update_identity_visuals()

	_interaction_cooldown_left = max(0.0, _interaction_cooldown_left - delta)
	if _waiting_for_network_action:
		_request_timeout_left = max(0.0, _request_timeout_left - delta)
	_update_visible_player_cache(delta)

	_held_package = _resolve_held_package()
	var is_holding_now := _held_package != null
	if is_holding_now != _last_holding_state:
		_waiting_for_network_action = false
		_request_timeout_left = 0.0
	_last_holding_state = is_holding_now

	if _waiting_for_network_action and is_zero_approx(_request_timeout_left):
		_waiting_for_network_action = false

	_update_runtime_status_label()


func _can_attempt_interaction() -> bool:
	if _interaction_cooldown_left > 0.0:
		return false
	if _waiting_for_network_action:
		return false
	return true


func _start_cooldown() -> void:
	_interaction_cooldown_left = interaction_cooldown


func _mark_network_request_sent() -> void:
	_start_cooldown()
	if not _has_network_peer():
		_waiting_for_network_action = false
		_request_timeout_left = 0.0
		return
	_waiting_for_network_action = true
	_request_timeout_left = network_request_timeout


func _update_visible_player_cache(delta: float) -> void:
	_player_count_refresh_left = max(0.0, _player_count_refresh_left - delta)
	if _player_count_refresh_left > 0.0:
		return

	_cached_visible_players = _compute_visible_player_count()
	_player_count_refresh_left = PLAYER_COUNT_REFRESH_INTERVAL


func _compute_visible_player_count() -> int:
	var tree := get_tree()
	if tree == null:
		return 0

	var count := 0
	for node in tree.get_nodes_in_group("players"):
		if node is Node3D and node.is_inside_tree():
			count += 1
	return count


func _has_network_peer() -> bool:
	var peer := multiplayer.multiplayer_peer
	if peer == null:
		return false
	return not peer is OfflineMultiplayerPeer


func _is_local_authority_safe() -> bool:
	if not _has_network_peer():
		return true
	return is_multiplayer_authority()


func _display_peer_id() -> int:
	var authority_id := get_multiplayer_authority()
	if authority_id <= 0:
		return 1
	if not _has_network_peer():
		return authority_id
	var network_manager := get_node_or_null("/root/NetworkManager")
	if network_manager != null and network_manager.has_method("get_peer_slot"):
		return int(network_manager.get_peer_slot(authority_id))
	return authority_id


func _local_requester_peer_id() -> int:
	if _has_network_peer():
		return multiplayer.get_unique_id()
	return _display_peer_id()


func _update_identity_visuals() -> void:
	var local_role := _is_local_authority_safe()
	var peer_id := _display_peer_id()
	var identity := "%s:%d" % ["LOCAL" if local_role else "REMOTE", peer_id]
	if identity == _last_identity_cache:
		return
	_last_identity_cache = identity

	var tint := LOCAL_COLOR if local_role else REMOTE_COLOR
	_debug_label.text = "P%d %s" % [peer_id, "LOCAL" if local_role else "REMOTE"]

	if _debug_material == null:
		var source_material := _visual_root.get_active_material(0)
		if source_material is StandardMaterial3D:
			_debug_material = source_material.duplicate()
			_visual_root.set_surface_override_material(0, _debug_material)

	if _debug_material != null:
		_debug_material.albedo_color = tint
		_debug_material.emission_enabled = true
		_debug_material.emission = tint * 0.35


func _update_runtime_status_label() -> void:
	var local_role := _is_local_authority_safe()
	var peer_id := _display_peer_id()
	var role_text := "LOCAL" if local_role else "REMOTE"
	var status_text := "READY"
	var label_color := LOCAL_COLOR if local_role else REMOTE_COLOR
	var visible_players := _cached_visible_players
	var roster_text := "N%d/%d" % [visible_players, expected_player_count]

	if _waiting_for_network_action:
		status_text = "WAIT %.2fs" % _request_timeout_left
		label_color = WAITING_COLOR
	elif _interaction_cooldown_left > 0.0:
		status_text = "CD %.2fs" % _interaction_cooldown_left
		label_color = COOLDOWN_COLOR
	elif _held_package != null:
		status_text = "HOLD"

	if visible_players < expected_player_count:
		roster_text += " MISSING"
		label_color = Color(1.0, 0.35, 0.35, 1.0)

	_debug_label.text = "P%d %s [%s] %s" % [peer_id, role_text, status_text, roster_text]
	_debug_label.modulate = label_color
