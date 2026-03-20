extends Node

var current_phase: EventBus.GamePhase = EventBus.GamePhase.LOBBY
var current_level: String = ""
var local_player_id: int = -1
var local_player_name: String = "Player"

var current_gold: int = 0
var current_score: int = 0
var completed_orders: int = 0
var failed_orders: int = 0

func reset_session(level_name: String = "") -> void:
	current_level = level_name
	current_phase = EventBus.GamePhase.PREPARATION
	current_gold = 0
	current_score = 0
	completed_orders = 0
	failed_orders = 0
	EventBus.phase_changed.emit(current_phase, EventBus.GamePhase.LOBBY)

func set_phase(new_phase: EventBus.GamePhase) -> void:
	if current_phase == new_phase:
		return
	var old_phase := current_phase
	current_phase = new_phase
	EventBus.phase_changed.emit(new_phase, old_phase)

func add_gold(amount: int) -> void:
	current_gold += amount

func add_score(amount: int) -> void:
	current_score += amount


func apply_session_totals(completed: int, failed: int, gold: int, score: int) -> void:
	completed_orders = completed
	failed_orders = failed
	current_gold = gold
	current_score = score
