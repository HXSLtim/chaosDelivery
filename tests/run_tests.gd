extends Node

const RUNTIME_LOG := preload("res://src/utils/runtime_log.gd")
const PACKAGE_BEHAVIOR_TEST := preload("res://tests/package_behavior_test.gd")
const PACKAGE_SNAPSHOT_TEST := preload("res://tests/package_snapshot_test.gd")
const ORDER_DELIVERY_BEHAVIOR_TEST := preload("res://tests/order_delivery_behavior_test.gd")
const HUD_SESSION_BEHAVIOR_TEST := preload("res://tests/hud_session_behavior_test.gd")
const GAME_STATE_SIGNAL_BEHAVIOR_TEST := preload("res://tests/game_state_signal_behavior_test.gd")
const PLAYER_INPUT_PACKAGE_STABILITY_TEST := preload("res://tests/player_input_package_stability_test.gd")
const NETWORK_MANAGER_HELPER_TEST := preload("res://tests/network_manager_helper_test.gd")
const RUNTIME_LOG_BEHAVIOR_TEST := preload("res://tests/runtime_log_behavior_test.gd")


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var failures: Array[String] = []
	var tree := get_tree()
	RUNTIME_LOG.set_force_enabled(false)

	var package_behavior_test = PACKAGE_BEHAVIOR_TEST.new()
	failures.append_array(await package_behavior_test.run(tree))
	var package_snapshot_test = PACKAGE_SNAPSHOT_TEST.new()
	failures.append_array(await package_snapshot_test.run(tree))
	var order_delivery_behavior_test = ORDER_DELIVERY_BEHAVIOR_TEST.new()
	failures.append_array(await order_delivery_behavior_test.run(tree))
	var hud_session_behavior_test = HUD_SESSION_BEHAVIOR_TEST.new()
	failures.append_array(await hud_session_behavior_test.run(tree))
	var game_state_signal_behavior_test = GAME_STATE_SIGNAL_BEHAVIOR_TEST.new()
	failures.append_array(await game_state_signal_behavior_test.run(tree))
	var player_input_package_stability_test = PLAYER_INPUT_PACKAGE_STABILITY_TEST.new()
	failures.append_array(await player_input_package_stability_test.run(tree))
	var network_manager_helper_test = NETWORK_MANAGER_HELPER_TEST.new()
	failures.append_array(await network_manager_helper_test.run(tree))
	var runtime_log_behavior_test = RUNTIME_LOG_BEHAVIOR_TEST.new()
	failures.append_array(await runtime_log_behavior_test.run(tree))

	if failures.is_empty():
		RUNTIME_LOG.clear_force_enabled()
		print("ALL TESTS PASSED")
		tree.quit(0)
		return

	RUNTIME_LOG.clear_force_enabled()
	for failure in failures:
		push_error("TEST FAILURE: %s" % failure)

	tree.quit(1)
