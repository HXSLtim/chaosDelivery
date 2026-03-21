extends Node

const PACKAGE_BEHAVIOR_TEST := preload("res://tests/package_behavior_test.gd")
const PACKAGE_SNAPSHOT_TEST := preload("res://tests/package_snapshot_test.gd")
const ORDER_DELIVERY_BEHAVIOR_TEST := preload("res://tests/order_delivery_behavior_test.gd")
const HUD_SESSION_BEHAVIOR_TEST := preload("res://tests/hud_session_behavior_test.gd")


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var failures: Array[String] = []
	var tree := get_tree()

	var package_behavior_test = PACKAGE_BEHAVIOR_TEST.new()
	failures.append_array(await package_behavior_test.run(tree))
	var package_snapshot_test = PACKAGE_SNAPSHOT_TEST.new()
	failures.append_array(await package_snapshot_test.run(tree))
	var order_delivery_behavior_test = ORDER_DELIVERY_BEHAVIOR_TEST.new()
	failures.append_array(await order_delivery_behavior_test.run(tree))
	var hud_session_behavior_test = HUD_SESSION_BEHAVIOR_TEST.new()
	failures.append_array(await hud_session_behavior_test.run(tree))

	if failures.is_empty():
		print("ALL TESTS PASSED")
		tree.quit(0)
		return

	for failure in failures:
		push_error("TEST FAILURE: %s" % failure)

	tree.quit(1)
