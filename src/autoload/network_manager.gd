extends Node

const DEFAULT_PORT: int = 7777
const MAX_PLAYERS: int = 4

enum ConnectionState {
	DISCONNECTED,
	CONNECTING,
	CONNECTED
}

var is_host: bool = false
var is_connected: bool = false
var is_connecting: bool = false
var connection_state: int = ConnectionState.DISCONNECTED
var last_connection_error: Error = OK
var connected_peers: Dictionary = {}

func has_active_peer() -> bool:
	return multiplayer.multiplayer_peer != null

func is_disconnected() -> bool:
	return connection_state == ConnectionState.DISCONNECTED

func get_connection_state() -> int:
	return connection_state

func get_connection_state_name() -> String:
	match connection_state:
		ConnectionState.DISCONNECTED:
			return "DISCONNECTED"
		ConnectionState.CONNECTING:
			return "CONNECTING"
		ConnectionState.CONNECTED:
			return "CONNECTED"
		_:
			return "UNKNOWN"

func get_connected_peer_count() -> int:
	return connected_peers.size()

func get_connected_peer_ids() -> Array[int]:
	var peer_ids: Array[int] = []
	for peer_id in connected_peers.keys():
		peer_ids.append(int(peer_id))
	return peer_ids

func _apply_state(
	next_state: int,
	next_host: bool,
	failure: Error = OK,
	reset_peers: bool = false
) -> void:
	connection_state = next_state
	is_connected = next_state == ConnectionState.CONNECTED
	is_connecting = next_state == ConnectionState.CONNECTING
	is_host = next_host
	last_connection_error = failure
	if reset_peers:
		connected_peers.clear()

func _clear_connection_state(
	reset_host: bool = true,
	close_peer: bool = true,
	failure: Error = OK
) -> bool:
	var had_peer := multiplayer.multiplayer_peer != null
	var next_host := is_host if not reset_host else false
	var did_change := (
		connection_state != ConnectionState.DISCONNECTED
		or is_host != next_host
		or connected_peers.size() > 0
		or had_peer
	)

	if close_peer and had_peer:
		multiplayer.multiplayer_peer.close()
	if had_peer:
		multiplayer.multiplayer_peer = null
	_apply_state(ConnectionState.DISCONNECTED, next_host, failure, true)
	return did_change

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func host_game(port: int = DEFAULT_PORT, max_players: int = MAX_PLAYERS) -> Error:
	if is_connected and is_host:
		return OK
	if multiplayer.multiplayer_peer != null:
		leave_game()

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, max_players)
	if err != OK:
		_apply_state(ConnectionState.DISCONNECTED, false, err, true)
		return err

	multiplayer.multiplayer_peer = peer
	_apply_state(ConnectionState.CONNECTED, true, OK, true)
	connected_peers[multiplayer.get_unique_id()] = true
	EventBus.network_state_changed.emit(is_connected, is_host)
	return OK

func join_game(address: String, port: int = DEFAULT_PORT) -> Error:
	if multiplayer.multiplayer_peer != null:
		_clear_connection_state(true, true, OK)

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		_clear_connection_state(true, false, err)
		return err

	multiplayer.multiplayer_peer = peer
	_apply_state(ConnectionState.CONNECTING, false, OK, true)
	EventBus.network_state_changed.emit(is_connected, is_host)
	return OK

func leave_game() -> void:
	if _clear_connection_state(true, true, OK):
		EventBus.network_state_changed.emit(is_connected, is_host)

func _on_peer_connected(peer_id: int) -> void:
	connected_peers[peer_id] = true
	EventBus.player_joined.emit(peer_id)

func _on_peer_disconnected(peer_id: int) -> void:
	connected_peers.erase(peer_id)
	EventBus.player_left.emit(peer_id)

func _on_connected_to_server() -> void:
	if multiplayer.multiplayer_peer == null or is_host:
		return
	_apply_state(ConnectionState.CONNECTED, false, OK, true)
	connected_peers[multiplayer.get_unique_id()] = true
	connected_peers[1] = true
	EventBus.network_state_changed.emit(is_connected, is_host)

func _on_connection_failed() -> void:
	if is_host or connection_state != ConnectionState.CONNECTING:
		return
	if _clear_connection_state(true, true, ERR_CANT_CONNECT):
		EventBus.network_state_changed.emit(is_connected, is_host)

func _on_server_disconnected() -> void:
	if connection_state == ConnectionState.DISCONNECTED:
		return
	if _clear_connection_state(true, true, OK):
		EventBus.network_state_changed.emit(is_connected, is_host)
