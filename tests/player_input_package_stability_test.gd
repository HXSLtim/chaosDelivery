extends RefCounted

const PLAYER_SCENE := preload("res://scenes/entities/player.tscn")
const PACKAGE_SCENE := preload("res://scenes/entities/package.tscn")

class FakeNetworkGrabSession extends Node3D:
	var grab_requests: int = 0
	var throw_requests: int = 0
	var last_throw_impulse: Vector3 = Vector3.ZERO

	func _ready() -> void:
		add_to_group("warehouse_session")

	func request_player_grab(_player: Node3D) -> bool:
		grab_requests += 1
		return true

	func request_player_throw(_player: Node3D, impulse: Vector3) -> bool:
		throw_requests += 1
		last_throw_impulse = impulse
		return true

var _tree: SceneTree
var _failures: Array[String] = []
var _saved_network_state: Dictionary = {}


func run(tree: SceneTree) -> Array[String]:
	_tree = tree
	_failures.clear()
	_capture_network_state()
	_reset_input_state()
	_reset_network_baseline()

	await _test_input_manager_default_actions_keep_expected_bindings()
	await _test_player_grab_selects_nearest_package_within_range()
	await _test_player_grab_ignores_packages_out_of_range()
	await _test_same_frame_grab_and_throw_input_drops_without_throwing()
	await _test_network_grab_prediction_allows_throw_after_timeout_before_snapshot_arrives()
	await _test_player_display_peer_id_maps_large_authority_to_stable_slot()
	await _test_player_runtime_labels_use_stable_peer_slots_when_networked()
	await _test_local_player_enables_third_person_camera()
	await _test_remote_player_camera_stays_inactive()
	await _test_camera_relative_movement_uses_yaw_pivot()
	await _test_shoulder_camera_uses_right_side_offset()

	_reset_input_state()
	_restore_network_state()
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
	await _tree.process_frame

	_assert(package.holder == null, "same-frame grab/throw should drop held package")
	_assert(package.get_state() == package.State.ON_GROUND, "same-frame grab/throw should not transition package into THROWN")

	world.queue_free()
	await _tree.process_frame


func _test_network_grab_prediction_allows_throw_after_timeout_before_snapshot_arrives() -> void:
	_reset_input_state()
	await _tree.process_frame

	var network_manager := _tree.root.get_node_or_null("NetworkManager")
	_assert(network_manager != null, "NetworkManager should exist for predicted network grab test")
	if network_manager == null:
		return

	network_manager.leave_game()
	_assert(network_manager.host_game() == OK, "setup should host a local session for predicted network grab test")
	network_manager.connected_peers = {1: true}

	var world := _make_world("PredictedNetworkGrabThrow")
	var session := FakeNetworkGrabSession.new()
	session.name = "FakePredictiveSession"
	world.add_child(session)

	var player = PLAYER_SCENE.instantiate()
	player.name = "PlayerPredictive"
	player.grab_range = 3.0
	player.network_request_timeout = 0.05
	player.interaction_cooldown = 0.01
	world.add_child(player)

	var package = PACKAGE_SCENE.instantiate()
	package.name = "PkgPredicted"
	world.get_node("Packages").add_child(package)
	await _tree.process_frame

	player.global_position = Vector3.ZERO
	package.global_position = Vector3(0.8, 0.0, 0.0)
	Input.action_press(String(InputManager.ACTION_GRAB))
	player._physics_process(1.0 / 60.0)
	Input.action_release(String(InputManager.ACTION_GRAB))
	_assert(session.grab_requests == 1, "network session should receive a grab request on the first frame")
	await _tree.process_frame

	player._physics_process(player.network_request_timeout + 0.01)
	await _tree.process_frame

	Input.action_press(String(InputManager.ACTION_THROW))
	var held_before_throw = player.get("_held_package")
	var predicted_before_throw = player.get("_predicted_held_package")
	var pending_before_throw := bool(player.get("_pending_network_hold"))
	player._physics_process(1.0 / 60.0)
	Input.action_release(String(InputManager.ACTION_THROW))

	var held_after_throw = player.get("_held_package")
	var predicted_after_throw = player.get("_predicted_held_package")
	var pending_after_throw := bool(player.get("_pending_network_hold"))
	var wait_after_throw := bool(player.get("_waiting_for_network_action"))
	var cooldown_after_throw := float(player.get("_interaction_cooldown_left"))

	_assert(
		session.throw_requests == 1,
		"predicted network-held package should allow throw request after timeout before authoritative snapshot arrives (before_held=%s before_predicted=%s before_pending=%s after_held=%s after_predicted=%s after_pending=%s waiting=%s cooldown=%.3f grab_requests=%d)" % [
			str(held_before_throw != null),
			str(predicted_before_throw != null),
			str(pending_before_throw),
			str(held_after_throw != null),
			str(predicted_after_throw != null),
			str(pending_after_throw),
			str(wait_after_throw),
			cooldown_after_throw,
			session.grab_requests
		]
	)
	_assert(
		session.last_throw_impulse.length() > 0.0,
		"predicted throw should still send a non-zero throw impulse (throw_requests=%d impulse=%s)" % [
			session.throw_requests,
			session.last_throw_impulse
		]
	)

	world.queue_free()
	await _tree.process_frame
	network_manager.leave_game()


func _test_player_display_peer_id_maps_large_authority_to_stable_slot() -> void:
	var network_manager := _tree.root.get_node_or_null("NetworkManager")
	_assert(network_manager != null, "NetworkManager should exist for player display peer slot test")
	if network_manager == null:
		return

	network_manager.leave_game()
	_assert(network_manager.host_game() == OK, "setup should host a local session for player display peer slot test")
	# 大型 peer id 用来模拟 ENet 生成的远端连接标识，而不是稳定的玩家槽位编号。
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
	# 大型 peer id 用来模拟 ENet 生成的远端连接标识，而不是稳定的玩家槽位编号。
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


