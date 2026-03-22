extends Node
class_name OrderManager

const DEFAULT_STATIC_ORDER_ID := "order_static_1"

signal order_created(order_id: String, order: Dictionary)
signal order_marked_completed(order_id: String, order: Dictionary)
signal orders_cleared
signal orders_changed(reason: String, order_id: String, pending_count: int, total_count: int)
signal pending_count_changed(pending_count: int)

var active_orders: Array[Dictionary] = []
var _next_order_index: int = 1

func _ready() -> void:
	add_to_group("order_manager")


func create_order(package_type: String = "normal", destination: String = "A") -> String:
	var order_id := "order_%d" % _next_order_index
	_next_order_index += 1

	var order := {
		"id": order_id,
		"package_type": package_type,
		"destination": destination,
		"is_completed": false
	}
	active_orders.append(order)
	_emit_order_created(order_id, order)
	var event_bus := _get_event_bus()
	if event_bus != null:
		event_bus.order_added.emit(order_id)
	_emit_order_change("created", order_id)
	return order_id

func complete_order(order_id: String) -> bool:
	for i in active_orders.size():
		var order: Dictionary = active_orders[i]
		if order.get("id", "") != order_id:
			continue
		if order.get("is_completed", false):
			return false
		order["is_completed"] = true
		active_orders[i] = order
		emit_signal("order_marked_completed", order_id, order)
		var event_bus := _get_event_bus()
		if event_bus != null:
			event_bus.order_completed.emit(order_id)
		_emit_order_change("completed", order_id)
		return true
	return false

func clear_orders() -> void:
	var had_orders := not active_orders.is_empty()
	active_orders.clear()
	_next_order_index = 1
	if had_orders:
		emit_signal("orders_cleared")
		_emit_order_change("cleared", "")


func ensure_static_order(package_type: String = "normal", destination: String = "A") -> String:
	for order in active_orders:
		if order.get("id", "") == DEFAULT_STATIC_ORDER_ID:
			return DEFAULT_STATIC_ORDER_ID

	var order := {
		"id": DEFAULT_STATIC_ORDER_ID,
		"package_type": package_type,
		"destination": destination,
		"is_completed": false
	}
	active_orders.append(order)
	_emit_order_created(DEFAULT_STATIC_ORDER_ID, order)
	var event_bus := _get_event_bus()
	if event_bus != null:
		event_bus.order_added.emit(DEFAULT_STATIC_ORDER_ID)
	_emit_order_change("created", DEFAULT_STATIC_ORDER_ID)
	return DEFAULT_STATIC_ORDER_ID


func get_first_pending_order() -> Dictionary:
	for order in active_orders:
		if not order.get("is_completed", false):
			return order
	return {}

func get_pending_order_count() -> int:
	var pending_count := 0
	for order in active_orders:
		if not order.get("is_completed", false):
			pending_count += 1
	return pending_count


func validate_delivery(package_node: Node, destination: String) -> Dictionary:
	var pending_order := get_first_pending_order()
	if pending_order.is_empty():
		return {
			"ok": false,
			"reason": "no_pending_order",
			"order_id": "",
			"package_id": _extract_package_id(package_node)
		}

	var expected_destination := String(pending_order.get("destination", ""))
	if expected_destination != destination:
		return {
			"ok": false,
			"reason": "destination_mismatch",
			"order_id": String(pending_order.get("id", "")),
			"package_id": _extract_package_id(package_node)
		}

	var expected_type := String(pending_order.get("package_type", "normal"))
	var package_type := _extract_package_type(package_node)
	if expected_type != package_type:
		return {
			"ok": false,
			"reason": "package_type_mismatch",
			"order_id": String(pending_order.get("id", "")),
			"package_id": _extract_package_id(package_node)
		}

	var completed_order_id := String(pending_order.get("id", ""))
	if complete_order(completed_order_id):
		return {
			"ok": true,
			"reason": "accepted",
			"order_id": completed_order_id,
			"package_id": _extract_package_id(package_node)
		}

	return {
		"ok": false,
		"reason": "complete_failed",
		"order_id": completed_order_id,
		"package_id": _extract_package_id(package_node)
	}


func _extract_package_id(package_node: Node) -> String:
	if package_node == null:
		return ""
	if package_node.has_method("get"):
		var id_value: Variant = package_node.get("package_id")
		if id_value != null and String(id_value) != "":
			return String(id_value)
	return String(package_node.name)


func _extract_package_type(package_node: Node) -> String:
	if package_node == null:
		return "normal"
	if package_node.has_method("get"):
		var type_value: Variant = package_node.get("package_type")
		if type_value != null and String(type_value) != "":
			return String(type_value)
	return "normal"


func _get_event_bus() -> Node:
	return get_node_or_null("/root/EventBus")


func _emit_order_created(order_id: String, order: Dictionary) -> void:
	emit_signal("order_created", order_id, order)


func _emit_order_change(reason: String, order_id: String) -> void:
	var pending_count := get_pending_order_count()
	emit_signal("orders_changed", reason, order_id, pending_count, active_orders.size())
	emit_signal("pending_count_changed", pending_count)
