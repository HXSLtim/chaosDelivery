extends RefCounted

const PACKAGE_SCENE := preload("res://scenes/entities/package.tscn")

var _tree: SceneTree
var _failures: Array[String] = []


func run(tree: SceneTree) -> Array[String]:
	_tree = tree
	_failures.clear()

	await _test_snapshot_round_trip_preserves_held_state_and_runtime_fields()
	await _test_partial_snapshot_updates_only_present_fields()
	await _test_thrown_snapshot_without_holder_stays_thrown()

	return _failures


func _test_snapshot_round_trip_preserves_held_state_and_runtime_fields() -> void:
	var world := _make_world("SnapshotRoundTrip")
	var packages := world.get_node("Packages")
	var holder := _make_holder("Carrier")
	world.add_child(holder)

	var source_package = PACKAGE_SCENE.instantiate()
	source_package.name = "SourcePkg"
	source_package.package_id = "pkg_source"
	packages.add_child(source_package)
	await _tree.process_frame

	source_package.global_position = Vector3(3.5, 1.25, -2.0)
	source_package.basis = Basis.from_euler(Vector3(0.0, 0.7, 0.0))
	source_package.linear_velocity = Vector3(2.0, 0.0, -1.0)
	source_package.angular_velocity = Vector3(0.0, 1.5, 0.0)
	_assert(source_package.request_grab(holder, 7), "source package should be grabbable")

	var snapshot: Dictionary = source_package.get_network_snapshot()

	var replica_package = PACKAGE_SCENE.instantiate()
	replica_package.name = "ReplicaPkg"
	packages.add_child(replica_package)
	await _tree.process_frame

	replica_package.apply_network_snapshot(snapshot)

	_assert(replica_package.package_id == "pkg_source", "snapshot should preserve package id")
	_assert(replica_package.get_state() == replica_package.State.HELD, "replica should restore HELD state")
	_assert(replica_package.holder == holder, "replica should resolve holder from holder_path")
	_assert(replica_package.freeze, "replica should preserve freeze state from snapshot")
	_assert(replica_package.global_position.is_equal_approx(source_package.global_position), "replica should restore position")
	_assert(replica_package.basis.is_equal_approx(source_package.basis), "replica should restore basis")
	_assert(replica_package.linear_velocity.is_equal_approx(source_package.linear_velocity), "replica should restore linear velocity")
	_assert(replica_package.angular_velocity.is_equal_approx(source_package.angular_velocity), "replica should restore angular velocity")

	world.queue_free()
	await _tree.process_frame


func _test_partial_snapshot_updates_only_present_fields() -> void:
	var world := _make_world("PartialSnapshot")
	var packages := world.get_node("Packages")

	var package = PACKAGE_SCENE.instantiate()
	package.name = "PartialPkg"
	package.package_id = "pkg_partial"
	packages.add_child(package)
	await _tree.process_frame

	package.set_authority_peer_id_hint(9)
	package.global_position = Vector3(1.0, 1.0, 1.0)
	package.freeze = false

	package.apply_network_snapshot({
		"position": Vector3(9.0, 2.0, -4.0),
		"freeze": true
	})

	_assert(package.package_id == "pkg_partial", "partial snapshot should not overwrite package_id")
	_assert(
		package.get_owner_peer_id_hint() == 1,
		"partial snapshot should keep local fallback authority when holder gets cleared"
	)
	_assert(package.get_state() == package.State.ON_GROUND, "partial snapshot should keep current state when state key is absent")
	_assert(package.global_position == Vector3(9.0, 2.0, -4.0), "partial snapshot should update provided position")
	_assert(not package.freeze, "partial snapshot should finish in released physics state")

	world.queue_free()
	await _tree.process_frame


func _test_thrown_snapshot_without_holder_stays_thrown() -> void:
	var world := _make_world("ThrownSnapshot")
	var packages := world.get_node("Packages")

	var package = PACKAGE_SCENE.instantiate()
	packages.add_child(package)
	await _tree.process_frame

	package.apply_network_snapshot({
		"state": int(package.State.THROWN),
		"holder_path": "",
		"freeze": false
	})

	_assert(package.get_state() == package.State.THROWN, "thrown snapshot without holder should stay THROWN")
	_assert(package.holder == null, "thrown snapshot without holder should keep holder null")

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
	holder.add_child(anchor)

	return holder


func _assert(condition: bool, message: String) -> void:
	if condition:
		return
	_failures.append(message)