func _test_local_player_enables_third_person_camera() -> void:
	var world := _make_world("LocalThirdPersonCamera")
	var player = PLAYER_SCENE.instantiate()
	player.name = "PlayerLocalCamera"
	world.add_child(player)
	await _tree.process_frame

	var camera := player.get_node("CameraRig/YawPivot/PitchPivot/CameraSpringArm/PlayerCamera") as Camera3D
	_assert(camera != null and camera.current, "local player should enable the third-person player camera")

	world.queue_free()
	await _tree.process_frame


func _test_remote_player_camera_stays_inactive() -> void:
	var network_manager := _tree.root.get_node_or_null("NetworkManager")
	_assert(network_manager != null, "NetworkManager should exist for remote camera test")
	if network_manager == null:
		return

	network_manager.leave_game()
	_assert(network_manager.host_game() == OK, "setup should host a local session for remote camera test")
	network_manager.connected_peers = {1: true, 1096654874: true}

	var world := _make_world("RemoteThirdPersonCamera")
	var remote_player = PLAYER_SCENE.instantiate()
	remote_player.name = "1096654874"
	remote_player.set_multiplayer_authority(1096654874)
	world.add_child(remote_player)
	await _tree.process_frame

	var camera := remote_player.get_node("CameraRig/YawPivot/PitchPivot/CameraSpringArm/PlayerCamera") as Camera3D
	_assert(camera != null and not camera.current, "remote player camera should stay inactive so each client keeps its own view")

	world.queue_free()
	await _tree.process_frame
	network_manager.leave_game()


func _test_camera_relative_movement_uses_yaw_pivot() -> void:
	var world := _make_world("CameraRelativeMovement")
	var player = PLAYER_SCENE.instantiate()
	player.name = "PlayerCameraRelativeMovement"
	world.add_child(player)
	await _tree.process_frame

	var yaw_pivot := player.get_node("CameraRig/YawPivot") as Node3D
	_assert(yaw_pivot != null, "player scene should expose a yaw pivot for third-person movement")
	if yaw_pivot == null:
		world.queue_free()
		await _tree.process_frame
		return

	yaw_pivot.rotation.y = -PI * 0.5
	var move_direction: Vector3 = player._get_camera_relative_move_direction(Vector2(0.0, -1.0))
	_assert(
		move_direction.distance_to(Vector3(1.0, 0.0, 0.0)) < 0.001,
		"forward movement should follow the camera yaw when the third-person camera turns"
	)

	world.queue_free()
	await _tree.process_frame


func _test_shoulder_camera_uses_right_side_offset() -> void:
	var world := _make_world("ShoulderCameraOffset")
	var player = PLAYER_SCENE.instantiate()
	player.name = "PlayerShoulderCameraOffset"
	world.add_child(player)
	await _tree.process_frame

	var camera := player.get_node("CameraRig/YawPivot/PitchPivot/CameraSpringArm/PlayerCamera") as Camera3D
	_assert(camera != null, "player scene should expose a third-person camera for shoulder offset checks")
	if camera == null:
		world.queue_free()
		await _tree.process_frame
		return

	_assert(camera.position.x > 0.4, "third-person camera should be offset to the right for an over-shoulder framing")
	_assert(camera.position.y > 0.0, "third-person camera should sit slightly above the shoulder line")

	world.queue_free()
	await _tree.process_frame


func _make_world(name: String) -> Node3D:
	var world := Node3D.new()
	world.name = name

	var packages := Node3D.new()
	packages.name = "Packages"
	world.add_child(packages)

	_tree.root.add_child(world)
	return world


func _capture_network_state() -> void:
	var network_manager := _tree.root.get_node_or_null("NetworkManager")
	if network_manager == null:
		return
	_saved_network_state = {
		"is_host": network_manager.is_host,
		"is_connected": network_manager.is_connected,
		"is_connecting": network_manager.is_connecting,
		"connection_state": network_manager.connection_state,
		"last_connection_error": int(network_manager.last_connection_error),
		"connected_peers": network_manager.connected_peers.duplicate(true)
	}


func _restore_network_state() -> void:
	var network_manager := _tree.root.get_node_or_null("NetworkManager")
	if network_manager == null:
		return
	network_manager.leave_game()
	network_manager.set("is_host", bool(_saved_network_state.get("is_host", false)))
	network_manager.set("is_connected", bool(_saved_network_state.get("is_connected", false)))
	network_manager.set("is_connecting", bool(_saved_network_state.get("is_connecting", false)))
	network_manager.set("connection_state", int(_saved_network_state.get("connection_state", 0)))
	network_manager.set("last_connection_error", int(_saved_network_state.get("last_connection_error", int(OK))))
	network_manager.set("connected_peers", _saved_network_state.get("connected_peers", {}).duplicate(true))


func _reset_network_baseline() -> void:
	var network_manager := _tree.root.get_node_or_null("NetworkManager")
	if network_manager == null:
		return
	network_manager.leave_game()
	network_manager.set("is_host", false)
	network_manager.set("is_connected", false)
	network_manager.set("is_connecting", false)
	network_manager.set("connection_state", 0)
	network_manager.set("last_connection_error", int(OK))
	network_manager.set("connected_peers", {})


func _reset_input_state() -> void:
	for action_name in InputManager.get_core_actions():
		Input.action_release(String(action_name))


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
