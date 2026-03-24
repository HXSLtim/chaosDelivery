extends RefCounted

const WAREHOUSE_SCENE := preload("res://scenes/levels/warehouse_test.tscn")

var _tree: SceneTree
var _failures: Array[String] = []


func run(tree: SceneTree) -> Array[String]:
	_tree = tree
	_failures.clear()

	await _test_dev_console_scene_exists_and_is_hidden_by_default()
	await _test_dev_console_toggles_and_reports_runtime_snapshot()

	return _failures


func _test_dev_console_scene_exists_and_is_hidden_by_default() -> void:
	var scene_resource := load("res://scenes/ui/dev_console.tscn")
	_assert(scene_resource != null, "dev console scene should exist")
	if scene_resource == null:
		return

	var root := Node.new()
	root.name = "DevConsoleDefaultRoot"
	_tree.root.add_child(root)

	var console = scene_resource.instantiate()
	root.add_child(console)
	await _tree.process_frame

	_assert(not console.visible, "dev console should stay hidden by default")

	root.queue_free()
	await _tree.process_frame


func _test_dev_console_toggles_and_reports_runtime_snapshot() -> void:
	var scene_resource := load("res://scenes/ui/dev_console.tscn")
	_assert(scene_resource != null, "dev console scene should exist for runtime snapshot test")
	if scene_resource == null:
		return

	var network_manager := _tree.root.get_node_or_null("NetworkManager")
	if network_manager != null:
		network_manager.leave_game()
		network_manager.connected_peers = {}
		network_manager.set("is_connected", false)
		network_manager.set("is_host", false)
		network_manager.set("is_connecting", false)
		network_manager.set("connection_state", 0)

	var session = WAREHOUSE_SCENE.instantiate()
	session.name = "DevConsoleSession"
	_tree.root.add_child(session)
	await _tree.process_frame
	await _tree.process_frame

	var console = scene_resource.instantiate()
	_tree.root.add_child(console)
	await _tree.process_frame

	var toggle_event := InputEventKey.new()
	toggle_event.keycode = KEY_F8
	toggle_event.pressed = true
	console._unhandled_input(toggle_event)
	console._refresh_console()

	var snapshot_label = console.get_node("Panel/Content/SnapshotLabel") as Label
	_assert(console.visible, "dev console should toggle visible on F8")
	_assert(snapshot_label != null, "dev console should expose a snapshot label")
	if snapshot_label != null:
		_assert(snapshot_label.text.contains("Players: 1"), "dev console should report current player count")
		_assert(snapshot_label.text.contains("Packages: 1"), "dev console should report current package count")
		_assert(snapshot_label.text.contains("Network:"), "dev console should include network state summary")

	console.queue_free()
	session.queue_free()
	await _tree.process_frame


func _assert(condition: bool, message: String) -> void:
	if condition:
		return
	_failures.append(message)
