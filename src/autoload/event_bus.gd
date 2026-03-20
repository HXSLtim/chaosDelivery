extends Node

signal phase_changed(new_phase: GamePhase, old_phase: GamePhase)
signal network_state_changed(is_connected: bool, is_host: bool)
signal player_joined(peer_id: int)
signal player_left(peer_id: int)
signal order_added(order_id: String)
signal order_completed(order_id: String)

enum GamePhase {
	LOBBY,
	PREPARATION,
	WORKING,
	SETTLEMENT,
	PAUSED
}
