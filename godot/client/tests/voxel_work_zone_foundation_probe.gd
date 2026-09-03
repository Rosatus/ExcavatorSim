extends SceneTree

const VoxelWorkZoneConfig = preload("res://scripts/voxel_work_zone_config.gd")
const VoxelWorkZone = preload("res://scripts/voxel_work_zone.gd")

const MAX_READY_FRAMES := 1200
const EDIT_RADIUS_WORLD_M := 0.75
const EDIT_START_WORLD := Vector3(-2.0, -0.35, 24.0)
const EDIT_END_WORLD := Vector3(2.0, -0.35, 24.0)
const SYNC_EDIT_BUDGET_USEC := 2000
const INITIAL_READY_BUDGET_FRAMES := 60
const COLLIDER_ACK_BUDGET_USEC := 250000

var _max_process_ms := 0.0
var _max_physics_ms := 0.0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var failures: Array[String] = []
	var candidates: Array[Dictionary] = []
	for scale_m in VoxelWorkZoneConfig.candidate_scales_m():
		var result := await _run_candidate(float(scale_m))
		candidates.append(result)
		if not bool(result.get("passed", false)):
			failures.append("scale %.3f failed: %s" % [scale_m, result.get("error", "unknown")])
	var evidence := {
		"schema_version": 1,
		"engine": Engine.get_version_info(),
		"candidates": candidates,
		"selected_scale_m": _select_scale(candidates),
		"budgets": {
			"sync_edit_usec": SYNC_EDIT_BUDGET_USEC,
			"initial_ready_frames": INITIAL_READY_BUDGET_FRAMES,
			"collider_ack_usec": COLLIDER_ACK_BUDGET_USEC,
			"dropped_blocks": 0,
		},
		"passed": failures.is_empty(),
		"failures": failures,
	}
	var output_dir := _output_directory()
	if not output_dir.is_empty():
		DirAccess.make_dir_recursive_absolute(output_dir)
		var evidence_file := FileAccess.open(output_dir.path_join("evidence.json"), FileAccess.WRITE)
		if evidence_file == null:
			failures.append("could not write evidence.json")
			evidence["passed"] = false
		else:
			evidence_file.store_string(JSON.stringify(evidence, "  "))
			evidence_file.close()
	print(JSON.stringify(evidence))
	for failure in failures:
		push_error(failure)
	quit(0 if failures.is_empty() else 1)


func _output_directory() -> String:
	var arguments := OS.get_cmdline_user_args()
	for index in arguments.size():
		if arguments[index] == "--output-dir" and index + 1 < arguments.size():
			return ProjectSettings.globalize_path(arguments[index + 1])
	return ""


