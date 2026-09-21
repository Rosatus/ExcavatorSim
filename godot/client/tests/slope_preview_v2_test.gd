extends SceneTree

const SlopeCutPreview := preload("res://scripts/slope_cut_preview.gd")
const SlopeProfile := preload("res://scripts/slope_profile.gd")
const SlopeSideView := preload("res://scripts/slope_side_view.gd")


## Preview-v2 pure contracts: the shader uniform pack mirrors the analytic
## profile exactly the way voxel_soil_bounded consumes it, and the side-view
## projection lands world points in the (s, h) plane. No scene needed —
## everything under test is a static pure function.


func _initialize() -> void:
	var failures := 0
	# Held input crosses zero in both directions without clamping the toe.
	var controller := TrackedChassisController.new()
	controller._slope_distance_m = 0.6
	for direction in [-1.0, 1.0]:
		for tick in range(12):
			var previous: float = controller._slope_distance_m
			controller._adjust_slope_params(Vector4(0, 0, direction, 0), 0.1)
			var distance: float = controller._slope_distance_m
			if not _expect(is_equal_approx(distance, previous + direction * 0.15), "held distance input moves continuously through zero"):
				failures += 1
			for angle in [-30.0, 30.0]:
				var signed_profile := SlopeProfile.create(Vector3(2, 0, 1), Vector3.RIGHT, distance, angle, 0.5)
				if not _expect(is_equal_approx(signed_profile.toe_world().x, 2.0 + distance), "signed toe matches terrain sampling location"):
					failures += 1
				if not _expect(is_equal_approx(signed_profile.height_at(distance - 1), 0.5) and is_equal_approx(signed_profile.height_at(distance + 1), 0.5 + tan(deg_to_rad(angle))), "bench and slope follow signed toe"):
					failures += 1
				var signed_pack := SlopeCutPreview.preview_uniforms(signed_profile, -3, 3, 0.56, 1)
				if not _expect(is_equal_approx((signed_pack.cut_band as Vector4).w, distance), "preview preserves signed toe"):
					failures += 1
	controller.free()
	var profile := SlopeProfile.create(
		Vector3(2.0, 0.5, -1.0),   # tooth anchor
		Vector3(0.6, 0.0, 0.8),    # cabin axis (normalized inside create)
		3.0,                       # toe distance
		30.0,                      # angle
		-0.2                       # toe height
	)

	# Uniform pack mirrors the profile and packs the band the shader expects.
	var pack := SlopeCutPreview.preview_uniforms(profile, 0.5, 4.5, 0.56, 1, 2.2)
	if not _expect(int(pack.get("cut_mode", 0)) == 1, "mode passes through"):
		failures += 1
	var band := pack.get("cut_band", Vector4.ZERO) as Vector4
	if not _expect(absf(band.x - 0.5) < 0.001 and absf(band.y - 4.5) < 0.001, "band carries s range"):
		failures += 1
	if not _expect(absf(band.z - 0.56) < 0.001, "band carries half width"):
		failures += 1
	if not _expect(absf(band.w - profile.toe_s) < 0.001, "band carries toe s"):
		failures += 1
	if not _expect(pack.get("cut_origin_xz") == profile.origin_xz, "origin passes through"):
		failures += 1
	if not _expect(pack.get("cut_axis") == profile.axis, "axis passes through"):
		failures += 1
	if not _expect(float(pack.get("cut_toe_height", 0.0)) == profile.toe_height, "toe height passes through"):
		failures += 1
	if not _expect(absf(float(pack.get("cut_tan_theta", 0.0)) - profile.grade) < 0.0001, "grade passes through"):
		failures += 1
	if not _expect(float(pack.get("cut_pulse_hz", 0.0)) == 2.2, "pulse hz passes through"):
		failures += 1

	# Mode 0 or a null profile must switch the mark off entirely.
	if not _expect(int(SlopeCutPreview.preview_uniforms(profile, 0.5, 4.5, 0.56, 0).get("cut_mode", 1)) == 0, "mode 0 clears"):
		failures += 1
	if not _expect(int(SlopeCutPreview.preview_uniforms(null, 0.5, 4.5, 0.56, 1).get("cut_mode", 1)) == 0, "null profile clears"):
		failures += 1
	# Zero/negative pulse leaves the shader default (key absent).
	if not _expect(not SlopeCutPreview.preview_uniforms(profile, 0.5, 4.5, 0.56, 1, 0.0).has("cut_pulse_hz"), "no pulse key when unset"):
		failures += 1

	# Side-view projection: s is the along-axis offset, h the world height.
	var projected := SlopeSideView.project_to_plane(profile.origin_xz, profile.axis, Vector3(3.0, 1.25, -0.5))
	var expected_s: float = profile.axis.dot(Vector2(3.0, -0.5) - profile.origin_xz)
	if not _expect(absf(projected.x - expected_s) < 0.0001, "projection s along axis"):
		failures += 1
	if not _expect(projected.y == 1.25, "projection h is world height"):
		failures += 1
	# The anchor projects to s=0 by construction.
	var anchor := SlopeSideView.project_to_plane(profile.origin_xz, profile.axis, Vector3(2.0, 0.5, -1.0))
	if not _expect(absf(anchor.x) < 0.0001, "anchor lands at s=0"):
		failures += 1

	# Level snapshots move their origin with the tooth. A parked machine must
	# keep the same viewport position/scale while the arm and terrain change.
	var hud := SlopeSideView.new()
	var view := {"mode": "level", "origin_xz": Vector2(4, 0), "axis": Vector2.RIGHT,
		"joints": {"swing_joint": Vector3(1, 2, 0)}, "tooth": Vector3(4, 0, 0)}
	hud.set_view(view)
	var before := hud.view_bounds()
	var parked := SlopeSideView.project_to_plane(view.origin_xz, view.axis, view.joints.swing_joint) - before.position
	view.origin_xz = Vector2(9, 0)
	view.tooth = Vector3(9, 5, 0)
	view.terrain = PackedVector2Array([Vector2(-20, -10), Vector2(20, 10)])
	hud.set_view(view)
	var after := hud.view_bounds()
	var still_parked := SlopeSideView.project_to_plane(view.origin_xz, view.axis, view.joints.swing_joint) - after.position
	if not _expect(parked.is_equal_approx(still_parked) and before.size == after.size, "parked machine does not drift or zoom with tooth/terrain"):
		failures += 1
	view.joints = {"swing_joint": Vector3(3, 2, 0)}
	hud.set_view(view)
	var moved := SlopeSideView.project_to_plane(view.origin_xz, view.axis, view.joints.swing_joint) - hud.view_bounds().position
	if not _expect(moved.is_equal_approx(parked + Vector2(2, 0)), "actual vehicle travel remains visible"):
		failures += 1
	hud.set_view({})
	hud.set_view(view)
	if not _expect(hud.view_bounds().position != after.position, "new operation relatches viewport"):
		failures += 1
	hud.free()
	# Both assist modes use the same terrain-supported symbol, independent
	# of the host's slew-pivot height or the design surface being excavated.
	for ground_height in [-0.5, 0.0, 2.0]:
		var terrain := PackedVector2Array([Vector2(-8, ground_height), Vector2(8, ground_height)])
		for pivot_height in [0.3, 1.5, 3.0]:
			var symbol := SlopeSideView.machine_symbol_pivot(Vector2(1, pivot_height), terrain)
			if not _expect(is_equal_approx(symbol.y - SlopeSideView.TRACK_BOTTOM_OFFSET_M, ground_height) and symbol.x == 1.0, "track bottom rests on ground regardless of slew height"):
				failures += 1
	var inclined := SlopeSideView.machine_symbol_pivot(Vector2(1, 4), PackedVector2Array([Vector2(0, 0), Vector2(2, 1)]))
	if not _expect(is_equal_approx(inclined.y - SlopeSideView.TRACK_BOTTOM_OFFSET_M, 0.5), "support height interpolates below track center"):
		failures += 1
	if not _expect(SlopeSideView.machine_symbol_pivot(Vector2(1, 4), PackedVector2Array()) == Vector2(1, 4), "missing ground preserves safe fallback"):
		failures += 1

	for machine in [Vector2(-60, 15), Vector2(60, 15)]:
		var pin := Vector2(4, 0)
		var tip := Vector2(0, 30)
		var outline := SlopeSideView.bucket_outline(pin, tip, machine)
		var bulge := outline[8] - pin.lerp(tip, 0.5)
		if not _expect(outline.size() == 17 and outline[0] == pin and outline[-1] == tip and bulge.dot(pin.lerp(tip, 0.5) - machine) > 0.0, "curved bucket faces away from machine and preserves tooth"):
			failures += 1
	if not _expect(SlopeSideView.bucket_outline(Vector2.ZERO, Vector2.ZERO, Vector2.LEFT).is_empty(), "collapsed bucket does not emit invalid polygon"):
		failures += 1

	if failures == 0:
		print("slope_preview_v2_test: PASS")
		quit(0)
	else:
		push_error("slope_preview_v2_test: %d failure(s)" % failures)
		quit(1)


func _expect(condition: bool, label: String) -> bool:
	if not condition:
		push_error("slope_preview_v2_test FAIL: %s" % label)
	return condition
