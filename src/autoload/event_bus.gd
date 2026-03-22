extends Node

signal phase_changed(new_phase: GamePhase, old_phase: GamePhase)
signal network_state_changed(is_connected: bool, is_host: bool)
signal player_joined(peer_id: int)
signal player_left(peer_id: int)
signal order_added(order_id: String)
signal order_completed(order_id: String)
signal local_player_profile_changed(player_id: int, player_name: String)
signal session_totals_changed(completed_orders: int, failed_orders: int, gold: int, score: int)
signal delivery_feedback_changed(status: String, message: String, package_id: String, order_id: String)

enum GamePhase {
	LOBBY,
	PREPARATION,
	WORKING,
	SETTLEMENT,
	PAUSED
}
