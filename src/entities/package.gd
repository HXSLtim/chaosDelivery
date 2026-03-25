extends RigidBody3D
class_name Package

const RuntimeLog := preload("res://src/utils/runtime_log.gd")
const FRAGILE_GLOW_SHADER := preload("res://shaders/spatial/fragile_glow.gdshader")
const URGENT_PULSE_SHADER := preload("res://shaders/spatial/urgent_pulse.gdshader")

signal package_state_changed(new_state: State, previous_state: State)
signal package_holder_changed(holder: Node3D)

enum State {
	ON_GROUND,
	HELD,
	THROWN
}

@export var package_id: String = ""
@export var package_type: String = "normal"
@export var landing_linear_velocity_threshold_squared: float = 0.01
@export var landing_angular_velocity_threshold_squared: float = 0.01

var current_state: State = State.ON_GROUND
var authority_peer_id_hint: int = 1
var holder: Node3D = null

@onready var grabbable_component = get_node_or_null("GrabbableComponent")
@onready var _visual_root: Node = $VisualRoot
@onready var _visual_mesh: MeshInstance3D = _find_visual_mesh(_visual_root)


func _ready() -> void:
	add_to_group("packages")
	if package_id.is_empty():
		package_id = String(name)
	_apply_visual_profile()
	if grabbable_component == null:
		push_warning(RuntimeLog.warning_text("Package", "package scene missing GrabbableComponent", {
			"node": name
		}))
		return
	grabbable_component.grab_started.connect(_on_grab_started)
	grabbable_component.grab_ended.connect(_on_grab_ended)


func _process(_delta: float) -> void:
	_recover_stale_holder()


func _physics_process(_delta: float) -> void:
	_recover_stale_holder()
	_update_thrown_state()


func _recover_stale_holder() -> void:
	if grabbable_component == null:
		return

	var component_holder: Variant = grabbable_component.get_holder_node()
	var component_has_valid_holder: bool = component_holder != null and is_instance_valid(component_holder) and component_holder.is_inside_tree()
	var local_holder_valid: bool = holder != null and is_instance_valid(holder) and holder.is_inside_tree()

	if component_has_valid_holder:
		if holder != component_holder:
			holder = component_holder
			package_holder_changed.emit(holder)
		if current_state != State.HELD:
			_change_state(State.HELD)
		freeze = true
		return

	# 断线或重复 RPC 后可能残留陈旧持有状态，这里统一回收。
	if current_state == State.HELD or local_holder_valid or freeze:
		grabbable_component.force_clear_holder(Vector3.ZERO, get_owner_peer_id_hint())
		freeze = false
		if holder != null:
			holder = null
			package_holder_changed.emit(holder)
		if current_state == State.HELD:
			_change_state(State.ON_GROUND)


func _update_thrown_state() -> void:
	if current_state != State.THROWN:
		return
	if holder != null or freeze:
		return
	if linear_velocity.length_squared() > landing_linear_velocity_threshold_squared:
		return
	if angular_velocity.length_squared() > landing_angular_velocity_threshold_squared:
		return
	_change_state(State.ON_GROUND)


func request_grab(by: Node3D, requester_peer_id: int = 0) -> bool:
	if grabbable_component == null:
		return false
	_recover_stale_holder()
	if holder == by and by != null:
		return true
	return grabbable_component.try_grab(by, requester_peer_id)


func request_drop(impulse: Vector3 = Vector3.ZERO) -> bool:
	if grabbable_component == null:
		return false
	_recover_stale_holder()
	var dropped := bool(grabbable_component.try_drop(impulse))
	if dropped:
		return true
	# 重复 drop 不应被当作失败，保持幂等即可。
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
	# 后续如果升级更复杂的联网权限切换，可以从这里扩展。


func _apply_visual_profile() -> void:
	if _visual_mesh == null:
		return

	match package_type:
		"fragile":
			_visual_mesh.set_surface_override_material(0, _build_effect_material(
				FRAGILE_GLOW_SHADER,
				Color(0.55, 0.82, 1.0, 1.0)
			))
		"urgent":
			_visual_mesh.set_surface_override_material(0, _build_effect_material(
				URGENT_PULSE_SHADER,
				Color(1.0, 0.28, 0.12, 1.0)
			))
		_:
			_visual_mesh.set_surface_override_material(0, null)


func _build_effect_material(shader_resource: Shader, effect_color: Color) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = shader_resource

	var source_material := _visual_mesh.get_active_material(0)
	var base_color := Color(1.0, 1.0, 1.0, 1.0)
	var albedo_texture: Texture2D = null
	if source_material is BaseMaterial3D:
		base_color = source_material.albedo_color
		albedo_texture = source_material.albedo_texture

	material.set_shader_parameter("base_color", base_color)
	material.set_shader_parameter("albedo_texture", albedo_texture)
	if shader_resource == FRAGILE_GLOW_SHADER:
		material.set_shader_parameter("glow_color", effect_color)
	elif shader_resource == URGENT_PULSE_SHADER:
		material.set_shader_parameter("pulse_color", effect_color)
	return material


func _find_visual_mesh(node: Node) -> MeshInstance3D:
	if node == null:
		return null
	if node is MeshInstance3D:
		return node as MeshInstance3D
	for child in node.get_children():
		var visual_mesh := _find_visual_mesh(child)
		if visual_mesh != null:
			return visual_mesh
	return null


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
		var position_value: Variant = snapshot["position"]
		if position_value is Vector3:
			global_position = position_value
	if snapshot.has("basis"):
		var basis_value: Variant = snapshot["basis"]
		if basis_value is Basis:
			basis = basis_value
	if snapshot.has("linear_velocity"):
		var linear_velocity_value: Variant = snapshot["linear_velocity"]
		if linear_velocity_value is Vector3:
			linear_velocity = linear_velocity_value
	if snapshot.has("angular_velocity"):
		var angular_velocity_value: Variant = snapshot["angular_velocity"]
		if angular_velocity_value is Vector3:
			angular_velocity = angular_velocity_value
	if snapshot.has("freeze"):
		var freeze_value: Variant = snapshot["freeze"]
		if freeze_value is bool:
			freeze = freeze_value
		elif freeze_value is int:
			freeze = int(freeze_value) != 0

	var target_state := int(snapshot.get("state", int(current_state)))
	if grabbable_component != null:
		var holder_path_raw: Variant = snapshot.get("holder_path", "")
		var holder_path_text := String(holder_path_raw).strip_edges()
		if target_state == int(State.HELD) and holder_path_text != "":
			var holder_node := get_node_or_null(NodePath(holder_path_text)) as Node3D
			if holder_node != null:
				grabbable_component.force_set_holder(holder_node, get_owner_peer_id_hint())
			else:
				# 快照里的 holder 路径无效时，强制回退到干净的落地状态。
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
