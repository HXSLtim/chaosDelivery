extends RigidBody3D
class_name Package

signal package_state_changed(new_state: State, previous_state: State)
signal package_holder_changed(holder: Node3D)

enum State {
	ON_GROUND,
	HELD,
	THROWN
}

@export var package_id: String = ""
@export var package_type: String = "normal"

var current_state: State = State.ON_GROUND
var authority_peer_id_hint: int = 1
var holder: Node3D = null

@onready var grabbable_component = get_node_or_null("GrabbableComponent")


func _ready() -> void:
	add_to_group("packages")
	if package_id.is_empty():
		package_id = String(name)
	if grabbable_component == null:
		push_warning("Package scene is missing GrabbableComponent.")
		return
	grabbable_component.grab_started.connect(_on_grab_started)
	grabbable_component.grab_ended.connect(_on_grab_ended)


func _process(_delta: float) -> void:
	_recover_stale_holder()


func _physics_process(_delta: float) -> void:
	_recover_stale_holder()


func _recover_stale_holder() -> void:
	if grabbable_component == null:
		return

	# Defensive recovery for stale runtime state after disconnects or duplicate RPCs.
	var holder_invalid := holder == null or not is_instance_valid(holder) or not holder.is_inside_tree()
	if current_state == State.HELD and holder_invalid:
		grabbable_component.force_clear_holder(Vector3.ZERO, get_owner_peer_id_hint())
		freeze = false
		holder = null
		_change_state(State.ON_GROUND)


func request_grab(by: Node3D, requester_peer_id: int = 0) -> bool:
	if grabbable_component == null:
		return false
	if holder == by and by != null:
		return true
	return grabbable_component.try_grab(by, requester_peer_id)


func request_drop(impulse: Vector3 = Vector3.ZERO) -> bool:
	if grabbable_component == null:
		return false
	var dropped := bool(grabbable_component.try_drop(impulse))
	if dropped:
		return true
	# Idempotent path: package already in released state should not be treated as failure.
	return holder == null and not freeze


func can_accept_grab_request(by: Node3D, requester_peer_id: int = 0, max_distance: float = -1.0) -> bool:
	if grabbable_component == null:
		return false
	return grabbable_component.can_grab(by, requester_peer_id, max_distance)


func can_accept_drop_request() -> bool:
	if grabbable_component == null:
		return false
	return grabbable_component.can_drop()


func get_state() -> State:
	return current_state


func get_state_name() -> String:
	match current_state:
		State.ON_GROUND:
			return "ON_GROUND"
		State.HELD:
			return "HELD"
		State.THROWN:
			return "THROWN"
	return "UNKNOWN"


func is_held() -> bool:
	return holder != null


func is_on_ground() -> bool:
	return current_state == State.ON_GROUND


func is_thrown() -> bool:
	return current_state == State.THROWN


func has_holder() -> bool:
	return holder != null


func get_holder_path() -> NodePath:
	if grabbable_component == null:
		return NodePath("")
	return grabbable_component.get_holder_path()


func get_owner_peer_id_hint() -> int:
	if grabbable_component != null:
		return grabbable_component.get_owner_peer_id()
	return authority_peer_id_hint


func set_authority_peer_id_hint(peer_id: int) -> void:
	authority_peer_id_hint = peer_id
	# For networked play later, this is where we can move authority ownership.


func _change_state(new_state: State) -> void:
	if new_state == current_state:
		return
	var previous_state := current_state
	current_state = new_state
	package_state_changed.emit(new_state, previous_state)


func get_network_snapshot() -> Dictionary:
	return {
		"package_id": package_id,
		"state": int(current_state),
		"authority_peer_id_hint": get_owner_peer_id_hint(),
		"holder_path": str(get_holder_path()),
		"position": global_position,
		"basis": basis,
		"linear_velocity": linear_velocity,
		"angular_velocity": angular_velocity,
		"freeze": freeze
	}


func apply_network_snapshot(snapshot: Dictionary) -> void:
	if snapshot.has("package_id"):
		package_id = str(snapshot.get("package_id", package_id))

	if snapshot.has("authority_peer_id_hint"):
		set_authority_peer_id_hint(int(snapshot.get("authority_peer_id_hint", authority_peer_id_hint)))

	if snapshot.has("position"):
		global_position = snapshot["position"]
	if snapshot.has("basis"):
		basis = snapshot["basis"]
	if snapshot.has("linear_velocity"):
		linear_velocity = snapshot["linear_velocity"]
	if snapshot.has("angular_velocity"):
		angular_velocity = snapshot["angular_velocity"]
	if snapshot.has("freeze"):
		freeze = bool(snapshot["freeze"])

	var target_state := int(snapshot.get("state", int(current_state)))
	if grabbable_component != null:
		var holder_path_text := String(snapshot.get("holder_path", ""))
		if target_state == int(State.HELD) and holder_path_text != "":
			var holder_node := get_node_or_null(NodePath(holder_path_text)) as Node3D
			if holder_node != null:
				grabbable_component.force_set_holder(holder_node, get_owner_peer_id_hint())
			else:
				# Invalid holder path in snapshot: force a clean release state.
				grabbable_component.force_clear_holder(Vector3.ZERO, get_owner_peer_id_hint())
				target_state = int(State.ON_GROUND)
		else:
			grabbable_component.force_clear_holder(Vector3.ZERO, get_owner_peer_id_hint())
			if target_state == int(State.HELD):
				target_state = int(State.ON_GROUND)

	if target_state >= int(State.ON_GROUND) and target_state <= int(State.THROWN):
		_change_state(target_state as State)


func _on_grab_started(new_holder: Node3D, new_owner_peer_id: int) -> void:
	holder = new_holder
	set_authority_peer_id_hint(new_owner_peer_id)
	_change_state(State.HELD)
	package_holder_changed.emit(holder)


func _on_grab_ended(impulse: Vector3, fallback_owner_peer_id: int) -> void:
	holder = null
	set_authority_peer_id_hint(fallback_owner_peer_id)
	if impulse.length_squared() > 0.0001:
		_change_state(State.THROWN)
	else:
		_change_state(State.ON_GROUND)
	package_holder_changed.emit(holder)
