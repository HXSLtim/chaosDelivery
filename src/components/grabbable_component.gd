extends Node
class_name GrabbableComponent

signal grab_started(holder: Node3D, owner_peer_id: int)
signal grab_ended(impulse: Vector3, fallback_owner_peer_id: int)

@export var holder_anchor_path: NodePath
@export var fallback_owner_peer_id: int = 1

var owner_peer_id: int = 1
var holder: Node3D = null

var _package: RigidBody3D
var _original_parent: Node = null


func _ready() -> void:
	_package = get_parent() as RigidBody3D
	if _package == null:
		push_warning("GrabbableComponent must be a direct child of Package.")


func can_grab(by: Node3D, requester_peer_id: int = 0, max_distance: float = -1.0) -> bool:
	if _package == null or by == null:
		return false
	if holder != null:
		return false
	if max_distance > 0.0 and _package.global_position.distance_to(by.global_position) > max_distance:
		return false
	if requester_peer_id < 0:
		return false
	return true


func can_drop() -> bool:
	return _package != null and holder != null


func get_owner_peer_id() -> int:
	return owner_peer_id


func get_holder_node() -> Node3D:
	return holder


func get_holder_path() -> NodePath:
	if holder == null:
		return NodePath("")
	return holder.get_path()


func try_grab(by: Node3D, requester_peer_id: int = 0) -> bool:
	if not can_grab(by, requester_peer_id):
		return false

	return force_set_holder(by, requester_peer_id)


func try_drop(impulse: Vector3 = Vector3.ZERO) -> bool:
	if not can_drop():
		return false

	return force_clear_holder(impulse)


func force_set_holder(by: Node3D, new_owner_peer_id: int = 0) -> bool:
	if _package == null or by == null:
		return false

	_original_parent = _package.get_parent()
	holder = by
	owner_peer_id = new_owner_peer_id if new_owner_peer_id > 0 else fallback_owner_peer_id

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
	if holder == null:
		if owner_peer_id_override > 0:
			owner_peer_id = owner_peer_id_override
		return false

	var drop_parent := _resolve_drop_parent()
	if drop_parent != null:
		_package.reparent(drop_parent, true)

	_package.freeze = false
	if impulse.length_squared() > 0.0001:
		_package.apply_central_impulse(impulse)

	holder = null
	owner_peer_id = owner_peer_id_override if owner_peer_id_override > 0 else fallback_owner_peer_id
	grab_ended.emit(impulse, owner_peer_id)
	return true


func _attach_to_holder(by: Node3D) -> void:
	var attach_target := _resolve_attach_target(by)
	if attach_target == null:
		return
	_package.reparent(attach_target, true)
	_package.global_position = attach_target.global_position
	_package.global_rotation = attach_target.global_rotation


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
