extends CharacterBody3D

@export var move_speed: float = 4.5
@export var acceleration: float = 18.0
@export var deceleration: float = 24.0
@export var gravity_scale: float = 1.0
@export var grab_range: float = 2.0
@export var throw_impulse_strength: float = 4.5

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var _last_input: Vector2 = Vector2.ZERO
var _held_package = null


func _physics_process(delta: float) -> void:
	if multiplayer.multiplayer_peer != null and not is_multiplayer_authority():
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
	_held_package = _find_held_package_for_self()
	var session := _get_session()

	if InputManager.is_grab_pressed():
		if _held_package != null:
			if session != null and session.has_method("request_player_drop"):
				if session.request_player_drop(self):
					_held_package = null
			else:
				_drop_package()
		else:
			if session != null and session.has_method("request_player_grab"):
				session.request_player_grab(self)
			else:
				_try_grab_nearest_package()

	if _held_package != null and InputManager.is_throw_pressed():
		if session != null and session.has_method("request_player_throw"):
			if session.request_player_throw(self, -basis.z.normalized() * throw_impulse_strength):
				_held_package = null
		else:
			_throw_package()


func _try_grab_nearest_package() -> void:
	var nearest_package = null
	var nearest_distance_squared := grab_range * grab_range

	for node in get_tree().get_nodes_in_group("packages"):
		if node == null or not node.has_method("is_held"):
			continue
		if node.is_held():
			continue

		var distance_squared := global_position.distance_squared_to(node.global_position)
		if distance_squared > nearest_distance_squared:
			continue

		nearest_package = node
		nearest_distance_squared = distance_squared

	if nearest_package != null and nearest_package.request_grab(self, multiplayer.get_unique_id()):
		_held_package = nearest_package


func _drop_package() -> void:
	if _held_package == null:
		return

	_held_package.request_drop()
	_held_package = null


func _throw_package() -> void:
	if _held_package == null:
		return

	var throw_direction := -basis.z.normalized()
	_held_package.request_drop(throw_direction * throw_impulse_strength)
	_held_package = null


func _get_session() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	return tree.get_first_node_in_group("warehouse_session")


func _find_held_package_for_self():
	for node in get_tree().get_nodes_in_group("packages"):
		if node == null:
			continue
		if node.get("holder") == self:
			return node
	return null


func _broadcast_state() -> void:
	if multiplayer.multiplayer_peer == null:
		return

	_sync_remote_state.rpc(global_position, basis, velocity)


@rpc("authority", "unreliable")
func _sync_remote_state(new_position: Vector3, new_basis: Basis, new_velocity: Vector3) -> void:
	if is_multiplayer_authority():
		return

	global_position = new_position
	basis = new_basis
	velocity = new_velocity
