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
	await _test_order_manager_change_signals_and_pending_helper_are_deterministic()
	await _test_validate_delivery_rejects_mismatch_and_accepts_match()
	await _test_delivery_zone_deduplicates_delivery_until_phase_reset()
	await _test_delivery_zone_uses_node_name_when_package_id_missing()
	await _test_delivery_zone_rejects_when_order_manager_is_missing()
	await _test_delivery_zone_rechecks_thrown_package_after_landing_inside_zone()
	await _test_delivery_zone_reset_disconnects_pending_landing_package_callbacks()

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


func _test_order_manager_change_signals_and_pending_helper_are_deterministic() -> void:
	var world := _make_world("OrderChangeSignals")
	var manager = ORDER_MANAGER_SCRIPT.new()
	world.add_child(manager)
	await _tree.process_frame

	_assert(manager.has_method("get_pending_order_count"), "order manager should expose get_pending_order_count helper")
	_assert(manager.has_signal("order_created"), "order manager should expose order_created signal")
	_assert(manager.has_signal("order_marked_completed"), "order manager should expose order_marked_completed signal")
	_assert(manager.has_signal("orders_changed"), "order manager should expose orders_changed signal")
	_assert(manager.has_signal("pending_count_changed"), "order manager should expose pending_count_changed signal")
	_assert(manager.has_signal("orders_cleared"), "order manager should expose orders_cleared signal")

	var created_ids: Array[String] = []
	var completed_ids: Array[String] = []
	var change_events: Array[Dictionary] = []
	var pending_counts: Array[int] = []
	var cleared_events: Array[bool] = []

	var on_created := func(order_id: String, _order: Dictionary) -> void:
		created_ids.append(order_id)
	var on_completed := func(order_id: String, _order: Dictionary) -> void:
		completed_ids.append(order_id)
	var on_changed := func(reason: String, order_id: String, pending_count: int, total_count: int) -> void:
		change_events.append({
			"reason": reason,
			"order_id": order_id,
			"pending": pending_count,
			"total": total_count
		})
	var on_pending_count_changed := func(pending_count: int) -> void:
		pending_counts.append(pending_count)
	var on_cleared := func() -> void:
		cleared_events.append(true)

	if manager.has_signal("order_created"):
		manager.order_created.connect(on_created)
	if manager.has_signal("order_marked_completed"):
		manager.order_marked_completed.connect(on_completed)
	if manager.has_signal("orders_changed"):
		manager.orders_changed.connect(on_changed)
	if manager.has_signal("pending_count_changed"):
		manager.pending_count_changed.connect(on_pending_count_changed)
	if manager.has_signal("orders_cleared"):
		manager.orders_cleared.connect(on_cleared)

	manager.clear_orders()
	_assert(manager.get_pending_order_count() == 0, "pending helper should start at zero after clear")

	var first := manager.create_order("normal", "A")
	_assert(manager.get_pending_order_count() == 1, "pending helper should increment after first create")

	var second := manager.create_order("fragile", "B")
	_assert(manager.get_pending_order_count() == 2, "pending helper should increment after second create")

	var completed := manager.complete_order(first)
	_assert(completed, "complete_order should succeed for first created order")
	_assert(manager.get_pending_order_count() == 1, "pending helper should decrement after completion")

	manager.clear_orders()
	_assert(manager.get_pending_order_count() == 0, "pending helper should reset after clear_orders")

	_assert(created_ids == [first, second], "order_created should emit deterministic ids in creation order")
	_assert(completed_ids == [first], "order_marked_completed should emit exactly once for completed order")
	_assert(
		change_events == [
			{"reason": "created", "order_id": first, "pending": 1, "total": 1},
			{"reason": "created", "order_id": second, "pending": 2, "total": 2},
			{"reason": "completed", "order_id": first, "pending": 1, "total": 2},
			{"reason": "cleared", "order_id": "", "pending": 0, "total": 0}
		],
		"orders_changed should emit deterministic reason/id/pending/total snapshots"
	)
	_assert(pending_counts == [1, 2, 1, 0], "pending_count_changed should emit deterministic pending sequence")
	_assert(cleared_events.size() == 1, "orders_cleared should emit once when clearing non-empty order list")

	if manager.has_signal("order_created") and manager.order_created.is_connected(on_created):
		manager.order_created.disconnect(on_created)
	if manager.has_signal("order_marked_completed") and manager.order_marked_completed.is_connected(on_completed):
		manager.order_marked_completed.disconnect(on_completed)
	if manager.has_signal("orders_changed") and manager.orders_changed.is_connected(on_changed):
		manager.orders_changed.disconnect(on_changed)
	if manager.has_signal("pending_count_changed") and manager.pending_count_changed.is_connected(on_pending_count_changed):
		manager.pending_count_changed.disconnect(on_pending_count_changed)
	if manager.has_signal("orders_cleared") and manager.orders_cleared.is_connected(on_cleared):
		manager.orders_cleared.disconnect(on_cleared)

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


