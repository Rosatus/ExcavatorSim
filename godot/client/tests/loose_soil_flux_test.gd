extends SceneTree


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var state := TerrainState.new(1937, 9, 9, 0.25)
	var snapshot := state.surface_snapshot()
	var loose: PackedFloat32Array = snapshot["loose_depth"]
	var center := 4 * 9 + 4
	loose[center] = 0.55
	snapshot["loose_depth"] = loose
	var surface := snapshot["stable_heights"] as PackedFloat32Array
	for index in surface.size():
		surface[index] += loose[index]
	snapshot["surface"] = surface
	var compaction := PackedFloat32Array()
	compaction.resize(81)
	compaction.fill(0.1)
	var frontier: Array[int] = []
	for index in 81:
		frontier.append(index)
	var solver := LooseSoilFluxSolver.new()
	var result := solver.build_patch(snapshot, compaction, "loose", frontier, 1, 3)
	if not bool(result.get("valid", false)):
		return _fail("steep loose pile did not relax: %s" % result.get("reason", "missing"))
	if float(result.get("moved_volume_m3", 0.0)) <= 0.0:
		return _fail("loose solver reported no conservative flux")
	var reversed := frontier.duplicate()
	reversed.reverse()
	var reordered := solver.build_patch(snapshot, compaction, "loose", reversed, 1, 3)
	if not bool(reordered.get("valid", false)) or String((reordered["patch"] as Dictionary)["patch_hash"]) != String((result["patch"] as Dictionary)["patch_hash"]):
		return _fail("frontier order changed deterministic flux")

	var clone := TerrainState.from_surface_snapshot(snapshot)
	var before_volume := _loose_volume(clone)
	if not clone.enqueue_cell_patch(clone.next_brush_sequence(), result["patch"] as Dictionary) or not clone.step_fixed():
		return _fail("loose flux patch did not commit")
	var after_volume := _loose_volume(clone)
	if absf(after_volume - before_volume) > 0.000001:
		return _fail("loose flux did not conserve volume")
	if clone.loose_depth[center] >= loose[center]:
		return _fail("steep donor did not shed loose material")

	var compacted := PackedFloat32Array()
	compacted.resize(81)
	compacted.fill(1.0)
	var compact_result := solver.build_patch(snapshot, compacted, "loose", frontier, 2, 3)
	if not bool(compact_result.get("valid", false)) or float(compact_result.get("moved_volume_m3", INF)) >= float(result.get("moved_volume_m3", 0.0)):
		return _fail("compaction did not reduce loose mobility")

	var shallow_snapshot := state.surface_snapshot()
	var shallow_loose: PackedFloat32Array = shallow_snapshot["loose_depth"]
	shallow_loose[center] = 0.10
	shallow_snapshot["loose_depth"] = shallow_loose
	var shallow_surface := shallow_snapshot["stable_heights"] as PackedFloat32Array
	for index in shallow_surface.size():
		shallow_surface[index] += shallow_loose[index]
	shallow_snapshot["surface"] = shallow_surface
	var shallow := solver.build_patch(shallow_snapshot, compaction, "loose", frontier, 3, 3)
	if bool(shallow.get("valid", false)) or shallow.get("reason") != "below_repose":
		return _fail("below-repose pile did not remain still")
	var pushed := solver.build_patch(shallow_snapshot, compaction, "loose", frontier, 4, 3, Vector2.RIGHT)
	if not bool(pushed.get("valid", false)):
		return _fail("tool impulse did not push below-repose loose soil")
	var pushed_state := TerrainState.from_surface_snapshot(shallow_snapshot)
	var pushed_before := _loose_volume(pushed_state)
	if not pushed_state.enqueue_cell_patch(pushed_state.next_brush_sequence(), pushed["patch"] as Dictionary) or not pushed_state.step_fixed():
		return _fail("tool-biased loose patch did not commit")
	if absf(_loose_volume(pushed_state) - pushed_before) > 0.000001:
		return _fail("tool-biased flux changed total loose volume")
	if pushed_state.loose_depth[center + 1] <= shallow_loose[center + 1]:
		return _fail("rightward tool impulse did not move material right")

	var settlement_state := TerrainState.new(4417, 17, 17, 0.25)
	var settlement_scheduler := TerrainCommitScheduler.new(settlement_state)
	settlement_scheduler.commit_interval_s = 0.0
	settlement_scheduler.maximum_latency_s = 0.0
	settlement_scheduler.volume_threshold_m3 = 0.0
	var field := ActiveSoilPersistentField.new()
	if not field.configure_product(settlement_state, settlement_scheduler, "damp"):
		return _fail("product persistent field did not configure")
	var requested_settlement := 0.012345
	var before_settlement := _loose_volume(settlement_state)
	var settlement := field.settle_volume(Vector2.ZERO, requested_settlement, 0.42, "exact-volume")
	if not bool(settlement.get("accepted", false)):
		return _fail("typed settlement rejected: %s" % settlement.get("reason", "missing"))
	var committed_settlement := float(settlement.get("committed_volume_m3", 0.0))
	var measured_settlement := _loose_volume(settlement_state) - before_settlement
	if absf(committed_settlement - requested_settlement) > 0.000001:
		return _fail("typed settlement did not allocate the requested volume")
	if absf(measured_settlement - committed_settlement) > 0.000001:
		return _fail("typed settlement metadata differed from installed loose volume")

	print("loose_soil_flux_test: PASS")
	quit(0)


func _loose_volume(state: TerrainState) -> float:
	var total := 0.0
	for depth in state.loose_depth:
		total += float(depth) * state.spacing_m * state.spacing_m
	return total


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
