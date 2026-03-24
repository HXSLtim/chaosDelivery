extends RefCounted

const PLAYER_SCENE := preload("res://scenes/entities/player.tscn")
const PACKAGE_SCENE := preload("res://scenes/entities/package.tscn")

var _tree: SceneTree
var _failures: Array[String] = []


func run(tree: SceneTree) -> Array[String]:
	_tree = tree
	_failures.clear()

	await _test_input_manager_default_actions_keep_expected_bindings()
	await _test_player_grab_selects_nearest_package_within_range()
	await _test_player_grab_ignores_packages_out_of_range()
	await _test_same_frame_grab_and_throw_input_drops_without_throwing()
	await _test_player_display_peer_id_maps_large_authority_to_stable_slot()
	await _test_player_runtime_labels_use_stable_peer_slots_when_networked()

	return _failures


func _test_input_manager_default_actions_keep_expected_bindings() -> void:
	var core_actions := InputManager.get_core_actions()
	_assert(core_actions.size() >= 7, "core input actions should include movement and interaction actions")

	for action_name in core_actions:
		_assert(InputMap.has_action(action_name), "input action should exist: %s" % String(action_name))

	_assert(_action_has_key(InputManager.ACTION_GRAB, KEY_E), "grab action should keep KEY_E binding")
	_assert(_action_has_key(InputManager.ACTION_THROW, KEY_F), "throw action should keep KEY_F binding")
	_assert(_action_has_key(InputManager.ACTION_MOVE_FORWARD, KEY_W), "move_forward action should keep KEY_W binding")
	_assert(_action_has_key(InputManager.ACTION_MOVE_BACKWARD, KEY_S), "move_backward action should keep KEY_S binding")


func _test_player_grab_selects_nearest_package_within_range() -> void:
	var world := _make_world("NearestGrabSelection")
	var player = PLAYER_SCENE.instantiate()
	player.name = "PlayerNearest"
	player.grab_range = 2.5
	world.add_child(player)

	var near_package = PACKAGE_SCENE.instantiate()
	near_package.name = "PkgNear"
	world.get_node("Packages").add_child(near_package)

	var farther_package = PACKAGE_SCENE.instantiate()
	farther_package.name = "PkgFarther"
	world.get_node("Packages").add_child(farther_package)
	await _tree.process_frame
	player.global_position = Vector3.ZERO
	near_package.global_position = Vector3(1.0, 0.0, 0.0)
	farther_package.global_position = Vector3(2.0, 0.0, 0.0)
	await _tree.process_frame

	player._try_grab_nearest_package()

	_assert(near_package.holder == player, "nearest package should be held after grab attempt")
	_assert(farther_package.holder == null, "farther package should remain unheld when nearest package is available")

	world.queue_free()
	await _tree.process_frame


func _test_player_grab_ignores_packages_out_of_range() -> void:
	var world := _make_world("OutOfRangeGrab")
	var player = PLAYER_SCENE.instantiate()
	player.name = "PlayerRange"
	player.grab_range = 1.5
	world.add_child(player)

	var package = PACKAGE_SCENE.instantiate()
	package.name = "PkgOutOfRange"
	world.get_node("Packages").add_child(package)
	await _tree.process_frame
	player.global_position = Vector3.ZERO
	package.global_position = Vector3(3.0, 0.0, 0.0)
	await _tree.process_frame

	player._try_grab_nearest_package()

	_assert(package.holder == null, "out-of-range package should not be grabbed")
	_assert(not package.freeze, "out-of-range package should remain unfrozen")

	world.queue_free()
	await _tree.process_frame