func _test_delivery_zone_uses_node_name_when_package_id_missing() -> void:
	var world := _make_world("DeliveryZonePackageIdFallback")
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
	var on_delivered := func(package_id: String, _order_id: String) -> void:
		delivered_ids.append(package_id)
	zone.package_delivered.connect(on_delivered)

	var package = PACKAGE_SCENE.instantiate()
	package.name = "PkgNameFallback"
	package.package_id = ""
	package.package_type = "normal"
	world.add_child(package)
	await _tree.process_frame

	zone._on_body_entered(package)
	zone._on_body_entered(package)
	_assert(
		delivered_ids == ["PkgNameFallback"],
		"delivery zone should fallback to node name for empty package_id and dedupe duplicate entries"
	)

	var event_bus := _get_event_bus()
	if event_bus != null:
		event_bus.phase_changed.emit(int(EVENT_BUS_SCRIPT.GamePhase.LOBBY), int(EVENT_BUS_SCRIPT.GamePhase.WORKING))
	manager.clear_orders()
	manager.create_order("normal", "A")
	zone._on_body_entered(package)

	_assert(
		delivered_ids == ["PkgNameFallback", "PkgNameFallback"],
		"delivery zone should reset name-based delivery cache on lobby phase changes"
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


func _test_delivery_zone_rechecks_thrown_package_after_landing_inside_zone() -> void:
	var world := _make_world("DeliveryZoneThrownLandingRetry")
	var gameplay := Node.new()
	gameplay.name = "Gameplay"
	world.add_child(gameplay)

	var manager = ORDER_MANAGER_SCRIPT.new()
	gameplay.add_child(manager)

	var zone = DELIVERY_ZONE_SCENE.instantiate()
	zone.auto_seed_static_order = false
	zone.destination_id = "A"
	gameplay.add_child(zone)

	var holder := Node3D.new()
	holder.name = "ThrowingHolder"
	world.add_child(holder)

	var package = PACKAGE_SCENE.instantiate()
	package.name = "PkgThrownLanding"
	package.package_id = "pkg_thrown_retry"
	package.package_type = "normal"
	world.add_child(package)
	await _tree.process_frame

	manager.clear_orders()
	manager.create_order("normal", "A")

	var delivered_ids: Array[String] = []
	var rejected_reasons: Array[String] = []
	zone.package_delivered.connect(func(package_id: String, _order_id: String) -> void:
		delivered_ids.append(package_id)
	)
	zone.delivery_rejected.connect(func(_package_id: String, reason: String) -> void:
		rejected_reasons.append(reason)
	)

	_assert(package.request_grab(holder, 1), "setup should allow holder to grab package before throw")
	_assert(package.request_drop(Vector3(3.0, 0.0, 0.0)), "setup should allow package throw before zone entry")
	_assert(package.is_thrown(), "setup should put package into THROWN state")

	zone._on_body_entered(package)
	_assert(
		rejected_reasons == ["package_state_thrown"],
		"delivery zone should reject the initial thrown entry before the package lands"
	)
	_assert(delivered_ids.is_empty(), "delivery zone should not deliver while package is still thrown")

	package._change_state(package.State.ON_GROUND)

	_assert(
		delivered_ids == ["pkg_thrown_retry"],
		"delivery zone should re-check a thrown package when it lands inside the zone without requiring re-entry"
	)

	world.queue_free()
	await _tree.process_frame


func _test_delivery_zone_reset_disconnects_pending_landing_package_callbacks() -> void:
	var world := _make_world("DeliveryZoneTrackedLandingReset")
	var gameplay := Node.new()
	gameplay.name = "Gameplay"
	world.add_child(gameplay)

	var manager = ORDER_MANAGER_SCRIPT.new()
	gameplay.add_child(manager)

	var zone = DELIVERY_ZONE_SCENE.instantiate()
	zone.auto_seed_static_order = false
	zone.destination_id = "A"
	gameplay.add_child(zone)

	var holder := Node3D.new()
	holder.name = "TrackedLandingHolder"
	world.add_child(holder)

	var package = PACKAGE_SCENE.instantiate()
	package.name = "PkgTrackedLanding"
	package.package_id = "pkg_tracked_landing"
	package.package_type = "normal"
	world.add_child(package)
	await _tree.process_frame

	manager.clear_orders()
	manager.create_order("normal", "A")

	_assert(package.request_grab(holder, 1), "setup should allow tracked package grab")
	_assert(package.request_drop(Vector3(4.0, 0.0, 0.0)), "setup should allow tracked package throw")
	zone._on_body_entered(package)

	_assert(
		not zone._pending_landing_packages.is_empty(),
		"delivery zone should track thrown packages that land inside the zone"
	)
	var tracked_entry: Dictionary = zone._pending_landing_packages.get(package.get_instance_id(), {})
	var tracked_callable: Callable = tracked_entry.get("callable", Callable())
	_assert(
		package.is_connected("package_state_changed", tracked_callable),
		"delivery zone should connect a landing callback for tracked packages"
	)

	zone.reset_delivery_tracking()

	_assert(zone._pending_landing_packages.is_empty(), "delivery zone reset should clear pending landing tracking")
	_assert(
		not package.is_connected("package_state_changed", tracked_callable),
		"delivery zone reset should disconnect tracked package state callbacks"
	)

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
