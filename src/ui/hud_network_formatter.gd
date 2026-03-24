extends RefCounted
class_name HudNetworkFormatter


static func format_status(
	connected: Variant,
	host: Variant,
	peer_count: int,
	local_peer_id: int,
	connection_state: String,
	is_connecting: Variant,
	last_connection_error: Variant
) -> String:
	if connected == null:
		return "Unknown (Missing is_connected)"

	var remote_count: int = maxi(peer_count - 1, 0)
	var role := "Role Unknown"
	if host == true:
		role = "Host"
	elif host == false:
		role = "Client"

	var parts: Array[String] = [role, "peers=%d" % peer_count, "remote=%d" % remote_count]
	if local_peer_id > 0:
		parts.append("id=%d" % local_peer_id)
	if connection_state != "":
		parts.append("link=%s" % connection_state)

	var status := "Disconnected"
	if is_connecting == true:
		status = "Connecting"
	elif connected == true:
		status = "Connected"

	if status == "Disconnected" and last_connection_error is int and int(last_connection_error) != OK:
		parts.append("last_error=%s" % error_string(int(last_connection_error)))

	return "%s (%s)" % [status, ", ".join(parts)]


static func format_detail(
	connected: Variant,
	host: Variant,
	peer_count: int,
	state_name: String,
	is_connecting: Variant,
	last_error: Variant
) -> String:
	var remote_count: int = maxi(peer_count - 1, 0)

	if is_connecting == true or state_name == "Connecting":
		return "Net Detail: Connecting to host... waiting for handshake."
	if connected == true and host == true:
		return "Net Detail: Hosting %d remote player(s). You validate deliveries." % remote_count
	if connected == true and host == false:
		return "Net Detail: Client mode with %d remote player(s). Host validates deliveries." % remote_count
	if last_error is int and int(last_error) != OK:
		return "Net Detail: Disconnected (%s)." % error_string(int(last_error))
	return "Net Detail: Offline. F5 host LAN / F6 join localhost."


static func connection_state_name(state_value: Variant) -> String:
	if state_value is int:
		match int(state_value):
			0:
				return "Disconnected"
			1:
				return "Connecting"
			2:
				return "Connected"
			_:
				return "Unknown"
	if state_value is String:
		return humanize_token(String(state_value))
	return ""


static func humanize_token(value: String) -> String:
	var words := value.replace("_", " ").replace("-", " ").split(" ", false)
	var humanized_words: Array[String] = []
	for word in words:
		humanized_words.append(word.capitalize())
	if humanized_words.is_empty():
		return value
	return " ".join(humanized_words)
