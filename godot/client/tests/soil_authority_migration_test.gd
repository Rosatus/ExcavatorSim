extends SceneTree


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var modes := SoilAuthorityModeController.new()
	if not modes.set_requested_mode("shadow") or not modes.begin_generation("generation:1"):
		return _fail("shadow generation did not configure")
	if not modes.set_requested_solver_mode("surface_patch_v2_shadow"):
		return _fail("surface solver request was rejected")
	if modes.selected_solver_mode != "point_brush_v1":
		return _fail("surface solver changed inside a locked generation")
	if modes.selected_mode != "shadow" or modes.product_owner() != "legacy":
		return _fail("shadow generation selected the wrong product owner")
	if not modes.set_requested_mode("active_patch") or modes.selected_mode != "shadow":
		return _fail("requested cutover changed the live generation")
	if not modes.begin_generation("generation:2") or modes.selected_mode != "active_patch":
		return _fail("active patch was not selected at the clean boundary")
	if modes.selected_solver_mode != "surface_patch_v2_shadow":
		return _fail("surface solver was not selected at the clean boundary")
	if not modes.can_product_owner_write("active_patch") or modes.can_product_owner_write("legacy"):
		return _fail("active generation did not enforce a single writer")
	if modes.bind_product_writers(true, true) or modes.owner_violation_count != 1:
		return _fail("double-writer assertion did not reject mixed ownership")
	if not modes.bind_product_writers(false, true):
		return _fail("active writer configuration did not recover after assertion")
	if not modes.report_runtime_failure("injected_failure"):
		return _fail("active runtime failure was not recorded")
	if not modes.writes_paused or modes.selected_mode != "active_patch" or modes.requested_mode != "legacy":
		return _fail("runtime failure mixed owners instead of scheduling fallback")
	if modes.requested_solver_mode != "point_brush_v1":
		return _fail("runtime failure did not schedule the compatible solver")
	if not modes.begin_generation("generation:3") or modes.selected_mode != "legacy":
		return _fail("clean fallback generation did not select legacy")
	if not modes.set_requested_mode("active_patch") or not modes.set_requested_solver_mode("arcade_stamp_v3"):
		return _fail("arcade stamp generation request was rejected")
	if not modes.begin_generation("generation:4") or modes.selected_solver_mode != "arcade_stamp_v3":
		return _fail("arcade stamp was not selected at a clean generation boundary")
	if not modes.can_product_owner_write("active_patch") or modes.can_product_owner_write("legacy"):
		return _fail("arcade stamp did not retain exclusive product-writer ownership")

	var terrain := TerrainState.new(240824, 25, 25, 0.25)
	var scheduler := TerrainCommitScheduler.new(terrain)
	var patch := ActiveSoilPatch.new()
	if not patch.configure_product(terrain, scheduler, "low", "loose"):
		return _fail("product-backed active patch did not configure")
	var before := terrain.surface_snapshot()
	var injection := patch.inject_tool_volume({
		"center": Vector2.ZERO,
		"tooth_world": Vector3(0.0, 0.0, 0.0),
		"tooth_velocity": Vector3(0.2, 0.0, 0.0),
		"volume_m3": 0.012,
	}, "product-cut")
	if not bool(injection.get("accepted", false)):
		return _fail("product-backed activation was rejected: %s" % injection.get("reason", "unknown"))
	var after_cut := terrain.surface_snapshot()
	if int(after_cut["terrain_revision"]) <= int(before["terrain_revision"]) or after_cut["snapshot_sha256"] == before["snapshot_sha256"]:
		return _fail("active patch did not mutate selected product terrain")
	var field_status := patch.persistent_field.get_status_snapshot()
	if String(field_status.get("write_scope", "")) != "product":
		return _fail("active patch did not expose product write scope")
	var revision_before_clear := terrain.terrain_revision
	patch.clear(false)
	if terrain.terrain_revision != revision_before_clear:
		return _fail("detaching active patch unexpectedly settled material")

	var descriptor := SoilContractDescriptor.load_for_model("sy205")
	if descriptor == null or not descriptor.is_valid_for("sy205"):
		return _fail("SY205 soil contract unavailable")
	var authority := SoilInteractionAuthority.new()
	if not authority.configure(descriptor.to_dictionary(), terrain.world_generation, "loose", "active_patch"):
		return _fail("active product lifecycle did not configure")
	var authority_status := authority.get_status_snapshot()
	if String(authority_status.get("mode", "")) != "active_patch" or String(authority_status.get("ledger_identity", "")).is_empty():
		return _fail("active lifecycle identity was not published")
	if (authority_status.get("fill_profile", PackedFloat32Array()) as PackedFloat32Array).size() != 8 * 6:
		return _fail("SY205 fill profile did not match its x/z grid")
	authority.clear()
	var cleared_status := authority.get_status_snapshot()
	if not (cleared_status.get("fill_profile", PackedFloat32Array()) as PackedFloat32Array).is_empty():
		return _fail("cleared authority exposed a stale fill profile")
	var sy135_descriptor := SoilContractDescriptor.load_for_model("sy135")
	if sy135_descriptor == null or not sy135_descriptor.is_valid_for("sy135"):
		return _fail("SY135 soil contract unavailable")
	if not authority.configure(sy135_descriptor.to_dictionary(), terrain.world_generation, "loose", "active_patch"):
		return _fail("SY135 active product lifecycle did not configure")
	var sy135_status := authority.get_status_snapshot()
	if (sy135_status.get("fill_profile", PackedFloat32Array()) as PackedFloat32Array).size() != 7 * 5:
		return _fail("SY135 fill profile did not match its x/z grid")

	print("soil_authority_migration_test: PASS")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