func _run_candidate(scale_m: float) -> Dictionary:
	_max_process_ms = 0.0
	_max_physics_ms = 0.0
	var memory_before := int(Performance.get_monitor(Performance.MEMORY_STATIC))
	var candidate_started := Time.get_ticks_usec()
	var zone := VoxelWorkZone.new()
	zone.name = "ProbeZone_%d" % roundi(scale_m * 1000.0)
	zone.voxel_scale_m = scale_m
	root.add_child(zone)
	if zone.terrain == null:
		var error := zone.last_error
		zone.queue_free()
		await process_frame
		return {"scale_m": scale_m, "passed": false, "error": error}

	var initial_frames := await _wait_initial_ready(zone)
	if initial_frames < 0:
		var initial_status := zone.get_status_snapshot()
		zone.queue_free()
		await process_frame
		return {"scale_m": scale_m, "passed": false, "error": "initial collision timeout", "status": initial_status}

	var tool := zone.get_voxel_tool()
	if tool == null:
		zone.queue_free()
		await process_frame
		return {"scale_m": scale_m, "passed": false, "error": "voxel tool unavailable"}
	var points := PackedVector3Array([
		VoxelWorkZoneConfig.world_to_voxel(EDIT_START_WORLD, scale_m),
		VoxelWorkZoneConfig.world_to_voxel(EDIT_END_WORLD, scale_m),
	])
	var radii := PackedFloat32Array([EDIT_RADIUS_WORLD_M / scale_m, EDIT_RADIUS_WORLD_M / scale_m])
	tool.channel = VoxelBuffer.CHANNEL_SDF
	tool.mode = VoxelTool.MODE_REMOVE
	var edit_started := Time.get_ticks_usec()
	tool.do_path(points, radii)
	var sync_edit_usec := Time.get_ticks_usec() - edit_started
	var edit_area := AABB(
		points[0].min(points[1]) - Vector3.ONE * radii[0],
		(points[1] - points[0]).abs() + Vector3.ONE * radii[0] * 2.0,
	)
	var ticket := zone.issue_edit_ticket(edit_area, &"bucket_path_probe")
	var collider_wait_started := Time.get_ticks_usec()
	var edit_frames := await _wait_ticket_meshed(zone, ticket)
	if edit_frames < 0:
		var timeout_status := zone.get_status_snapshot()
		zone.queue_free()
		await process_frame
		return {"scale_m": scale_m, "passed": false, "error": "edit remesh timeout", "status": timeout_status}
	await physics_frame
	_sample_frame_monitors()
	await physics_frame
	_sample_frame_monitors()
	var hit := _ray_hit(Vector2(0.0, 24.0))
	var hit_y := float(hit.get("position", Vector3(0.0, INF, 0.0)).y) if not hit.is_empty() else INF
	var query_changed := not hit.is_empty() and hit_y < -0.65
	if query_changed:
		zone.acknowledge_ticket_query(ticket)
	var collider_ack_usec := Time.get_ticks_usec() - collider_wait_started
	var statistics := zone.terrain.get_statistics()
	var dropped_blocks := int(statistics.get("dropped_block_loads", 0)) + int(statistics.get("dropped_block_meshs", 0))
	var within_budget := sync_edit_usec <= SYNC_EDIT_BUDGET_USEC \
		and initial_frames <= INITIAL_READY_BUDGET_FRAMES \
		and collider_ack_usec <= COLLIDER_ACK_BUDGET_USEC \
		and dropped_blocks == 0
	var result := {
		"scale_m": scale_m,
		"voxel_dimensions": VoxelWorkZoneConfig.voxel_bounds(scale_m).size,
		"initial_ready_frames": initial_frames,
		"sync_edit_usec": sync_edit_usec,
		"edit_ready_frames": edit_frames,
		"collider_ack_usec": collider_ack_usec,
		"changed_query_hit_y": hit_y,
		"query_changed": query_changed,
		"ticket_ready": zone.readiness.is_ready(ticket),
		"statistics": statistics,
		"memory_before_bytes": memory_before,
		"memory_after_bytes": int(Performance.get_monitor(Performance.MEMORY_STATIC)),
		"max_process_ms": _max_process_ms,
		"max_physics_ms": _max_physics_ms,
		"candidate_elapsed_usec": Time.get_ticks_usec() - candidate_started,
		"within_budget": within_budget,
		"passed": query_changed and zone.readiness.is_ready(ticket) and within_budget,
		"error": "" if query_changed and within_budget else (
			"foundation budget exceeded" if query_changed else "changed-geometry Jolt query did not acknowledge edit"
		),
	}
	zone.queue_free()
	await process_frame
	return result


func _wait_initial_ready(zone: Node) -> int:
	for frame in MAX_READY_FRAMES:
		if zone.readiness.is_ready(zone.initial_ticket):
			return frame
		await physics_frame
		_sample_frame_monitors()
	return -1


func _wait_ticket_meshed(zone: Node, ticket: Dictionary) -> int:
	for frame in MAX_READY_FRAMES:
		if zone.poll_ticket_meshed(ticket):
			return frame
		await physics_frame
		_sample_frame_monitors()
	return -1


func _sample_frame_monitors() -> void:
	_max_process_ms = maxf(_max_process_ms, float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0)
	_max_physics_ms = maxf(_max_physics_ms, float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0)


func _ray_hit(world_xz: Vector2) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(world_xz.x, 2.0, world_xz.y),
		Vector3(world_xz.x, -3.0, world_xz.y),
		VoxelWorkZoneConfig.TERRAIN_COLLISION_LAYER,
	)
	query.collide_with_areas = false
	return root.get_world_3d().direct_space_state.intersect_ray(query)


func _select_scale(candidates: Array[Dictionary]) -> float:
	for candidate in candidates:
		if bool(candidate.get("passed", false)) and is_equal_approx(float(candidate.get("scale_m", 0.0)), VoxelWorkZoneConfig.DEFAULT_VOXEL_SCALE_M):
			return VoxelWorkZoneConfig.DEFAULT_VOXEL_SCALE_M
	for candidate in candidates:
		if bool(candidate.get("passed", false)):
			return float(candidate.get("scale_m", 0.0))
	return 0.0
