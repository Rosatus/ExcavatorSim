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
