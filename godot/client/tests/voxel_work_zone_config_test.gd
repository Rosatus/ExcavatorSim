extends SceneTree

const VoxelWorkZoneConfig = preload("res://scripts/voxel_work_zone_config.gd")
const VoxelCollisionReadiness = preload("res://scripts/voxel_collision_readiness.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var failures: Array[String] = []
	_check_config(failures)
	_check_readiness(failures)
	if failures.is_empty():
		print("Voxel work-zone config/readiness contracts passed.")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _check_config(failures: Array[String]) -> void:
	var bounds := VoxelWorkZoneConfig.world_bounds()
	_expect(bounds.position == Vector3(-16.0, -6.0, 8.0), "world minimum is fixed", failures)
	_expect(bounds.end == Vector3(16.0, 4.0, 40.0), "world maximum is fixed", failures)
	_expect(VoxelWorkZoneConfig.owns_world_xz(Vector2(-16.0, 8.0)), "minimum boundary is owned", failures)
	_expect(not VoxelWorkZoneConfig.owns_world_xz(Vector2(16.0, 8.0)), "maximum X boundary is half-open", failures)
	_expect(not VoxelWorkZoneConfig.owns_world_xz(Vector2(0.0, 40.0)), "maximum Z boundary is half-open", failures)
	_expect(not VoxelWorkZoneConfig.owns_world_xz(Vector2.ZERO), "spawn remains on hard ground", failures)
	for scale_m in VoxelWorkZoneConfig.candidate_scales_m():
		var point := Vector3(3.25, -1.5, 21.75)
		var round_trip := VoxelWorkZoneConfig.voxel_to_world(
			VoxelWorkZoneConfig.world_to_voxel(point, scale_m),
			scale_m,
		)
		_expect(round_trip.is_equal_approx(point), "world/voxel round trip at %.3f m" % scale_m, failures)
	var fine_bounds := VoxelWorkZoneConfig.voxel_bounds()
	_expect(fine_bounds.position == Vector3(-128.0, -48.0, -128.0), "fine voxel minimum", failures)
	_expect(fine_bounds.size == Vector3(256.0, 80.0, 256.0), "fine voxel dimensions", failures)
	_expect(VoxelWorkZoneConfig.is_world_position_editable(Vector3(0.0, -1.0, 24.0)), "zone center is editable", failures)
	_expect(not VoxelWorkZoneConfig.is_world_position_editable(Vector3(-16.0, 0.0, 8.0)), "protected shell rejects boundary", failures)


func _check_readiness(failures: Array[String]) -> void:
	var readiness := VoxelCollisionReadiness.new()
	var first := readiness.issue(AABB(Vector3.ZERO, Vector3.ONE * 16.0), &"initial")
	_expect(not readiness.is_ready(first), "new ticket starts pending", failures)
	_expect(not readiness.acknowledge_query(first), "query cannot precede mesh", failures)
	_expect(readiness.mark_meshed(first), "current ticket accepts mesh", failures)
	_expect(readiness.acknowledge_query(first), "current meshed ticket accepts query", failures)
	_expect(readiness.is_ready(first), "mesh plus query publishes readiness", failures)
	_expect(readiness.is_point_ready(Vector3(0.5, 0.5, 0.5)), "ready ticket supports contained point", failures)
	var second := readiness.issue(AABB(Vector3.ONE, Vector3.ONE * 4.0), &"edit")
	_expect(not readiness.mark_meshed(first), "superseded revision rejects mesh", failures)
	_expect(not readiness.is_point_ready(Vector3(2.0, 2.0, 2.0)), "newest overlapping ticket disarms edited point", failures)
	_expect(readiness.is_point_ready(Vector3(10.0, 10.0, 10.0)), "unaffected point retains prior readiness", failures)
	var disjoint := readiness.issue(AABB(Vector3(32.0, 0.0, 0.0), Vector3.ONE * 4.0), &"disjoint_edit")
	_expect(readiness.mark_meshed(second), "older disjoint ticket remains independently current", failures)
	_expect(readiness.acknowledge_query(second), "older disjoint ticket can finish after a newer issue", failures)
	_expect(readiness.mark_meshed(disjoint), "new disjoint ticket accepts mesh", failures)
	readiness.reset()
	_expect(not readiness.mark_meshed(second), "pre-reset generation rejects mesh", failures)
	_expect(not readiness.is_ready(second), "pre-reset ticket never revives", failures)


func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append("voxel foundation: %s" % message)
