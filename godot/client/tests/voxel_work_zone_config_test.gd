extends SceneTree

const VoxelWorkZoneConfig = preload("res://scripts/voxel_work_zone_config.gd")
const VoxelCollisionReadiness = preload("res://scripts/voxel_collision_readiness.gd")
const VoxelTimingWindow = preload("res://scripts/voxel_timing_window.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var failures: Array[String] = []
	_check_config(failures)
	_check_readiness(failures)
	_check_timing_window(failures)
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
	var edge_keys := VoxelWorkZoneConfig.mesh_block_keys_for_area(AABB(Vector3.ZERO, Vector3.ONE * 16.0))
	_expect(edge_keys == PackedStringArray(["0:0:0"]), "half-open block area excludes exact neighboring edges", failures)
	var cross_keys := VoxelWorkZoneConfig.mesh_block_keys_for_area(AABB(Vector3(15.0, 0.0, 0.0), Vector3(2.0, 1.0, 1.0)))
	_expect(cross_keys == PackedStringArray(["0:0:0", "1:0:0"]), "cross-edge edit owns both canonical blocks", failures)


func _check_readiness(failures: Array[String]) -> void:
	var readiness := VoxelCollisionReadiness.new()
	var first := readiness.issue(AABB(Vector3.ZERO, Vector3.ONE * 16.0), &"initial")
	_expect(not readiness.is_ready(first), "new ticket starts pending", failures)
	_expect(not readiness.acknowledge_query(first), "query cannot precede mesh", failures)
	_expect(readiness.mark_meshed(first), "current ticket accepts mesh", failures)
	_expect(readiness.acknowledge_query(first), "current meshed ticket accepts query", failures)
	_expect(readiness.is_ready(first), "mesh plus query publishes readiness", failures)
	_expect(readiness.is_point_ready(Vector3(0.5, 0.5, 0.5)), "ready ticket supports contained point", failures)
	_expect(int(readiness.get_status_snapshot().get("canonical_block_count", -1)) == 1, "one canonical block backs the initial ticket", failures)
	var second := readiness.issue(AABB(Vector3.ONE, Vector3.ONE * 4.0), &"edit")
	_expect(not readiness.mark_meshed(first), "superseded revision rejects mesh", failures)
	_expect(readiness.is_ready(first), "completed ticket remains a diagnostic receipt after supersession", failures)
	_expect(readiness.is_point_ready(Vector3(2.0, 2.0, 2.0)), "edited point keeps the last acknowledged collider until replacement", failures)
	_expect(readiness.is_point_ready(Vector3(10.0, 10.0, 10.0)), "same-block point retains last acknowledged collider", failures)
	_expect(int(readiness.get_status_snapshot().get("fallback_ready_block_count", 0)) == 1, "pending replacement exposes stale-collider fallback", failures)
	var disjoint := readiness.issue(AABB(Vector3(32.0, 0.0, 0.0), Vector3.ONE * 4.0), &"disjoint_edit")
	_expect(readiness.mark_meshed(second), "older disjoint ticket remains independently current", failures)
	_expect(readiness.acknowledge_query(second), "older disjoint ticket can finish after a newer issue", failures)
	_expect(readiness.is_point_ready(Vector3(10.0, 10.0, 10.0)), "whole canonical block publishes replacement together", failures)
	_expect(readiness.mark_meshed(disjoint), "new disjoint ticket accepts mesh", failures)
	var snapshot := readiness.get_status_snapshot()
	_expect(int(snapshot.get("canonical_block_count", -1)) == 2, "disjoint edits produce two bounded canonical states", failures)
	_expect(int((snapshot.get("mesh_latency_usec", {}) as Dictionary).get("sample_count", 0)) == 3, "mesh lag samples are retained", failures)
	var spanning := readiness.issue(AABB(Vector3(64.0, 0.0, 0.0), Vector3(32.0, 4.0, 4.0)), &"spanning")
	var partial_overlap := readiness.issue(AABB(Vector3(64.0, 0.0, 0.0), Vector3(4.0, 4.0, 4.0)), &"partial_overlap")
	_expect(readiness.mark_meshed(spanning) and readiness.acknowledge_query(spanning), "partially superseded ticket can finish its remaining blocks", failures)
	_expect(readiness.is_point_ready(Vector3(80.5, 1.0, 1.0)), "uncovered block never becomes permanently pending", failures)
	_expect(not readiness.is_point_ready(Vector3(64.5, 1.0, 1.0)), "overwritten block remains owned by the newer ticket", failures)
	_expect(readiness.mark_meshed(partial_overlap), "newer partial-overlap ticket remains current", failures)
	_expect(readiness.retire(partial_overlap, &"test_timeout"), "pending replacement can be explicitly retired", failures)
	_expect(not readiness.is_point_ready(Vector3(64.5, 1.0, 1.0)), "retired block without fallback is no longer pending or ready", failures)
	var fallback_replacement := readiness.issue(AABB(Vector3.ONE, Vector3.ONE * 4.0), &"fallback_replacement")
	_expect(readiness.retire(fallback_replacement, &"test_timeout"), "replacement with fallback can be retired", failures)
	_expect(readiness.is_point_ready(Vector3(2.0, 2.0, 2.0)), "retirement restores the last acknowledged collider", failures)
	readiness.reset()
	_expect(not readiness.mark_meshed(second), "pre-reset generation rejects mesh", failures)
	_expect(not readiness.is_ready(second), "pre-reset ticket never revives", failures)
	_expect(int(readiness.get_status_snapshot().get("canonical_block_count", -1)) == 0, "reset clears canonical readiness state", failures)


func _check_timing_window(failures: Array[String]) -> void:
	var window := VoxelTimingWindow.new(4)
	for sample in [10, 20, 30, 40, 50]:
		window.record(sample)
	var snapshot := window.snapshot()
	_expect(int(snapshot.get("sample_count", -1)) == 4, "timing window stays bounded", failures)
	_expect(int(snapshot.get("recorded_count", -1)) == 5, "timing window retains lifetime count", failures)
	_expect(is_equal_approx(float(snapshot.get("average", -1.0)), 35.0), "timing average only covers retained samples", failures)
	_expect(int(snapshot.get("maximum", -1)) == 50, "timing maximum only covers retained samples", failures)
	_expect(int(snapshot.get("p95", -1)) == 50, "timing window reports nearest-rank p95", failures)
	_expect(int(snapshot.get("p99", -1)) == 50, "timing window reports nearest-rank p99", failures)


func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append("voxel foundation: %s" % message)