func _test_same_frame_grab_and_throw_input_drops_without_throwing() -> void:
	var world := _make_world("GrabThrowConflict")
	var player = PLAYER_SCENE.instantiate()
	player.name = "PlayerConflict"
	player.grab_range = 3.0
	world.add_child(player)

	var package = PACKAGE_SCENE.instantiate()
	package.name = "PkgHeld"
	world.get_node("Packages").add_child(package)
	await _tree.process_frame
	player.global_position = Vector3.ZERO
	package.global_position = Vector3(0.8, 0.0, 0.0)
	await _tree.process_frame

	_assert(package.request_grab(player, 1), "setup should start with held package")
	Input.action_press(String(InputManager.ACTION_GRAB))
	Input.action_press(String(InputManager.ACTION_THROW))
	player._physics_process(1.0 / 60.0)
	Input.action_release(String(InputManager.ACTION_GRAB))
	Input.action_release(String(InputManager.ACTION_THROW))

	_assert(package.holder == null, "same-frame grab/throw should drop held package")
	_assert(package.get_state() == package.State.ON_GROUND, "same-frame grab/throw should not transition package into THROWN")

	world.queue_free()
	await _tree.process_frame


func _test_player_display_peer_id_maps_large_authority_to_stable_slot() -> void:
	var network_manager := _tree.root.get_node_or_null("NetworkManager")
	_assert(network_manager != null, "NetworkManager should exist for player display peer slot test")
	if network_manager == null:
		return

	network_manager.leave_game()
	_assert(network_manager.host_game() == OK, "setup should host a local session for player display peer slot test")
	network_manager.connected_peers = {
		1: true,
		1096654874: true
	}

	var world := _make_world("PlayerDisplayPeerSlots")
	var remote_player = PLAYER_SCENE.instantiate()
	remote_player.name = "1096654874"
	remote_player.set_multiplayer_authority(1096654874)
	world.add_child(remote_player)
	await _tree.process_frame

	_assert(remote_player._display_peer_id() == 2, "player display peer id should map large authority ids to stable slot numbers")

	world.queue_free()
	await _tree.process_frame
	network_manager.leave_game()


func _test_player_runtime_labels_use_stable_peer_slots_when_networked() -> void:
	var network_manager := _tree.root.get_node_or_null("NetworkManager")
	_assert(network_manager != null, "NetworkManager should exist for player runtime label slot test")
	if network_manager == null:
		return

	network_manager.leave_game()
	network_manager.connected_peers = {}
	_assert(network_manager.host_game() == OK, "setup should host a local session for networked label test")
	network_manager.connected_peers = {
		1: true,
		1096654874: true
	}

	var world := _make_world("NetworkedPlayerRuntimeLabels")
	var local_player = PLAYER_SCENE.instantiate()
	local_player.name = "1"
	local_player.set_multiplayer_authority(1)
	world.add_child(local_player)

	var remote_player = PLAYER_SCENE.instantiate()
	remote_player.name = "1096654874"
	remote_player.set_multiplayer_authority(1096654874)
	world.add_child(remote_player)
	await _tree.process_frame

	local_player._physics_process(1.0 / 60.0)
	remote_player._physics_process(1.0 / 60.0)

	var local_label := local_player.get_node("DebugLabel") as Label3D
	var remote_label := remote_player.get_node("DebugLabel") as Label3D
	_assert(local_label != null and local_label.text.begins_with("P1 LOCAL"), "local player runtime label should use slot P1 when hosting")
	_assert(remote_label != null and remote_label.text.begins_with("P2 REMOTE"), "remote player runtime label should use slot P2 for the first client")

	world.queue_free()
	await _tree.process_frame
	network_manager.leave_game()


func _make_world(name: String) -> Node3D:
	var world := Node3D.new()
	world.name = name

	var packages := Node3D.new()
	packages.name = "Packages"
	world.add_child(packages)

	_tree.root.add_child(world)
	return world


func _action_has_key(action_name: StringName, keycode: Key) -> bool:
	for event in InputMap.action_get_events(action_name):
		if event is not InputEventKey:
			continue
		var key_event := event as InputEventKey
		if key_event.keycode == keycode or key_event.physical_keycode == keycode:
			return true
	return false


func _assert(condition: bool, message: String) -> void:
	if condition:
		return
	_failures.append(message)
