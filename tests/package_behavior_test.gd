extends RefCounted

const PACKAGE_SCENE := preload("res://scenes/entities/package.tscn")
const GRABBABLE_COMPONENT_SCRIPT := preload("res://src/components/grabbable_component.gd")

var _tree: SceneTree
var _failures: Array[String] = []


func run(tree: SceneTree) -> Array[String]:
	_tree = tree
	_failures.clear()

	await _test_grab_does_not_reparent_package()
	await _test_drop_returns_package_to_released_state()
	await _test_repeated_grab_drop_requests_are_idempotent()
	await _test_stale_holder_is_not_reported_as_held()
	await _test_stale_holder_recovers_cleanly()
	await _test_invalid_held_snapshot_falls_back_to_ground_state()
	await _test_grabbable_component_throttles_stale_holder_recovery_in_physics()
	await _test_thrown_package_returns_to_ground_when_motion_stabilizes()

	return _failures


func _test_grab_does_not_reparent_package() -> void:
	var world := _make_world("GrabKeepsParent")
	var packages := world.get_node("Packages")
	var holder := _make_holder("HolderA")
	world.add_child(holder)

	var package = PACKAGE_SCENE.instantiate()
	packages.add_child(package)
	await _tree.process_frame

	var original_parent := package.get_parent()
	var grabbed := bool(package.request_grab(holder, 1))

	_assert(grabbed, "grab should succeed")
	_assert(package.get_parent() == original_parent, "grab should keep original parent")
	_assert(package.freeze, "grabbed package should be frozen")
	_assert(package.holder == holder, "package holder should be set to holder")

	world.queue_free()
	await _tree.process_frame


func _test_drop_returns_package_to_released_state() -> void:
	var world := _make_world("DropRestoresState")
	var packages := world.get_node("Packages")
	var holder := _make_holder("HolderB")
	world.add_child(holder)

	var package = PACKAGE_SCENE.instantiate()
	packages.add_child(package)
	await _tree.process_frame

	package.request_grab(holder, 1)
	var dropped := bool(package.request_drop())

	_assert(dropped, "drop should succeed after grab")
	_assert(not package.freeze, "dropped package should not stay frozen")
	_assert(package.holder == null, "dropped package holder should be cleared")
	_assert(package.get_parent() == packages, "dropped package should still live under Packages")

	world.queue_free()
	await _tree.process_frame


func _test_repeated_grab_drop_requests_are_idempotent() -> void:
	var world := _make_world("IdempotentGrabDrop")
	var packages := world.get_node("Packages")
	var holder := _make_holder("HolderC")
	world.add_child(holder)

	var package = PACKAGE_SCENE.instantiate()
	packages.add_child(package)
	await _tree.process_frame

	_assert(package.request_grab(holder, 1), "first grab should succeed")
	_assert(package.request_grab(holder, 1), "second grab by same holder should also succeed")
	_assert(package.request_drop(), "first drop should succeed")
	_assert(package.request_drop(), "second drop should be idempotently successful")

	world.queue_free()
	await _tree.process_frame


func _test_stale_holder_is_not_reported_as_held() -> void:
	var world := _make_world("StaleHolderReportedState")
	var packages := world.get_node("Packages")
	var holder := _make_holder("HolderE")
	world.add_child(holder)

	var package = PACKAGE_SCENE.instantiate()
	packages.add_child(package)
	await _tree.process_frame

	package.request_grab(holder, 1)
	holder.free()

	_assert(not package.is_held(), "stale holder should not be reported as held")
	_assert(not package.has_holder(), "stale holder should not be reported by has_holder")

	world.queue_free()
	await _tree.process_frame


func _test_stale_holder_recovers_cleanly() -> void:
	var world := _make_world("StaleHolderRecovery")
	var packages := world.get_node("Packages")
	var holder := _make_holder("HolderD")
	world.add_child(holder)

	var package = PACKAGE_SCENE.instantiate()
	packages.add_child(package)
	await _tree.process_frame

	package.request_grab(holder, 1)
	holder.free()
	package._process(0.0)
	package._physics_process(0.0)

	_assert(package.holder == null, "stale holder should be cleared")
	_assert(not package.freeze, "package should unfreeze after stale-holder recovery")

	var replacement_holder := _make_holder("Replacement")
	world.add_child(replacement_holder)
	await _tree.process_frame
	_assert(package.can_accept_grab_request(replacement_holder, 2), "package should be grabbable again after recovery")

	world.queue_free()
	await _tree.process_frame


func _test_invalid_held_snapshot_falls_back_to_ground_state() -> void:
	var world := _make_world("InvalidHeldSnapshot")
	var packages := world.get_node("Packages")

	var package = PACKAGE_SCENE.instantiate()
	packages.add_child(package)
	await _tree.process_frame

	package.apply_network_snapshot({
		"state": 1,
		"authority_peer_id_hint": 2,
		"holder_path": "",
		"position": Vector3(1, 2, 3),
		"basis": Basis.IDENTITY,
		"linear_velocity": Vector3.ZERO,
		"angular_velocity": Vector3.ZERO,
		"freeze": true
	})

	_assert(package.get_state() == package.State.ON_GROUND, "invalid held snapshot should fall back to ON_GROUND")
	_assert(package.holder == null, "invalid held snapshot should clear holder")
	_assert(not package.freeze, "invalid held snapshot should release physics freeze")

	world.queue_free()
	await _tree.process_frame


func _test_grabbable_component_throttles_stale_holder_recovery_in_physics() -> void:
	var world := _make_world("GrabbableThrottle")
	var packages := world.get_node("Packages")
	var holder := _make_holder("ThrottleHolder")
	world.add_child(holder)

	var package_body := RigidBody3D.new()
	package_body.name = "RawPackageBody"
	packages.add_child(package_body)

	var component = GRABBABLE_COMPONENT_SCRIPT.new()
	package_body.add_child(component)
	await _tree.process_frame

	_assert(component.force_set_holder(holder, 1), "setup should allow component to attach to holder")
	world.remove_child(holder)

	component._physics_process(0.02)
	_assert(component.holder != null, "physics recovery should not clear stale holder before validation interval elapses")

	component._physics_process(0.10)
	_assert(component.holder == null, "physics recovery should clear stale holder after validation interval elapses")

	holder.free()
	world.queue_free()
	await _tree.process_frame


func _test_thrown_package_returns_to_ground_when_motion_stabilizes() -> void:
	var world := _make_world("ThrownLandingStateRecovery")
	var packages := world.get_node("Packages")
	var holder := _make_holder("ThrowLandingHolder")
	world.add_child(holder)

	var package = PACKAGE_SCENE.instantiate()
	packages.add_child(package)
	await _tree.process_frame

	_assert(package.request_grab(holder, 1), "setup should allow grab before throw")
	_assert(package.request_drop(Vector3(3.0, 0.0, 0.0)), "setup should allow throw impulse")
	_assert(package.get_state() == package.State.THROWN, "thrown package should enter THROWN state immediately after drop impulse")

	package.linear_velocity = Vector3.ZERO
	package.angular_velocity = Vector3.ZERO
	package._physics_process(1.0 / 60.0)

	_assert(package.get_state() == package.State.ON_GROUND, "thrown package should return to ON_GROUND after motion stabilizes")

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


func _make_holder(name: String) -> Node3D:
	var holder := Node3D.new()
	holder.name = name

	var anchor := Marker3D.new()
	anchor.name = "HoldAnchor"
	anchor.position = Vector3(0, 1, -0.75)
	holder.add_child(anchor)

	return holder


func _assert(condition: bool, message: String) -> void:
	if condition:
		return
	_failures.append(message)
