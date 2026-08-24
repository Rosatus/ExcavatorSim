extends SceneTree

const QUALITY_MEMORY_LIMITS := {
	"low": 96 * 1024 * 1024,
	"balanced": 256 * 1024 * 1024,
	"high": 512 * 1024 * 1024,
}
const QUALITY_TICK_LIMITS_MS := {"low": 2.0, "balanced": 4.0, "high": 6.0}


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var source := TerrainState.new(8042, 41, 41, 0.25)
	var source_before := source.surface_snapshot()
	var observed_angles := {}
	for preset in ["loose", "compact", "sand", "damp"]:
		var patch := ActiveSoilPatch.new()
		if not patch.configure(source_before, "balanced", preset):
			return _fail("%s material preset did not configure" % preset)
		var injection := patch.inject_cut_event({
			"center": Vector2.ZERO,
			"tooth_world": Vector3(0.0, 0.04, 0.0),
			"tooth_velocity": Vector3(0.25, 0.1, 0.0),
			"volume_m3": 0.024,
		}, "preset:%s" % preset)
		if not bool(injection.get("accepted", false)):
			return _fail("%s injection rejected: %s" % [preset, injection.get("reason", "unknown")])
		for tick in 30:
			patch.step_fixed(1.0 / 60.0, Vector3.ZERO)
		var active_status := patch.get_status_snapshot()
		if int(active_status["representative_count"]) <= 0 or int(active_status["representative_count"]) > int(active_status["max_representatives"]):
			return _fail("%s representative budget was not respected" % preset)
		if int(active_status["estimated_memory_bytes"]) >= QUALITY_MEMORY_LIMITS["balanced"]:
			return _fail("%s exceeded the balanced memory budget" % preset)
		observed_angles[preset] = float(active_status["angle_of_repose_degrees"])
		patch.flush_all()
		var settled := patch.get_status_snapshot()
		if int(settled["representative_count"]) != 0:
			return _fail("%s did not settle all active representatives" % preset)
		if absf(float(settled["conservation_error_m3"])) > 0.00001:
			return _fail("%s violated volume conservation: %.8f" % [preset, float(settled["conservation_error_m3"])])
	var unique_angles := {}
	for angle in observed_angles.values():
		unique_angles[angle] = true
	if unique_angles.size() != 4:
		return _fail("material response presets were not distinguishable")

	var descriptor := SoilContractDescriptor.load_for_model("sy205")
	if descriptor == null or not descriptor.is_valid_for("sy205"):
		return _fail("SY205 tool contract unavailable for containment scenario")
	var tool := BucketSoilTool.new()
	if not tool.configure(descriptor.to_dictionary()):
		return _fail("SY205 tool contract did not configure")
	var bucket_frame := Transform3D(Basis.IDENTITY, Vector3(0.0, 0.8, 0.0))
	var tool_snapshot := tool.compose_snapshot(bucket_frame, bucket_frame, true, "containment")
	var inner_center := Vector3.ZERO
	for region_value in tool_snapshot.get("regions", []):
		var region := region_value as Dictionary
		if String(region.get("region_id", "")) == "inner_shell":
			inner_center = (region["current_transform"] as Transform3D).origin
	var containment_patch := ActiveSoilPatch.new()
	containment_patch.configure(source_before, "balanced", "damp")
	var contained_injection := containment_patch.inject_cut_event({
		"center": Vector2(inner_center.x, inner_center.z),
		"tooth_world": inner_center,
		"tooth_velocity": Vector3.ZERO,
		"volume_m3": 0.012,
	}, "containment")
	if not bool(contained_injection.get("accepted", false)):
		return _fail("containment injection was rejected")
	containment_patch.step_fixed(1.0 / 60.0, inner_center, tool_snapshot)
	if int(containment_patch.get_status_snapshot()["contained_count"]) <= 0:
		return _fail("inner shell did not contain active soil")
	containment_patch.flush_all()

	for quality in ["low", "balanced", "high"]:
		var patch := ActiveSoilPatch.new()
		if not patch.configure(source_before, quality, "loose"):
			return _fail("%s quality profile did not configure" % quality)
		for event_index in 24:
			patch.inject_cut_event({
				"center": Vector2(float(event_index % 6) * 0.08 - 0.2, float(event_index / 6) * 0.08 - 0.12),
				"tooth_world": Vector3.ZERO,
				"tooth_velocity": Vector3(0.4, 0.0, 0.15),
				"volume_m3": 0.012,
			}, "%s:%d" % [quality, event_index])
		for tick in 20:
			patch.step_fixed(1.0 / 60.0, Vector3.ZERO)
		var status := patch.get_status_snapshot()
		if int(status["representative_count"]) > int(status["max_representatives"]):
			return _fail("%s exceeded its fixed representative budget" % quality)
		if int(status["estimated_memory_bytes"]) >= int(QUALITY_MEMORY_LIMITS[quality]):
			return _fail("%s exceeded its memory gate" % quality)
		if float(status["p95_tick_ms"]) > float(QUALITY_TICK_LIMITS_MS[quality]):
			return _fail("%s exceeded its %.1f ms p95 gate: %.3f ms" % [quality, float(QUALITY_TICK_LIMITS_MS[quality]), float(status["p95_tick_ms"])])
		print("active_soil_patch_benchmark: %s p95=%.3fms reps=%d memory=%d" % [quality, float(status["p95_tick_ms"]), int(status["representative_count"]), int(status["estimated_memory_bytes"])])
		patch.flush_all()
		if absf(float(patch.get_status_snapshot()["conservation_error_m3"])) > 0.00005:
			return _fail("%s profile leaked active volume" % quality)

	var source_after := source.surface_snapshot()
	if source_after["snapshot_sha256"] != source_before["snapshot_sha256"] or source_after["terrain_revision"] != source_before["terrain_revision"]:
		return _fail("shadow active patch mutated product TerrainState")
	print("active_soil_patch_test: PASS")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
