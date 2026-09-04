class_name VoxelCollisionReadiness
extends RefCounted

const WorkZoneConfig = preload("res://scripts/voxel_work_zone_config.gd")
const TimingWindow = preload("res://scripts/voxel_timing_window.gd")

## Project identity wrapper around Voxel Tools' asynchronous mesh/collider
## derivatives. Current readiness is owned by canonical mesh blocks, not by an
## ever-growing list of arbitrary edit AABBs. Point queries are therefore O(1).
const MAX_COMPLETED_TICKET_RECEIPTS := 256

var generation := 0
var revision := 0
var _next_ticket_id := 1
var _tickets: Dictionary = {}
var _ticket_order: Array[int] = []
var _blocks: Dictionary = {}
var _mesh_latency_usec := TimingWindow.new()
var _collision_latency_usec := TimingWindow.new()
var _end_to_end_latency_usec := TimingWindow.new()
var _last_acknowledged_revision := 0
var _last_acknowledged_usec := 0


func reset() -> void:
	generation += 1
	revision = 0
	_next_ticket_id = 1
	_tickets.clear()
	_ticket_order.clear()
	_blocks.clear()
	_mesh_latency_usec.clear()
	_collision_latency_usec.clear()
	_end_to_end_latency_usec.clear()
	_last_acknowledged_revision = 0
	_last_acknowledged_usec = 0


func issue(area_voxels: AABB, purpose: StringName) -> Dictionary:
	revision += 1
	var ticket_id := _next_ticket_id
	var issued_usec := Time.get_ticks_usec()
	var block_keys := WorkZoneConfig.mesh_block_keys_for_area(area_voxels)
	var ticket := {
		"ticket_id": ticket_id,
		"generation": generation,
		"revision": revision,
		"purpose": purpose,
		"area_voxels": area_voxels,
		"block_keys": block_keys,
		"block_count": block_keys.size(),
		"current_block_count": block_keys.size(),
		"superseded_block_count": 0,
		"meshed": false,
		"query_acknowledged": false,
		"issued_usec": issued_usec,
		"meshed_usec": 0,
		"ready_usec": 0,
		"superseded_by_revision": 0,
	}
	for block_key in block_keys:
		var previous_value: Variant = _blocks.get(block_key)
		var fallback_acknowledged := false
		var fallback_revision := 0
		if previous_value is Dictionary:
			var previous := previous_value as Dictionary
			fallback_acknowledged = bool(previous.get("query_acknowledged", false)) \
				or bool(previous.get("fallback_acknowledged", false))
			fallback_revision = int(previous.get("revision", 0)) \
				if bool(previous.get("query_acknowledged", false)) \
				else int(previous.get("fallback_revision", 0))
			var previous_ticket_id := int(previous.get("ticket_id", -1))
			var previous_ticket_value: Variant = _tickets.get(previous_ticket_id)
			if previous_ticket_value is Dictionary:
				var previous_ticket := previous_ticket_value as Dictionary
				previous_ticket["superseded_by_revision"] = revision
				previous_ticket["superseded_block_count"] = int(previous_ticket.get("superseded_block_count", 0)) + 1
				previous_ticket["current_block_count"] = maxi(0, int(previous_ticket.get("current_block_count", 0)) - 1)
		_blocks[block_key] = {
			"ticket_id": ticket_id,
			"generation": generation,
			"revision": revision,
			"meshed": false,
			"query_acknowledged": false,
			"issued_usec": issued_usec,
			"meshed_usec": 0,
			"ready_usec": 0,
			"fallback_acknowledged": fallback_acknowledged,
			"fallback_revision": fallback_revision,
		}
	_next_ticket_id += 1
	_tickets[ticket_id] = ticket
	_ticket_order.append(ticket_id)
	_prune_ticket_receipts()
	return ticket.duplicate(true)


func mark_meshed(ticket: Dictionary) -> bool:
	var current := _resolve_mutable_current(ticket)
	if current.is_empty():
		return false
	var now_usec := Time.get_ticks_usec()
	current["meshed"] = true
	if int(current["meshed_usec"]) == 0:
		current["meshed_usec"] = now_usec
		_mesh_latency_usec.record(now_usec - int(current.get("issued_usec", now_usec)))
	for block_key in current.get("block_keys", PackedStringArray()) as PackedStringArray:
		var block_value: Variant = _blocks.get(block_key)
		if block_value is Dictionary:
			var block := block_value as Dictionary
			if int(block.get("ticket_id", -1)) == int(current["ticket_id"]):
				block["meshed"] = true
				block["meshed_usec"] = now_usec
	return true


func acknowledge_query(ticket: Dictionary) -> bool:
	var current := _resolve_mutable_current(ticket)
	if current.is_empty() or not bool(current["meshed"]):
		return false
	var now_usec := Time.get_ticks_usec()
	current["query_acknowledged"] = true
	current["ready_usec"] = now_usec
	_collision_latency_usec.record(now_usec - int(current.get("meshed_usec", now_usec)))
	_end_to_end_latency_usec.record(now_usec - int(current.get("issued_usec", now_usec)))
	_last_acknowledged_revision = int(current.get("revision", 0))
	_last_acknowledged_usec = now_usec
	for block_key in current.get("block_keys", PackedStringArray()) as PackedStringArray:
		var block_value: Variant = _blocks.get(block_key)
		if block_value is Dictionary:
			var block := block_value as Dictionary
			if int(block.get("ticket_id", -1)) == int(current["ticket_id"]):
				block["query_acknowledged"] = true
				block["ready_usec"] = now_usec
	_prune_ticket_receipts()
	return true


