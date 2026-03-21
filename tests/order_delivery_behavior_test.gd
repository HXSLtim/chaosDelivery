extends RefCounted

const ORDER_MANAGER_SCRIPT := preload("res://src/systems/order_manager.gd")
const DELIVERY_ZONE_SCENE := preload("res://scenes/entities/delivery_zone.tscn")
const PACKAGE_SCENE := preload("res://scenes/entities/package.tscn")
const EVENT_BUS_SCRIPT := preload("res://src/autoload/event_bus.gd")

var _tree: SceneTree
var _failures: Array[String] = []


func run(tree: SceneTree) -> Array[String]:
	_tree = tree
	_failures.clear()

	await _test_order_ids_and_event_emits_are_deterministic()
	await _test_validate_delivery_rejects_mismatch_and_accepts_match()
	await _test_delivery_zone_deduplicates_delivery_until_phase_reset()
	await _test_delivery_zone_rejects_when_order_manager_is_missing()

	return _failures


func _test_order_ids_and_event_emits_are_deterministic() -> void:
	var world := _make_world("OrderEventDeterminism")
	var manager = ORDER_MANAGER_SCRIPT.new()
	world.add_child(manager)
	await _tree.process_frame

	var added_ids: Array[String] = []
	var completed_ids: Array[String] = []
	var on_added := func(order_id: String) -> void:
		added_ids.append(order_id)
	var on_completed := func(order_id: String) -> void:
		completed_ids.append(order_id)
	var event_bus := _get_event_bus()

	if event_bus != null:
		event_bus.order_added.connect(on_added)
		event_bus.order_completed.connect(on_completed)

	manager.clear_orders()
	var first := manager.create_order("normal", "A")
	var second := manager.create_order("fragile", "B")
	var complete_first := manager.complete_order(first)
	var complete_first_again := manager.complete_order(first)

	_assert(first == "order_1", "first dynamic order id should start from order_1")
	_assert(second == "order_2", "second dynamic order id should increment deterministically")
	_assert(added_ids == ["order_1", "order_2"], "order_added should emit once per created order in sequence")
	_assert(complete_first, "first completion should succeed")
	_assert(not complete_first_again, "second completion for same order should fail")
	_assert(completed_ids == ["order_1"], "order_completed should emit only once for same order")

	if event_bus != null and event_bus.order_added.is_connected(on_added):
		event_bus.order_added.disconnect(on_added)
	if event_bus != null and event_bus.order_completed.is_connected(on_completed):
		event_bus.order_completed.disconnect(on_completed)

	world.queue_free()
	await _tree.process_frame


func _test_validate_delivery_rejects_mismatch_and_accepts_match() -> void:
	var world := _make_world("ValidateDelivery")
	var manager = ORDER_MANAGER_SCRIPT.new()
	world.add_child(manager)
	await _tree.process_frame

	manager.clear_orders()
	manager.create_order("normal", "A")

	var package = PACKAGE_SCENE.instantiate()
	package.name = "PkgNode"
	package.package_id = "pkg_test"
	package.package_type = "normal"
	world.add_child(package)
	await _tree.process_frame

	var destination_mismatch := manager.validate_delivery(package, "B")
	_assert(not bool(destination_mismatch.get("ok", true)), "delivery should fail for destination mismatch")
	_assert(String(destination_mismatch.get("reason", "")) == "destination_mismatch", "reason should be destination_mismatch")

	package.set("package_type", "fragile")
	var type_mismatch := manager.validate_delivery(package, "A")
	_assert(not bool(type_mismatch.get("ok", true)), "delivery should fail for package type mismatch")
	_assert(String(type_mismatch.get("reason", "")) == "package_type_mismatch", "reason should be package_type_mismatch")

	package.set("package_type", "normal")
	var accepted := manager.validate_delivery(package, "A")
	_assert(bool(accepted.get("ok", false)), "delivery should succeed after destination and type match")
	_assert(String(accepted.get("reason", "")) == "accepted", "accepted delivery reason should be accepted")
	_assert(manager.get_first_pending_order().is_empty(), "accepted delivery should complete the only pending order")

	var no_pending := manager.validate_delivery(package, "A")
	_assert(not bool(no_pending.get("ok", true)), "delivery should fail when there are no pending orders")
	_assert(String(no_pending.get("reason", "")) == "no_pending_order", "reason should be no_pending_order when order queue is empty")

	world.queue_free()
	await _tree.process_frame


