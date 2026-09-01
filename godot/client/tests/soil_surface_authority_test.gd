extends SceneTree


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var descriptor := SoilContractDescriptor.load_for_model("sy205")
	if descriptor == null or not descriptor.is_valid_for("sy205"):
		return _fail("SY205 soil contract unavailable")
	var contract := descriptor.to_dictionary()
	var terrain := TerrainState.new(1937, 41, 41, 0.25)
	var scheduler := TerrainCommitScheduler.new(terrain)
	var active := ActiveSoilPatch.new()
	if not active.configure_product(terrain, scheduler, "low", "loose"):
		return _fail("product active patch did not configure")
	var authority := SoilInteractionAuthority.new()
	if not authority.configure(contract, terrain.world_generation, "loose", "active_patch"):
		return _fail("soil authority did not configure")
	var tool := BucketSoilTool.new()
	if not tool.configure(contract):
		return _fail("bucket tool did not configure")
	var tool_snapshot := tool.compose_snapshot(
		Transform3D(Basis.IDENTITY, Vector3(0.0, 1.25, -0.25)),
		Transform3D(Basis.IDENTITY, Vector3(0.0, 0.70, 0.25)),
		true,
		"sy205|surface-authority",
	)
	var classification := tool.classify(tool_snapshot, terrain, 0.0, contract["interaction"] as Dictionary)
	var sweep := BucketSurfaceSweep.new().build_patch(tool_snapshot, classification, terrain.surface_snapshot(), contract["interaction"] as Dictionary, 11)
	if not bool(sweep.get("valid", false)):
		return _fail("surface sweep unavailable: %s" % sweep.get("reason", "missing"))
	var before := terrain.surface_snapshot()
	var shadow_terrain := TerrainState.from_surface_snapshot(before)
	var shadow_scheduler := TerrainCommitScheduler.new(shadow_terrain)
	var shadow_active := ActiveSoilPatch.new()
	shadow_active.configure_product(shadow_terrain, shadow_scheduler, "low", "loose")
	var shadow_authority := SoilInteractionAuthority.new()
	shadow_authority.configure(contract, shadow_terrain.world_generation, "loose", "active_patch")
	var shadow := shadow_authority.step_fixed(
		1.0 / 60.0,
		1,
		tool_snapshot,
		classification,
		shadow_active,
		Vector3.ZERO,
		sweep,
		shadow_scheduler,
		"surface_patch_v2_shadow",
	)
	var baseline_terrain := TerrainState.from_surface_snapshot(before)
	var baseline_scheduler := TerrainCommitScheduler.new(baseline_terrain)
	var baseline_active := ActiveSoilPatch.new()
	baseline_active.configure_product(baseline_terrain, baseline_scheduler, "low", "loose")
	var baseline_authority := SoilInteractionAuthority.new()
	baseline_authority.configure(contract, baseline_terrain.world_generation, "loose", "active_patch")
	var baseline := baseline_authority.step_fixed(
		1.0 / 60.0,
		1,
		tool_snapshot,
		classification,
		baseline_active,
		Vector3.ZERO,
		{},
		baseline_scheduler,
		"point_brush_v1",
	)
	if not bool(shadow.get("changed", false)) or not bool(baseline.get("changed", false)):
		return _fail("v1 product owner did not continue in v2 shadow mode")
	if shadow_terrain.surface_snapshot()["snapshot_sha256"] != baseline_terrain.surface_snapshot()["snapshot_sha256"]:
		return _fail("v2 shadow changed the v1 product terrain outcome")
	if String(shadow_authority.get_status_snapshot()["ledger_identity"]) != String(baseline_authority.get_status_snapshot()["ledger_identity"]):
		return _fail("v2 shadow changed the v1 product ledger outcome")
	if String((shadow_authority.get_status_snapshot()["last_surface_patch"] as Dictionary).get("patch_hash", "")) != String(sweep["patch_hash"]):
		return _fail("v2 shadow did not publish canonical diagnostics")

	var committed := authority.step_fixed(
		1.0 / 60.0,
		2,
		tool_snapshot,
		classification,
		active,
		Vector3.ZERO,
		sweep,
		scheduler,
		"surface_patch_v2",
	)
	var surface_commit := committed.get("surface_patch_commit", {}) as Dictionary
	if not bool(surface_commit.get("changed", false)) or surface_commit.get("reason") != "surface_patch_committed":
		return _fail("v2 authority did not commit: %s" % surface_commit.get("reason", "missing"))
	var after := terrain.surface_snapshot()
	if int(after["terrain_revision"]) != int(before["terrain_revision"]) + 1 or after["snapshot_sha256"] == before["snapshot_sha256"]:
		return _fail("v2 authority did not install one terrain revision")
	var authority_status := authority.get_status_snapshot()
	if int(authority_status.get("surface_patch_commits", 0)) != 1 or int(authority_status.get("invariant_failure_count", 0)) != 0:
		return _fail("v2 authority diagnostics are inconsistent")
	var requested := float(sweep.get("removed_stable_m3", 0.0)) + float(sweep.get("removed_loose_m3", 0.0))
	var surface_accepted := 0.0
	for row_value in authority.get_journal_snapshot():
		var row := row_value as Dictionary
		if String(row.get("kind", "")) == "surface_cut":
			surface_accepted += float(row.get("accepted_volume_m3", 0.0))
	if not is_equal_approx(surface_accepted, requested):
		return _fail("ledger surface debit does not match exact patch volume")
	var active_status := active.get_status_snapshot()
	if not is_equal_approx(float(active_status.get("injected_volume_m3", 0.0)), requested):
		return _fail("logical active aggregate does not match exact patch debit")
	if int(active_status.get("predebited_reservation_count", -1)) != 0:
		return _fail("committed reservation was retained")

	var loose_seed := active.persistent_field.settle_volume(Vector2.ZERO, 0.01, 0.36, "push-seed")
	if not bool(loose_seed.get("accepted", false)):
		return _fail("push integration loose seed rejected")
	var push_snapshot := tool.compose_snapshot(
		Transform3D(Basis.IDENTITY, Vector3(0.0, 0.34, 0.20)),
		Transform3D(Basis.IDENTITY, Vector3(0.0, 0.34, -0.20)),
		true,
		"sy205|loose-push",
	)
	var push_classification := tool.classify(push_snapshot, terrain, 0.0, contract["interaction"] as Dictionary)
	var has_push := false
	for candidate_value in push_classification.get("candidates", []):
		var candidate := candidate_value as Dictionary
		if String(candidate.get("classification", "")) == "push":
			has_push = true
			break
	if not has_push:
		return _fail("semantic outer surface did not classify a push")
	var flux_before := int((active.persistent_field.get_status_snapshot()).get("flux_commit_count", 0))
	authority.step_fixed(
		1.0 / 60.0,
		3,
		push_snapshot,
		push_classification,
		active,
		Vector3.ZERO,
		{},
		scheduler,
		"surface_patch_v2",
	)
	var flux_after := int((active.persistent_field.get_status_snapshot()).get("flux_commit_count", 0))
	if flux_after <= flux_before:
		return _fail("classified push did not reach the bounded loose frontier")

	print("soil_surface_authority_test: PASS")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
