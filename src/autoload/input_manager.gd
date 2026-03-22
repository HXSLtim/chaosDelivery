extends Node

const ACTION_MOVE_LEFT := &"move_left"
const ACTION_MOVE_RIGHT := &"move_right"
const ACTION_MOVE_FORWARD := &"move_forward"
const ACTION_MOVE_BACKWARD := &"move_backward"
const ACTION_GRAB := &"grab"
const ACTION_THROW := &"throw"
const ACTION_INTERACT := &"interact"

const MOVE_ACTIONS: Array[StringName] = [
	ACTION_MOVE_LEFT,
	ACTION_MOVE_RIGHT,
	ACTION_MOVE_FORWARD,
	ACTION_MOVE_BACKWARD
]

const CORE_ACTIONS: Array[StringName] = [
	ACTION_MOVE_LEFT,
	ACTION_MOVE_RIGHT,
	ACTION_MOVE_FORWARD,
	ACTION_MOVE_BACKWARD,
	ACTION_GRAB,
	ACTION_THROW,
	ACTION_INTERACT
]

const DEFAULT_BINDINGS: Array[Dictionary] = [
	{"action": ACTION_MOVE_LEFT, "keys": [KEY_A, KEY_LEFT]},
	{"action": ACTION_MOVE_RIGHT, "keys": [KEY_D, KEY_RIGHT]},
	{"action": ACTION_MOVE_FORWARD, "keys": [KEY_W, KEY_UP]},
	{"action": ACTION_MOVE_BACKWARD, "keys": [KEY_S, KEY_DOWN]},
	{"action": ACTION_GRAB, "keys": [KEY_E]},
	{"action": ACTION_THROW, "keys": [KEY_F]},
	{"action": ACTION_INTERACT, "keys": [KEY_SPACE, KEY_ENTER, KEY_KP_ENTER]}
]

func _ready() -> void:
	_ensure_default_actions()

func get_move_vector() -> Vector2:
	_ensure_default_actions()
	return get_move_vector_for_actions(
		MOVE_ACTIONS[0],
		MOVE_ACTIONS[1],
		MOVE_ACTIONS[2],
		MOVE_ACTIONS[3]
	)

func get_move_vector_for_actions(
	left_action: StringName,
	right_action: StringName,
	forward_action: StringName,
	backward_action: StringName
) -> Vector2:
	_ensure_default_actions()
	return Input.get_vector(left_action, right_action, forward_action, backward_action)

func get_core_actions() -> Array[StringName]:
	_ensure_default_actions()
	return CORE_ACTIONS.duplicate()

func is_action_just_pressed(action_name: StringName) -> bool:
	_ensure_default_actions()
	return Input.is_action_just_pressed(action_name)

func is_grab_pressed() -> bool:
	return is_action_just_pressed(ACTION_GRAB)

func is_throw_pressed() -> bool:
	return is_action_just_pressed(ACTION_THROW)

func is_interact_pressed() -> bool:
	return is_action_just_pressed(ACTION_INTERACT)

func _ensure_default_actions() -> void:
	_ensure_actions_exist(CORE_ACTIONS)
	_ensure_default_bindings(DEFAULT_BINDINGS)

func _ensure_actions_exist(actions: Array[StringName]) -> void:
	for action_name in actions:
		if not InputMap.has_action(action_name):
			InputMap.add_action(action_name)

func _ensure_default_bindings(binding_specs: Array[Dictionary]) -> void:
	for binding_spec in binding_specs:
		var action_name: StringName = binding_spec.get("action", &"")
		var keys: Array = binding_spec.get("keys", [])
		if action_name == &"":
			continue
		for keycode in keys:
			_ensure_key_binding(action_name, keycode as Key)

func _ensure_key_binding(action_name: StringName, keycode: Key) -> void:
	for event in InputMap.action_get_events(action_name):
		if not event is InputEventKey:
			continue
		var key_event := event as InputEventKey
		if _key_event_matches_key(key_event, keycode):
			return

	var key_event := InputEventKey.new()
	key_event.keycode = keycode
	key_event.physical_keycode = keycode
	InputMap.action_add_event(action_name, key_event)

func _key_event_matches_key(event: InputEventKey, keycode: Key) -> bool:
	return event.keycode == keycode or event.physical_keycode == keycode
