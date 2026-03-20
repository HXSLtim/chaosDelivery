extends Node

const DEFAULT_PORT: int = 7777
const MAX_PLAYERS: int = 4

var is_host: bool = false
var is_connected: bool = false
var connected_peers: Dictionary = {}

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func host_game(port: int = DEFAULT_PORT, max_players: int = MAX_PLAYERS) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, max_players)
	if err != OK:
		return err

	multiplayer.multiplayer_peer = peer
	is_host = true
	is_connected = true
	connected_peers.clear()
	connected_peers[multiplayer.get_unique_id()] = true
	EventBus.network_state_changed.emit(is_connected, is_host)
	return OK

func join_game(address: String, port: int = DEFAULT_PORT) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		return err

	multiplayer.multiplayer_peer = peer
	is_host = false
	return OK

func leave_game() -> void:
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	is_connected = false
	is_host = false
	connected_peers.clear()
	EventBus.network_state_changed.emit(is_connected, is_host)

func _on_peer_connected(peer_id: int) -> void:
	connected_peers[peer_id] = true
	EventBus.player_joined.emit(peer_id)

func _on_peer_disconnected(peer_id: int) -> void:
	connected_peers.erase(peer_id)
	EventBus.player_left.emit(peer_id)

func _on_connected_to_server() -> void:
	is_connected = true
	connected_peers.clear()
	connected_peers[multiplayer.get_unique_id()] = true
	connected_peers[1] = true
	EventBus.network_state_changed.emit(is_connected, is_host)

func _on_connection_failed() -> void:
	is_connected = false
	EventBus.network_state_changed.emit(is_connected, is_host)

func _on_server_disconnected() -> void:
	is_connected = false
	is_host = false
	connected_peers.clear()
	EventBus.network_state_changed.emit(is_connected, is_host)
