extends SceneTree


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	# Keep this transaction test on the product terrain size/spacing; the first
	# manual v2 pass exposed latency that the old 25x25 synthetic grid hid.
	var state := TerrainState.new(1937)
	var collider := TerrainCollider.new()
	collider.enabled = true
	root.add_child(collider)
	if not collider.queue_snapshot(state.surface_snapshot()) or not collider.apply_pending():
		return _fail("initial collider build failed")
	var scheduler := TerrainCommitScheduler.new(state, null, collider)
	var before := state.surface_snapshot()
	var index := 12 * state.columns + 12
	var patch := _patch_for(before, index, -0.05)
	collider.fail_next_prepare_for_test()
	if not scheduler.queue_cell_patch(1, patch, state.world_generation, "prepare-failure"):
		return _fail("valid patch did not queue before injected prepare failure")
	var rejected := scheduler.step_fixed(0.0, true)
	if bool(rejected.get("changed", false)) or rejected.get("reason") != "collider_prepare_rejected":
		return _fail("collider prepare failure was not rejected atomically")
	if state.terrain_revision != int(before["terrain_revision"]) or state.surface_snapshot()["snapshot_sha256"] != before["snapshot_sha256"]:
		return _fail("prepare failure changed TerrainState")
	if collider.get_applied_identity() != Vector2i(state.world_generation, state.terrain_revision):
		return _fail("prepare failure changed collider identity")
	collider.fail_next_install_for_test()
	if not scheduler.queue_cell_patch(2, patch, state.world_generation, "install-failure"):
		return _fail("valid patch did not queue before injected install failure")
	var install_rejected := scheduler.step_fixed(0.0, true)
	if bool(install_rejected.get("changed", false)) or install_rejected.get("reason") != "collider_install_rejected":
		return _fail("collider install failure was not rejected atomically")
	if state.terrain_revision != int(before["terrain_revision"]) or state.surface_snapshot()["snapshot_sha256"] != before["snapshot_sha256"]:
		return _fail("install failure changed TerrainState")
	state.fail_next_cell_patch_apply_for_test()
	if not scheduler.queue_cell_patch(3, patch, state.world_generation, "post-install-terrain-failure"):
		return _fail("valid patch did not queue before injected terrain failure")
	var terrain_rejected := scheduler.step_fixed(0.0, true)
	if bool(terrain_rejected.get("changed", false)) or terrain_rejected.get("reason") != "post_install_terrain_invariant":
		return _fail("post-install terrain failure did not reject")
	if state.terrain_revision != int(before["terrain_revision"]) or state.surface_snapshot()["snapshot_sha256"] != before["snapshot_sha256"]:
		return _fail("post-install terrain failure changed TerrainState")
	if collider.get_applied_identity() != Vector2i(state.world_generation, state.terrain_revision):
		return _fail("post-install terrain failure did not restore collider identity")

	if not scheduler.queue_cell_patch(4, patch, state.world_generation, "prepared-success"):
		return _fail("healthy patch did not requeue")
	var committed := scheduler.step_fixed(0.0, true)
	if not bool(committed.get("changed", false)) or committed.get("reason") != "committed":
		return _fail("prepared patch did not commit")
	if collider.get_applied_identity() != Vector2i(state.world_generation, state.terrain_revision):
		return _fail("collider and TerrainState did not publish one identity")
	if int(state.surface_snapshot()["terrain_revision"]) != int(before["terrain_revision"]) + 1:
		return _fail("prepared patch advanced more than one revision")
	var status := scheduler.get_status_snapshot()
	if int(status.get("collider_prepare_rejections", 0)) != 1 or int(status.get("collider_install_failures", 0)) != 1:
		return _fail("collider transaction diagnostics are inconsistent")
	print("terrain_cell_patch_collider_test: flush_us=%d" % int(status.get("last_cell_patch_flush_us", -1)))

	collider.queue_free()
	await process_frame
	print("terrain_cell_patch_collider_test: PASS")
	quit(0)


func _patch_for(snapshot: Dictionary, index: int, delta: float) -> Dictionary:
	var stable: PackedFloat32Array = snapshot["stable_heights"]
	var loose: PackedFloat32Array = snapshot["loose_depth"]
	var rows := [{
		"index": index,
		"original_stable_height": float(stable[index]),
		"original_loose_depth": float(loose[index]),
		"target_stable_height": float(stable[index]) + delta,
		"target_loose_depth": float(loose[index]),
		"action": "cut",
		"contributing_region_ids": ["teeth_main_edge"],
	}]
	var patch := {
		"schema_version": SoilCellPatch.SCHEMA_VERSION,
		"generation": int(snapshot["world_generation"]),
		"base_revision": int(snapshot["terrain_revision"]),
		"tick": 1,
		"tool_identity": "collider-test",
		"rows": rows,
		"removed_stable_m3": -delta * float(snapshot["spacing_m"]) * float(snapshot["spacing_m"]),
		"removed_loose_m3": 0.0,
		"dirty_rect_cells": SoilCellPatch.dirty_rect(rows, int(snapshot["columns"])),
	}
	patch["patch_hash"] = SoilCellPatch.compute_hash(patch)
	return patch


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
