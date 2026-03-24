extends Area3D
class_name DeliveryZone

const EVENT_BUS_SCRIPT := preload("res://src/autoload/event_bus.gd")

signal package_delivered(package_id: String, order_id: String)
signal delivery_rejected(package_id: String, reason: String)

@export var destination_id: String = "A"
@export var auto_seed_static_order: bool = true
@export var static_order_package_type: String = "normal"

var _order_manager: Node = null
var _delivered_cache: Dictionary = {}
var _pending_landing_packages: Dictionary = {}


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	_order_manager = _find_order_manager()
	var event_bus := _get_event_bus()
	if event_bus != null and not event_bus.phase_changed.is_connected(_on_phase_changed):
		event_bus.phase_changed.connect(_on_phase_changed)
	if _order_manager != null and auto_seed_static_order:
		_order_manager.ensure_static_order(static_order_package_type, destination_id)


func _on_body_entered(body: Node) -> void:
	if body == null or not is_instance_valid(body):
		return

	if not _is_package(body):
		return

	var package_id := _extract_package_id(body)
	if package_id.is_empty():
		package_id = "unknown_package"
	if _delivered_cache.has(package_id):
		return

	var state_rejection_reason := _get_package_rejection_reason(body)
	if state_rejection_reason == "package_state_thrown":
		_track_pending_landing_package(body)
	else:
		_untrack_pending_landing_package(body)
	if not state_rejection_reason.is_empty():
		delivery_rejected.emit(package_id, state_rejection_reason)
		return

	_process_delivery(body, package_id)


func _on_body_exited(body: Node) -> void:
	_untrack_pending_landing_package(body)


func _process_delivery(body: Node, package_id: String) -> void:
	_untrack_pending_landing_package(body)

	if _order_manager == null or not is_instance_valid(_order_manager):
		_order_manager = _find_order_manager()
	if _order_manager == null:
		delivery_rejected.emit(package_id, "missing_order_manager")
		return
	if not _order_manager.has_method("validate_delivery"):
		delivery_rejected.emit(package_id, "invalid_order_manager")
		return

	var raw_result: Variant = _order_manager.validate_delivery(body, destination_id)
	if not (raw_result is Dictionary):
		delivery_rejected.emit(package_id, "invalid_validation_result")
		return

	var result: Dictionary = raw_result
	var is_ok := bool(result.get("ok", false))
	var order_id := String(result.get("order_id", ""))
	var reason := String(result.get("reason", ""))
	if reason.is_empty():
		reason = "validation_rejected"

	if is_ok:
		_delivered_cache[package_id] = true
		package_delivered.emit(package_id, order_id)
	else:
		delivery_rejected.emit(package_id, reason)


func _find_order_manager() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	var node := tree.get_first_node_in_group("order_manager")
	return node


func _get_event_bus() -> Node:
	return get_node_or_null("/root/EventBus")


func _on_phase_changed(new_phase: int, _old_phase: int) -> void:
	if new_phase == int(EVENT_BUS_SCRIPT.GamePhase.PREPARATION) or new_phase == int(EVENT_BUS_SCRIPT.GamePhase.LOBBY):
		reset_delivery_tracking()


func reset_delivery_tracking() -> void:
	_delivered_cache.clear()
	_clear_pending_landing_tracking()


func _is_package(node: Node) -> bool:
	return node != null and is_instance_valid(node) and node.is_in_group("packages")


func _get_package_rejection_reason(node: Node) -> String:
	if _is_package_held(node):
		return "package_state_held"
	if _is_package_frozen(node):
		return "package_state_frozen"
	if _is_package_thrown(node):
		return "package_state_thrown"
	return ""


func _is_package_held(node: Node) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	if node.has_method("is_held"):
		return bool(node.call("is_held"))
	return false


func _is_package_frozen(node: Node) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	var freeze_state: Variant = node.get("freeze")
	if freeze_state is bool:
		return bool(freeze_state)
	if freeze_state is int:
		return int(freeze_state) != 0
	return false


func _is_package_thrown(node: Node) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	if node.has_method("is_thrown"):
		return bool(node.call("is_thrown"))
	return false


func _extract_package_id(node: Node) -> String:
	if node == null or not is_instance_valid(node):
		return ""
	var package_id: Variant = node.get("package_id")
	if package_id != null and String(package_id) != "":
		return String(package_id)
	var fallback_name := String(node.name)
	if fallback_name != "":
		return fallback_name
	return "instance_%d" % node.get_instance_id()


func _track_pending_landing_package(node: Node) -> void:
	if node == null or not is_instance_valid(node):
		return
	if not node.has_signal("package_state_changed"):
		return

	var package_key := node.get_instance_id()
	if _pending_landing_packages.has(package_key):
		return

	var state_changed_callable := Callable(self, "_on_tracked_package_state_changed").bind(node)
	_pending_landing_packages[package_key] = {
		"node": node,
		"callable": state_changed_callable
	}
	if not node.is_connected("package_state_changed", state_changed_callable):
		node.connect("package_state_changed", state_changed_callable)


func _untrack_pending_landing_package(node: Node) -> void:
	if node == null:
		return

	var package_key := node.get_instance_id()
	if not _pending_landing_packages.has(package_key):
		return

	var entry: Dictionary = _pending_landing_packages.get(package_key, {})
	var state_changed_callable: Callable = entry.get("callable", Callable())
	_pending_landing_packages.erase(package_key)
	if is_instance_valid(node) and node.has_signal("package_state_changed") and node.is_connected("package_state_changed", state_changed_callable):
		node.disconnect("package_state_changed", state_changed_callable)


func _clear_pending_landing_tracking() -> void:
	for package_key in _pending_landing_packages.keys():
		var entry: Dictionary = _pending_landing_packages.get(package_key, {})
		var body: Node = entry.get("node", null)
		var state_changed_callable: Callable = entry.get("callable", Callable())
		if body != null and is_instance_valid(body) and body.has_signal("package_state_changed") and body.is_connected("package_state_changed", state_changed_callable):
			body.disconnect("package_state_changed", state_changed_callable)
	_pending_landing_packages.clear()


func _on_tracked_package_state_changed(new_state: Variant, _previous_state: Variant, node: Node) -> void:
	if node == null or not is_instance_valid(node):
		_untrack_pending_landing_package(node)
		return
	var state_int := int(new_state) if new_state is int else int(Package.State.ON_GROUND)
	if state_int != int(Package.State.ON_GROUND):
		return

	_untrack_pending_landing_package(node)
	_on_body_entered(node)
