extends Node

var current_phase: EventBus.GamePhase = EventBus.GamePhase.LOBBY
var current_level: String = ""
var local_player_id: int = -1
var local_player_name: String = "Player"

var current_gold: int = 0
var current_score: int = 0
var completed_orders: int = 0
var failed_orders: int = 0
var last_delivery_status: String = ""
var last_delivery_message: String = ""
var last_delivery_package_id: String = ""
var last_delivery_order_id: String = ""

func set_local_player_profile(player_id: int, player_name: String) -> void:
	local_player_id = player_id
	local_player_name = player_name
	EventBus.local_player_profile_changed.emit(local_player_id, local_player_name)

func get_local_player_profile() -> Dictionary:
	return {
		"id": local_player_id,
		"name": local_player_name
	}

func reset_session(level_name: String = "") -> void:
	current_level = level_name
	current_phase = EventBus.GamePhase.PREPARATION
	set_session_totals(0, 0, 0, 0)
	clear_delivery_feedback()
	EventBus.phase_changed.emit(current_phase, EventBus.GamePhase.LOBBY)

func set_phase(new_phase: EventBus.GamePhase) -> void:
	if current_phase == new_phase:
		return
	var old_phase := current_phase
	current_phase = new_phase
	EventBus.phase_changed.emit(new_phase, old_phase)

func add_gold(amount: int) -> void:
	set_session_totals(
		completed_orders,
		failed_orders,
		current_gold + amount,
		current_score
	)

func add_score(amount: int) -> void:
	set_session_totals(
		completed_orders,
		failed_orders,
		current_gold,
		current_score + amount
	)


func add_completed_orders(amount: int) -> void:
	if amount == 0:
		return
	set_session_totals(
		completed_orders + amount,
		failed_orders,
		current_gold,
		current_score
	)


func add_failed_orders(amount: int) -> void:
	if amount == 0:
		return
	set_session_totals(
		completed_orders,
		failed_orders + amount,
		current_gold,
		current_score
	)

func set_session_totals(completed: int, failed: int, gold: int, score: int) -> void:
	completed_orders = completed
	failed_orders = failed
	current_gold = gold
	current_score = score
	EventBus.session_totals_changed.emit(completed_orders, failed_orders, current_gold, current_score)

func get_session_totals() -> Dictionary:
	return {
		"completed_orders": completed_orders,
		"failed_orders": failed_orders,
		"gold": current_gold,
		"score": current_score
	}


func set_delivery_feedback(status: String, message: String, package_id: String = "", order_id: String = "") -> void:
	last_delivery_status = status
	last_delivery_message = message
	last_delivery_package_id = package_id
	last_delivery_order_id = order_id
	EventBus.delivery_feedback_changed.emit(
		last_delivery_status,
		last_delivery_message,
		last_delivery_package_id,
		last_delivery_order_id
	)


func clear_delivery_feedback() -> void:
	set_delivery_feedback("", "", "", "")


func get_delivery_feedback() -> Dictionary:
	return {
		"status": last_delivery_status,
		"message": last_delivery_message,
		"package_id": last_delivery_package_id,
		"order_id": last_delivery_order_id
	}


func apply_session_totals(completed: int, failed: int, gold: int, score: int) -> void:
	set_session_totals(completed, failed, gold, score)
