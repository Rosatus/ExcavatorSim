class_name VoxelCollisionReadiness
extends RefCounted

## Project identity wrapper around Voxel Tools' asynchronous mesh/collider
## derivatives. `is_area_meshed()` alone is insufficient: support becomes ready
## only after a matching changed-geometry physics query acknowledges the newest
## ticket.
var generation := 0
var revision := 0
var _next_ticket_id := 1
var _tickets: Dictionary = {}


func reset() -> void:
	generation += 1
	revision = 0
	_next_ticket_id = 1
	_tickets.clear()


func issue(area_voxels: AABB, purpose: StringName) -> Dictionary:
	revision += 1
	var ticket := {
		"ticket_id": _next_ticket_id,
		"generation": generation,
		"revision": revision,
		"purpose": purpose,
		"area_voxels": area_voxels,
		"meshed": false,
		"query_acknowledged": false,
		"issued_usec": Time.get_ticks_usec(),
		"meshed_usec": 0,
		"ready_usec": 0,
		"superseded_by_revision": 0,
	}
	var superseded_ticket_ids: Array[int] = []
	for ticket_id_value in _tickets.keys():
		var stored := _tickets[ticket_id_value] as Dictionary
		var stored_area := stored.get("area_voxels", AABB()) as AABB
		if int(stored.get("generation", -1)) == generation and stored_area.intersects(area_voxels):
			stored["superseded_by_revision"] = revision
			if area_voxels.encloses(stored_area):
				superseded_ticket_ids.append(int(ticket_id_value))
	for ticket_id in superseded_ticket_ids:
		# A fully covered ticket contributes no unique spatial readiness. Partial
		# overlaps must remain so points outside the new edit retain their prior
		# readiness (especially the initial whole-zone ticket).
		_tickets.erase(ticket_id)
	_next_ticket_id += 1
	_tickets[int(ticket["ticket_id"])] = ticket
	return ticket.duplicate(true)


func mark_meshed(ticket: Dictionary) -> bool:
	var current := _resolve_current(ticket)
	if current.is_empty():
		return false
	current["meshed"] = true
	if int(current["meshed_usec"]) == 0:
		current["meshed_usec"] = Time.get_ticks_usec()
	return true


func acknowledge_query(ticket: Dictionary) -> bool:
	var current := _resolve_current(ticket)
	if current.is_empty() or not bool(current["meshed"]):
		return false
	current["query_acknowledged"] = true
	current["ready_usec"] = Time.get_ticks_usec()
	return true


func is_ready(ticket: Dictionary) -> bool:
	var current := _resolve_current(ticket)
	return not current.is_empty() and bool(current["meshed"]) and bool(current["query_acknowledged"])


func is_point_ready(voxel_position: Vector3) -> bool:
	var newest: Dictionary = {}
	for stored_value in _tickets.values():
		var stored := stored_value as Dictionary
		if int(stored.get("generation", -1)) != generation:
			continue
		if not (stored.get("area_voxels", AABB()) as AABB).has_point(voxel_position):
			continue
		if newest.is_empty() or int(stored.get("revision", -1)) > int(newest.get("revision", -1)):
			newest = stored
	return not newest.is_empty() and bool(newest.get("meshed", false)) \
		and bool(newest.get("query_acknowledged", false))


func status(ticket: Dictionary) -> Dictionary:
	var current := _resolve_current(ticket)
	return current.duplicate(true) if not current.is_empty() else {
		"ticket_id": int(ticket.get("ticket_id", -1)),
		"generation": int(ticket.get("generation", -1)),
		"revision": int(ticket.get("revision", -1)),
		"stale": true,
		"meshed": false,
		"query_acknowledged": false,
	}


func _resolve_current(ticket: Dictionary) -> Dictionary:
	if int(ticket.get("generation", -1)) != generation:
		return {}
	var ticket_id := int(ticket.get("ticket_id", -1))
	var stored: Variant = _tickets.get(ticket_id)
	if not stored is Dictionary:
		return {}
	var current := stored as Dictionary
	if int(current.get("generation", -1)) != generation \
			or int(current.get("revision", -1)) != int(ticket.get("revision", -1)):
		return {}
	if int(current.get("superseded_by_revision", 0)) > 0:
		return {}
	return current
