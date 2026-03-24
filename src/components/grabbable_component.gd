extends Node
class_name GrabbableComponent

signal grab_started(holder: Node3D, owner_peer_id: int)
signal grab_ended(impulse: Vector3, fallback_owner_peer_id: int)

@export var holder_anchor_path: NodePath
@export var fallback_owner_peer_id: int = 1
@export var holder_validation_interval: float = 0.08

var owner_peer_id: int = 1
var holder: Node3D = null

var _package: RigidBody3D
var _original_parent: Node = null
var _hold_target: Node3D = null
var _holder_validation_elapsed: float = 0.0


func _ready() -> void:
	_package = get_parent() as RigidBody3D
	if _package == null:
		push_warning("GrabbableComponent must be a direct child of Package.")
		return
	_original_parent = _package.get_parent()


func _physics_process(delta: float) -> void:
	if _package == null:
		return
	_holder_validation_elapsed += maxf(delta, 0.0)
	if _holder_validation_elapsed >= maxf(holder_validation_interval, 0.01):
		_holder_validation_elapsed = 0.0
		_recover_if_holder_stale()
	if not _has_valid_holder():
		return
	if _hold_target == null or not is_instance_valid(_hold_target):
		_hold_target = _resolve_attach_target(holder)
	if _hold_target == null:
		return

	# Keep the package in its authoritative parent branch and only follow transform.
	_package.global_position = _hold_target.global_position
	_package.global_rotation = _hold_target.global_rotation


func can_grab(by: Node3D, requester_peer_id: int = 0, max_distance: float = -1.0) -> bool:
	if _package == null or by == null:
		return false
	if not is_instance_valid(by) or not by.is_inside_tree():
		return false
	_recover_if_holder_stale()
	if _has_valid_holder():
		# Idempotent path: same holder re-requesting grab is treated as valid.
		return holder == by
	if max_distance > 0.0 and _package.global_position.distance_to(by.global_position) > max_distance:
		return false
	if requester_peer_id < 0:
		return false
	return true


func can_drop() -> bool:
	if _package == null:
		return false
	_recover_if_holder_stale()
	return _has_valid_holder() or _package.freeze


func get_owner_peer_id() -> int:
	return owner_peer_id


func get_holder_node() -> Node3D:
	if not _has_valid_holder():
		return null
	return holder


func get_holder_path() -> NodePath:
	if not _has_valid_holder():
		return NodePath("")
	return holder.get_path()


func try_grab(by: Node3D, requester_peer_id: int = 0) -> bool:
	if not can_grab(by, requester_peer_id):
		return false

	return force_set_holder(by, requester_peer_id)


func try_drop(impulse: Vector3 = Vector3.ZERO) -> bool:
	if not can_drop():
		# Idempotent path: already-released package should not fail repeated drop requests.
		return holder == null and _package != null and not _package.freeze

	return force_clear_holder(impulse)


func force_set_holder(by: Node3D, new_owner_peer_id: int = 0) -> bool:
	if _package == null or by == null:
		return false
	if not is_instance_valid(by) or not by.is_inside_tree():
		return false
	_recover_if_holder_stale()
	if _has_valid_holder() and holder == by:
		owner_peer_id = new_owner_peer_id if new_owner_peer_id > 0 else owner_peer_id
		_package.freeze = true
		_package.linear_velocity = Vector3.ZERO
		_package.angular_velocity = Vector3.ZERO
		_hold_target = _resolve_attach_target(by)
		_attach_to_holder(by)
		return true
	if _has_valid_holder() and holder != by:
		force_clear_holder(Vector3.ZERO)

	if _original_parent == null or not is_instance_valid(_original_parent):
		_original_parent = _package.get_parent()
	elif _package.get_parent() != _original_parent:
		_package.reparent(_original_parent, true)
	holder = by
	owner_peer_id = new_owner_peer_id if new_owner_peer_id > 0 else fallback_owner_peer_id
	_hold_target = _resolve_attach_target(by)
	_holder_validation_elapsed = 0.0

	# Local prototype behavior: freeze physics and attach under the holder anchor.
	_package.freeze = true
	_package.linear_velocity = Vector3.ZERO
	_package.angular_velocity = Vector3.ZERO
	_attach_to_holder(by)

	grab_started.emit(holder, owner_peer_id)
	return true


func force_clear_holder(impulse: Vector3 = Vector3.ZERO, owner_peer_id_override: int = -1) -> bool:
	if _package == null:
		return false
	var had_holder_ref := holder != null
	var had_freeze := _package.freeze

	var drop_parent := _resolve_drop_parent()
	if drop_parent != null and _package.get_parent() != drop_parent:
		_package.reparent(drop_parent, true)

	_package.freeze = false
	if impulse.length_squared() > 0.0001:
		_package.apply_central_impulse(impulse)

	holder = null
	_hold_target = null
	owner_peer_id = owner_peer_id_override if owner_peer_id_override > 0 else fallback_owner_peer_id
	_holder_validation_elapsed = 0.0
	if had_holder_ref or had_freeze or impulse.length_squared() > 0.0001:
		grab_ended.emit(impulse, owner_peer_id)
	return true


func _attach_to_holder(by: Node3D) -> void:
	if _hold_target == null:
		_hold_target = _resolve_attach_target(by)
	if _hold_target == null:
		return
	if _original_parent == null or not is_instance_valid(_original_parent):
		_original_parent = _package.get_parent()
	elif _package.get_parent() != _original_parent:
		_package.reparent(_original_parent, true)
	_package.global_position = _hold_target.global_position
	_package.global_rotation = _hold_target.global_rotation


func _resolve_attach_target(by: Node3D) -> Node3D:
	if holder_anchor_path != NodePath(""):
		var explicit_anchor := by.get_node_or_null(holder_anchor_path) as Node3D
		if explicit_anchor != null:
			return explicit_anchor

	var named_anchor := by.get_node_or_null("HoldAnchor") as Node3D
	if named_anchor != null:
		return named_anchor

	return by


func _resolve_drop_parent() -> Node:
	if is_instance_valid(_original_parent):
		return _original_parent

	var tree := get_tree()
	if tree != null and tree.current_scene != null:
		return tree.current_scene

	return _package.get_tree().root if _package != null else null


func _has_valid_holder() -> bool:
	return holder != null and is_instance_valid(holder) and holder.is_inside_tree()


func _recover_if_holder_stale() -> void:
	if holder == null:
		return
	if _has_valid_holder():
		return
	# Stale holder reference can happen after disconnect/free. Force a clean release so
	# package-level listeners clear their own holder state too.
	force_clear_holder(Vector3.ZERO)
