extends SceneTree


func _init() -> void:
	var modes := SoilAuthorityModeController.new()
	for retired in ["legacy", "shadow", "active_patch"]:
		if modes.set_requested_mode(retired):
			return _fail("retired soil mode was accepted")
	for retired in ["point_brush_v1", "surface_patch_v2", "arcade_stamp_v3"]:
		if modes.set_requested_solver_mode(retired):
			return _fail("retired solver was accepted")
	if not modes.begin_generation("stable:1") or not modes.can_product_owner_write("voxel"):
		return _fail("stable voxel owner did not initialize")
	if modes.can_product_owner_write("legacy") or modes.can_product_owner_write("active_patch"):
		return _fail("retired writer was enabled")
	if modes.bind_product_writers(true, false, true):
		return _fail("multiple material writers were accepted")
	if not modes.bind_product_writers(false, false, true):
		return _fail("voxel ownership did not recover")
	if not modes.report_runtime_failure("injected") or modes.can_product_owner_write("voxel"):
		return _fail("runtime failure did not pause soil writes")
	if modes.requested_mode != "voxel" or modes.requested_solver_mode != "voxel_bucket_v1":
		return _fail("failure re-enabled retired soil")
	if not modes.begin_generation("stable:2") or not modes.can_product_owner_write("voxel"):
		return _fail("clean generation did not recover voxel writer")
	if modes.fallback_initialization_to_legacy("injected") or modes.selected_mode != "voxel" or not modes.writes_paused:
		return _fail("old fallback seam must pause, never select legacy")
	print("soil_authority_migration_test: PASS")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