func _test_delivery_zone_deduplicates_delivery_until_phase_reset() -> void:
	var world := _make_world("DeliveryZoneDedup")
	var gameplay := Node.new()
	gameplay.name = "Gameplay"
	world.add_child(gameplay)

	var manager = ORDER_MANAGER_SCRIPT.new()
	gameplay.add_child(manager)

	var zone = DELIVERY_ZONE_SCENE.instantiate()
	zone.auto_seed_static_order = false
	zone.destination_id = "A"
	gameplay.add_child(zone)

	await _tree.process_frame

	manager.clear_orders()
	manager.create_order("normal", "A")

	var delivered_ids: Array[String] = []
	var rejected_reasons: Array[String] = []
	var on_delivered := func(package_id: String, _order_id: String) -> void:
		delivered_ids.append(package_id)
	var on_rejected := func(_package_id: String, reason: String) -> void:
		rejected_reasons.append(reason)
	zone.package_delivered.connect(on_delivered)
	zone.delivery_rejected.connect(on_rejected)

	var package = PACKAGE_SCENE.instantiate()
	package.name = "PkgZone"
	package.package_id = "pkg_zone_1"
	package.package_type = "normal"
	world.add_child(package)
	await _tree.process_frame
	_assert(package.is_in_group("packages"), "package should be in packages group for delivery zone detection")
	_assert(zone._order_manager != null, "delivery zone should resolve order manager before body events")

	var sanity := manager.validate_delivery(package, "A")
	_assert(bool(sanity.get("ok", false)), "sanity check: order manager should accept package before delivery zone handles it")
	manager.clear_orders()
	manager.create_order("normal", "A")

	zone._on_body_entered(package)
	zone._on_body_entered(package)

	_assert(
		delivered_ids.size() == 1,
		"delivery zone should emit only once for duplicate package entry in same phase (got %d deliveries, reasons=%s)" % [delivered_ids.size(), rejected_reasons]
	)
	_assert(
		rejected_reasons.is_empty(),
		"duplicate package entry should be ignored rather than rejected in same phase (got %d rejections, reasons=%s)" % [rejected_reasons.size(), rejected_reasons]
	)

	var event_bus := _get_event_bus()
	if event_bus != null:
		event_bus.phase_changed.emit(int(EVENT_BUS_SCRIPT.GamePhase.PREPARATION), int(EVENT_BUS_SCRIPT.GamePhase.WORKING))
	manager.clear_orders()
	manager.create_order("normal", "A")
	zone._on_body_entered(package)

	_assert(
		delivered_ids.size() == 2,
		"delivery cache should reset on preparation phase and allow delivery again (got %d deliveries, reasons=%s)" % [delivered_ids.size(), rejected_reasons]
	)

	world.queue_free()
	await _tree.process_frame


func _test_delivery_zone_rejects_when_order_manager_is_missing() -> void:
	var world := _make_world("DeliveryZoneMissingManager")
	var zone = DELIVERY_ZONE_SCENE.instantiate()
	zone.auto_seed_static_order = false
	world.add_child(zone)
	await _tree.process_frame

	var reasons: Array[String] = []
	var on_rejected := func(_package_id: String, reason: String) -> void:
		reasons.append(reason)
	zone.delivery_rejected.connect(on_rejected)

	var package = PACKAGE_SCENE.instantiate()
	package.name = "PkgNoManager"
	package.package_id = "pkg_missing"
	package.package_type = "normal"
	world.add_child(package)
	await _tree.process_frame

	zone._on_body_entered(package)
	_assert(reasons == ["missing_order_manager"], "delivery zone should reject package when order manager is missing")

	world.queue_free()
	await _tree.process_frame


func _make_world(name: String) -> Node3D:
	var world := Node3D.new()
	world.name = name
	_tree.root.add_child(world)
	return world


func _get_event_bus() -> Node:
	return _tree.root.get_node_or_null("EventBus")


func _assert(condition: bool, message: String) -> void:
	if condition:
		return
	_failures.append(message)
