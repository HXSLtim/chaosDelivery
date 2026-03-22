extends RefCounted

const RUNTIME_LOG := preload("res://src/utils/runtime_log.gd")

var _failures: Array[String] = []


func run(_tree: SceneTree) -> Array[String]:
	_failures.clear()

	_test_format_sorts_fields_and_prefixes_scope()
	_test_force_enabled_overrides_default_state()

	return _failures


func _test_format_sorts_fields_and_prefixes_scope() -> void:
	var formatted := String(RUNTIME_LOG.format_message(
		"Session",
		"spawned player",
		{
			"peer_id": 2,
			"position": Vector3(1, 2, 3),
			"node": "Player2"
		}
	))
	_assert(
		formatted == "[ChaosDelivery][Session] spawned player node=Player2 peer_id=2 position=(1.0, 2.0, 3.0)",
		"runtime log should produce deterministic prefix and sorted field output"
	)


func _test_force_enabled_overrides_default_state() -> void:
	RUNTIME_LOG.set_force_enabled(false)
	_assert(not RUNTIME_LOG.is_enabled(), "runtime log should be disable-able for deterministic tests")

	RUNTIME_LOG.set_force_enabled(true)
	_assert(RUNTIME_LOG.is_enabled(), "runtime log should allow forced enable for local debugging")

	RUNTIME_LOG.clear_force_enabled()


func _assert(condition: bool, message: String) -> void:
	if condition:
		return
	_failures.append(message)
