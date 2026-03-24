extends RefCounted
class_name HudSignalBinder


static func rebind(current_node: Node, next_node: Node, specs: Array[Dictionary]) -> Node:
	if current_node == next_node:
		return next_node
	_disconnect_specs(current_node, specs)
	_connect_specs(next_node, specs)
	return next_node


static func _connect_specs(node: Node, specs: Array[Dictionary]) -> void:
	if node == null:
		return
	for spec in specs:
		var signal_name: StringName = spec.get("signal_name", &"")
		var callable: Callable = spec.get("callable", Callable())
		if signal_name == &"" or callable.is_null():
			continue
		if not node.has_signal(signal_name):
			continue
		if node.is_connected(signal_name, callable):
			continue
		node.connect(signal_name, callable)


static func _disconnect_specs(node: Node, specs: Array[Dictionary]) -> void:
	if node == null:
		return
	for spec in specs:
		var signal_name: StringName = spec.get("signal_name", &"")
		var callable: Callable = spec.get("callable", Callable())
		if signal_name == &"" or callable.is_null():
			continue
		if not node.has_signal(signal_name):
			continue
		if not node.is_connected(signal_name, callable):
			continue
		node.disconnect(signal_name, callable)
