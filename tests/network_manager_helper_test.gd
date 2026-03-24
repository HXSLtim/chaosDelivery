extends RefCounted

var _tree: SceneTree
var _failures: Array[String] = []
var _saved_network_state: Dictionary = {}


func run(tree: SceneTree) -> Array[String]:
	_tree = tree
	_failures.clear()
	_capture_network_state()

	_test_has_active_peer_ignores_default_offline_peer()
	_test_peer_slots_are_stable_for_large_peer_ids()
	_test_peer_slots_fallback_safely_when_roster_is_empty()
	_test_peer_slots_ignore_insertion_order()
	_test_get_local_peer_slot_returns_slot_one_while_hosting()
	_test_apply_state_updates_flags_and_clears_peers()
	_test_clear_connection_state_respects_host_reset_parameter()
	_test_get_connected_peer_ids_ignores_non_numeric_keys()

	_restore_network_state()
	return _failures


func _test_apply_state_updates_flags_and_clears_peers() -> void:
	var network_manager := _network_manager()
	network_manager.connected_peers = {1: true, 9: true}

	network_manager._apply_state(network_manager.ConnectionState.CONNECTING, false, ERR_BUSY, true)

	_assert(
		network_manager.connection_state == network_manager.ConnectionState.CONNECTING,
		"_apply_state should set explicit connection_state"
	)
	_assert(not network_manager.is_connected, "_apply_state CONNECTING should keep is_connected false")
	_assert(network_manager.is_connecting, "_apply_state CONNECTING should set is_connecting true")
	_assert(not network_manager.is_host, "_apply_state should update host role flag")
	_assert(network_manager.last_connection_error == ERR_BUSY, "_apply_state should store last failure code")
	_assert(network_manager.connected_peers.is_empty(), "_apply_state reset_peers should clear peer cache")


func _test_clear_connection_state_respects_host_reset_parameter() -> void:
	var network_manager := _network_manager()
	network_manager._apply_state(network_manager.ConnectionState.CONNECTED, true, OK, false)
	network_manager.connected_peers = {1: true, 2: true}

	network_manager._clear_connection_state(false, false, ERR_CANT_CONNECT)

	_assert(
		network_manager.connection_state == network_manager.ConnectionState.DISCONNECTED,
		"_clear_connection_state should force disconnected state"
	)
	_assert(not network_manager.is_connected, "_clear_connection_state should clear connected flag")
	_assert(not network_manager.is_connecting, "_clear_connection_state should clear connecting flag")
	_assert(network_manager.is_host, "_clear_connection_state(reset_host=false) should preserve host role")
	_assert(
		network_manager.last_connection_error == ERR_CANT_CONNECT,
		"_clear_connection_state should persist provided failure reason"
	)
	_assert(network_manager.connected_peers.is_empty(), "_clear_connection_state should clear peer cache")

	network_manager._clear_connection_state(true, false, OK)
	_assert(not network_manager.is_host, "_clear_connection_state(reset_host=true) should clear host role")


func _test_has_active_peer_ignores_default_offline_peer() -> void:
	var network_manager := _network_manager()
	network_manager._apply_state(network_manager.ConnectionState.DISCONNECTED, false, OK, true)
	_assert(
		not network_manager.has_active_peer(),
		"has_active_peer should ignore the default OfflineMultiplayerPeer so offline world spawning is not blocked"
	)


func _test_peer_slots_are_stable_for_large_peer_ids() -> void:
	var network_manager := _network_manager()
	network_manager.connected_peers = {
		1: true,
		1096654874: true,
		2147483640: true
	}
	_assert(network_manager.get_peer_slot(1) == 1, "host should keep slot P1")
	_assert(network_manager.get_peer_slot(1096654874) == 2, "first remote peer should map to slot P2")
	_assert(network_manager.get_peer_slot(2147483640) == 3, "second remote peer should map to slot P3")


func _test_peer_slots_fallback_safely_when_roster_is_empty() -> void:
	var network_manager := _network_manager()
	network_manager.connected_peers = {}
	_assert(network_manager.get_peer_slot(1) == 1, "host should default to slot P1 when roster is empty")
	_assert(network_manager.get_peer_slot(99) == 2, "unknown remote peer should default to slot P2 when roster is empty")


func _test_peer_slots_ignore_insertion_order() -> void:
	var network_manager := _network_manager()
	network_manager.connected_peers = {
		2147483640: true,
		1: true,
		1096654874: true
	}
	_assert(network_manager.get_peer_slot(1) == 1, "peer slots should keep host at P1 regardless of insertion order")
	_assert(network_manager.get_peer_slot(1096654874) == 2, "peer slots should sort peer ids before assigning P2")
	_assert(network_manager.get_peer_slot(2147483640) == 3, "peer slots should sort peer ids before assigning P3")


func _test_get_local_peer_slot_returns_slot_one_while_hosting() -> void:
	var network_manager := _network_manager()
	network_manager.leave_game()
	_assert(network_manager.host_game() == OK, "setup should allow hosting for local peer slot test")
	# 大型 peer id 用来模拟 ENet 生成的远端连接标识，而不是稳定的本地槽位编号。
	network_manager.connected_peers = {
		1: true,
		1096654874: true
	}
	_assert(network_manager.get_local_peer_slot() == 1, "host should always report local slot P1 while hosting")
	network_manager.leave_game()


func _test_get_connected_peer_ids_ignores_non_numeric_keys() -> void:
	var network_manager := _network_manager()
	network_manager.connected_peers = {
		1: true,
		"not_a_peer": true,
		3.0: true
	}

	var peer_ids: Array[int] = network_manager.get_connected_peer_ids()
	peer_ids.sort()
	_assert(peer_ids == [1, 3], "get_connected_peer_ids should ignore non-numeric peer keys")


func _capture_network_state() -> void:
	var network_manager := _network_manager()
	_saved_network_state = {
		"is_host": network_manager.is_host,
		"is_connected": network_manager.is_connected,
		"is_connecting": network_manager.is_connecting,
		"connection_state": network_manager.connection_state,
		"last_connection_error": int(network_manager.last_connection_error),
		"connected_peers": network_manager.connected_peers.duplicate(true)
	}


func _restore_network_state() -> void:
	var network_manager := _network_manager()
	network_manager.set("is_host", bool(_saved_network_state.get("is_host", false)))
	network_manager.set("is_connected", bool(_saved_network_state.get("is_connected", false)))
	network_manager.set("is_connecting", bool(_saved_network_state.get("is_connecting", false)))
	network_manager.set("connection_state", int(_saved_network_state.get("connection_state", 0)))
	network_manager.set("last_connection_error", int(_saved_network_state.get("last_connection_error", int(OK))))
	network_manager.set("connected_peers", _saved_network_state.get("connected_peers", {}).duplicate(true))


func _network_manager() -> Node:
	return _tree.root.get_node("NetworkManager")


func _assert(condition: bool, message: String) -> void:
	if condition:
		return
	_failures.append(message)
