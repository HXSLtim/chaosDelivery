extends RefCounted
class_name RuntimeLog

const FORCE_DEFAULT := -1
const FORCE_DISABLED := 0
const FORCE_ENABLED := 1

static var _force_mode: int = FORCE_DEFAULT


static func set_force_enabled(enabled: bool) -> void:
	_force_mode = FORCE_ENABLED if enabled else FORCE_DISABLED


static func clear_force_enabled() -> void:
	_force_mode = FORCE_DEFAULT


static func is_enabled() -> bool:
	if _force_mode == FORCE_ENABLED:
		return true
	if _force_mode == FORCE_DISABLED:
		return false
	return OS.is_debug_build() or OS.get_environment("CHAOS_DELIVERY_DEBUG_LOGS") == "1"


static func format_message(scope: String, message: String, fields: Dictionary = {}) -> String:
	var parts: Array[String] = ["[ChaosDelivery][%s] %s" % [scope, message]]
	var field_names: Array = fields.keys()
	field_names.sort()
	for field_name in field_names:
		var field_key := String(field_name)
		parts.append("%s=%s" % [field_key, _value_to_text(fields[field_name])])
	return " ".join(parts)


static func info(scope: String, message: String, fields: Dictionary = {}) -> void:
	if not is_enabled():
		return
	print(format_message(scope, message, fields))


static func warning_text(scope: String, message: String, fields: Dictionary = {}) -> String:
	return format_message(scope, message, fields)


static func _value_to_text(value: Variant) -> String:
	match typeof(value):
		TYPE_STRING:
			return String(value)
		TYPE_VECTOR2, TYPE_VECTOR2I, TYPE_VECTOR3, TYPE_VECTOR3I:
			return str(value)
		TYPE_BOOL:
			return "true" if bool(value) else "false"
		_:
			return str(value)
