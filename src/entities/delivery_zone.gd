extends Area3D
class_name DeliveryZone

signal package_delivered(package_id: String, order_id: String)
signal delivery_rejected(package_id: String, reason: String)

@export var destination_id: String = "A"
@export var auto_seed_static_order: bool = true
@export var static_order_package_type: String = "normal"

var _order_manager: Node = null
var _delivered_cache: Dictionary = {}


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	_order_manager = _find_order_manager()
	if _order_manager != null and auto_seed_static_order:
		_order_manager.ensure_static_order(static_order_package_type, destination_id)


func _on_body_entered(body: Node) -> void:
	if not _is_package(body):
		return

	var package_id := _extract_package_id(body)
	if _delivered_cache.has(package_id):
		return

	if _order_manager == null:
		_order_manager = _find_order_manager()
	if _order_manager == null:
		delivery_rejected.emit(package_id, "missing_order_manager")
		return

	var result: Dictionary = _order_manager.validate_delivery(body, destination_id)
	var is_ok := bool(result.get("ok", false))
	var order_id := String(result.get("order_id", ""))
	var reason := String(result.get("reason", "unknown"))

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


func _is_package(node: Node) -> bool:
	return node != null and node.is_in_group("packages")


func _extract_package_id(node: Node) -> String:
	if node == null:
		return ""
	var package_id: Variant = node.get("package_id")
	if package_id != null and String(package_id) != "":
		return String(package_id)
	return String(node.name)