func retire(ticket: Dictionary, reason: StringName) -> bool:
	var receipt := _resolve_receipt(ticket)
	if receipt.is_empty():
		return false
	var retired_blocks := 0
	for block_key in receipt.get("block_keys", PackedStringArray()) as PackedStringArray:
		var block_value: Variant = _blocks.get(block_key)
		if not block_value is Dictionary:
			continue
		var block := block_value as Dictionary
		if int(block.get("ticket_id", -1)) != int(receipt.get("ticket_id", -1)):
			continue
		retired_blocks += 1
		if bool(block.get("fallback_acknowledged", false)):
			_blocks[block_key] = {
				"ticket_id": -1,
				"generation": generation,
				"revision": int(block.get("fallback_revision", 0)),
				"meshed": true,
				"query_acknowledged": true,
				"issued_usec": 0,
				"meshed_usec": 0,
				"ready_usec": 0,
				"fallback_acknowledged": false,
				"fallback_revision": 0,
			}
		else:
			_blocks.erase(block_key)
	receipt["current_block_count"] = maxi(
		0,
		int(receipt.get("current_block_count", 0)) - retired_blocks,
	)
	receipt["retired_block_count"] = int(receipt.get("retired_block_count", 0)) + retired_blocks
	receipt["retired_reason"] = reason
	_prune_ticket_receipts()
	return retired_blocks > 0


func is_ready(ticket: Dictionary) -> bool:
	var receipt := _resolve_receipt(ticket)
	return not receipt.is_empty() and bool(receipt["meshed"]) and bool(receipt["query_acknowledged"])


func is_point_ready(voxel_position: Vector3) -> bool:
	var block_value: Variant = _blocks.get(WorkZoneConfig.mesh_block_key(voxel_position))
	if not block_value is Dictionary:
		return false
	var block := block_value as Dictionary
	return int(block.get("generation", -1)) == generation \
		and ((bool(block.get("meshed", false)) \
			and bool(block.get("query_acknowledged", false))) \
			or bool(block.get("fallback_acknowledged", false)))


func status(ticket: Dictionary) -> Dictionary:
	var receipt := _resolve_receipt(ticket)
	if receipt.is_empty():
		return {
			"ticket_id": int(ticket.get("ticket_id", -1)),
			"generation": int(ticket.get("generation", -1)),
			"revision": int(ticket.get("revision", -1)),
			"stale": true,
			"meshed": false,
			"query_acknowledged": false,
		}
	var result := receipt.duplicate(true)
	result["stale"] = int(receipt.get("generation", -1)) != generation \
		or int(receipt.get("current_block_count", 0)) <= 0
	result["partially_superseded"] = int(receipt.get("superseded_block_count", 0)) > 0 \
		and int(receipt.get("current_block_count", 0)) > 0
	return result


func get_status_snapshot() -> Dictionary:
	var pending_blocks := 0
	var meshed_blocks := 0
	var ready_blocks := 0
	var fallback_ready_blocks := 0
	for block_value in _blocks.values():
		var block := block_value as Dictionary
		if bool(block.get("query_acknowledged", false)):
			ready_blocks += 1
		elif bool(block.get("meshed", false)):
			meshed_blocks += 1
		else:
			pending_blocks += 1
		if not bool(block.get("query_acknowledged", false)) \
				and bool(block.get("fallback_acknowledged", false)):
			fallback_ready_blocks += 1
	return {
		"generation": generation,
		"revision": revision,
		"canonical_block_count": _blocks.size(),
		"pending_block_count": pending_blocks,
		"meshed_block_count": meshed_blocks,
		"ready_block_count": ready_blocks,
		"fallback_ready_block_count": fallback_ready_blocks,
		"visual_collision_pending_block_count": pending_blocks + meshed_blocks,
		"ticket_receipt_count": _tickets.size(),
		"last_acknowledged_revision": _last_acknowledged_revision,
		"last_acknowledged_usec": _last_acknowledged_usec,
		"mesh_latency_usec": _mesh_latency_usec.snapshot(),
		"collision_latency_usec": _collision_latency_usec.snapshot(),
		"end_to_end_latency_usec": _end_to_end_latency_usec.snapshot(),
	}


func _resolve_receipt(ticket: Dictionary) -> Dictionary:
	if int(ticket.get("generation", -1)) != generation:
		return {}
	var stored_value: Variant = _tickets.get(int(ticket.get("ticket_id", -1)))
	if not stored_value is Dictionary:
		return {}
	var stored := stored_value as Dictionary
	if int(stored.get("generation", -1)) != generation \
		or int(stored.get("revision", -1)) != int(ticket.get("revision", -1)):
		return {}
	return stored


func _resolve_mutable_current(ticket: Dictionary) -> Dictionary:
	var current := _resolve_receipt(ticket)
	if current.is_empty() or int(current.get("current_block_count", 0)) <= 0:
		return {}
	return current


func _prune_ticket_receipts() -> void:
	if _tickets.size() <= MAX_COMPLETED_TICKET_RECEIPTS:
		return
	var kept_order: Array[int] = []
	for ticket_id in _ticket_order:
		var ticket_value: Variant = _tickets.get(ticket_id)
		if not ticket_value is Dictionary:
			continue
		var ticket := ticket_value as Dictionary
		var completed := bool(ticket.get("query_acknowledged", false)) \
			or int(ticket.get("current_block_count", 0)) <= 0
		if ticket_id != 1 and completed and _tickets.size() > MAX_COMPLETED_TICKET_RECEIPTS:
			_tickets.erase(ticket_id)
			continue
		kept_order.append(ticket_id)
	_ticket_order = kept_order
