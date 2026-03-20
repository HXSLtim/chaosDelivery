extends Node

const ACTION_MOVE_LEFT := &"move_left"
const ACTION_MOVE_RIGHT := &"move_right"
const ACTION_MOVE_FORWARD := &"move_forward"
const ACTION_MOVE_BACKWARD := &"move_backward"
const ACTION_GRAB := &"grab"
const ACTION_THROW := &"throw"
const ACTION_INTERACT := &"interact"

func _ready() -> void:
	_ensure_default_actions()

func get_move_vector() -> Vector2:
	return Input.get_vector(
		ACTION_MOVE_LEFT,
		ACTION_MOVE_RIGHT,
		ACTION_MOVE_FORWARD,
		ACTION_MOVE_BACKWARD
	)

func is_grab_pressed() -> bool:
	return Input.is_action_just_pressed(ACTION_GRAB)

func is_throw_pressed() -> bool:
	return Input.is_action_just_pressed(ACTION_THROW)

func is_interact_pressed() -> bool:
	return Input.is_action_just_pressed(ACTION_INTERACT)

func _ensure_default_actions() -> void:
	var actions: Array[StringName] = [
		ACTION_MOVE_LEFT,
		ACTION_MOVE_RIGHT,
		ACTION_MOVE_FORWARD,
		ACTION_MOVE_BACKWARD,
		ACTION_GRAB,
		ACTION_THROW,
		ACTION_INTERACT
	]
	for action_name in actions:
		if not InputMap.has_action(action_name):
			InputMap.add_action(action_name)

	_ensure_key_binding(ACTION_MOVE_LEFT, KEY_A)
	_ensure_key_binding(ACTION_MOVE_RIGHT, KEY_D)
	_ensure_key_binding(ACTION_MOVE_FORWARD, KEY_W)
	_ensure_key_binding(ACTION_MOVE_BACKWARD, KEY_S)
	_ensure_key_binding(ACTION_GRAB, KEY_E)
	_ensure_key_binding(ACTION_THROW, KEY_F)
	_ensure_key_binding(ACTION_INTERACT, KEY_SPACE)

func _ensure_key_binding(action_name: StringName, keycode: Key) -> void:
	for event in InputMap.action_get_events(action_name):
		if event is InputEventKey and event.keycode == keycode:
			return

	var key_event := InputEventKey.new()
	key_event.keycode = keycode
	key_event.physical_keycode = keycode
	InputMap.action_add_event(action_name, key_event)
