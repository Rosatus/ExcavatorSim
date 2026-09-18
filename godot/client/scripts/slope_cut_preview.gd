class_name SlopeCutPreview
extends RefCounted

## Computes what a confirmed slope pass would remove without moving the
## machine: the reachable band along the profile axis (joint-limit FK
## sweep), the terrain cells above the target surface inside that band, and
## the estimated removal volume. Terrain access is injected as a Callable —
## the runtime wires the authoritative height query (voxel raycast inside
## the work zone, heightfield bilinear outside), tests feed synthetic
## heightfields. Pure math, no scene-tree dependency.

## Fraction of the joint-limit span explored per work joint when sweeping
## the reachable envelope: N^3 FK evaluations (~14k at 24) is a one-shot
## cost paid per preview refresh.
const DEFAULT_SWEEP_STEPS := 24
## Vertical tolerance for counting a swept tooth position as "able to ride
## the surface": reachable extremes far above/below the profile do not
## extend the operating band.
const SURFACE_RIDE_TOL_M := 0.2


## profile: confirmed-or-previewing SlopeProfile. articulation: live
## KinematicArticulationState (FK provider + current positions).
## edge_local: cutting-edge reference in bucket_link space. joint_limits:
## {name: Vector2}. height_sampler: Callable(world_xz: Vector2) -> float.
## Returns {s_min, s_max, volume_m3, max_depth_m, s_values, t_values,
## terrain, target} — the 2D arrays are row-major over s_values x t_values
## for the visual mesh builder.
static func compute(
	profile: RefCounted,
	articulation: RefCounted,
	chassis_transform: Transform3D,
	edge_local: Vector3,
	joint_limits: Dictionary,
	height_sampler: Callable,
	cell_m: float = 0.25,
	half_width_m: float = 0.6,
	sweep_steps: int = DEFAULT_SWEEP_STEPS
) -> Dictionary:
	var band := reach_band(profile, articulation, chassis_transform, edge_local, joint_limits, sweep_steps)
	var s_min := float(band.x)
	var s_max := float(band.y)
	var result := {
		"s_min": s_min,
		"s_max": s_max,
		"volume_m3": 0.0,
		"max_depth_m": 0.0,
		"s_values": PackedFloat32Array(),
		"t_values": PackedFloat32Array(),
		"terrain": [],
		"target": [],
		"half_width_m": half_width_m,
		"toe_world": profile.toe_world() if profile != null else Vector3.ZERO,
	}
	if profile == null or s_max <= s_min:
		return result
	var axis: Vector2 = profile.axis
	var perp := Vector2(-axis.y, axis.x)
	var s_values := PackedFloat32Array()
	var s := s_min
	while s <= s_max + 0.0001:
		s_values.append(s)
		s += cell_m
	var t_values := PackedFloat32Array()
	var t := -half_width_m
	while t <= half_width_m + 0.0001:
		t_values.append(t)
		t += cell_m
	var terrain_rows: Array = []
	var target_rows: Array = []
	var volume := 0.0
	var max_depth := 0.0
	var cell_area := cell_m * cell_m
	for s_value in s_values:
		var terrain_row := PackedFloat32Array()
		var target_row := PackedFloat32Array()
		for t_value in t_values:
			var world_xz: Vector2 = profile.origin_xz + axis * s_value + perp * t_value
			var terrain_h := float(height_sampler.call(world_xz))
			var target_h: float = profile.height_at(s_value)
			terrain_row.append(terrain_h)
			target_row.append(target_h)
			var depth := terrain_h - target_h
			if is_finite(depth) and depth > 0.0:
				volume += depth * cell_area
				max_depth = maxf(max_depth, depth)
		terrain_rows.append(terrain_row)
		target_rows.append(target_row)
	result["s_values"] = s_values
	result["t_values"] = t_values
	result["terrain"] = terrain_rows
	result["target"] = target_rows
	result["volume_m3"] = volume
	result["max_depth_m"] = max_depth
	return result


## Shader uniform pack for the voxel-soil preview: the analytic profile plus
## the reachable band, packed exactly the way voxel_soil_bounded.gdshader's
## fragment test consumes them. mode 1 = preview blink, 2 = static mark while
## the assist cuts. Pure packing, unit-testable.
static func preview_uniforms(
	profile: RefCounted,
	s_min: float,
	s_max: float,
	half_width_m: float,
	mode: int = 1,
	pulse_hz: float = 0.0
) -> Dictionary:
	if profile == null or mode == 0:
		return {"cut_mode": 0}
	var pack := {
		"cut_mode": mode,
		"cut_origin_xz": profile.origin_xz,
		"cut_axis": profile.axis,
		"cut_band": Vector4(s_min, s_max, half_width_m, profile.toe_s),
		"cut_toe_height": profile.toe_height,
		"cut_tan_theta": profile.grade,
	}
	if pulse_hz > 0.0:
		pack["cut_pulse_hz"] = pulse_hz
	return pack


## Joint-limit FK sweep: the tooth's reachable along-axis interval while
## able to ride the target surface (within SURFACE_RIDE_TOL_M of it). The
## swing joint stays at its current position — the preview freezes it
## exactly the way the active stage does. Public: the level-assist view
## sweeps the same band against its flat tracked plane.
static func reach_band(
	profile: RefCounted,
	articulation: RefCounted,
	chassis_transform: Transform3D,
	edge_local: Vector3,
	joint_limits: Dictionary,
	sweep_steps: int
) -> Vector2:
	var positions := {}
	for state_value in articulation.joint_states():
		var state := state_value as Dictionary
		positions[String(state.get("name", ""))] = float(state.get("position_rad", 0.0))
	var boom_limits := joint_limits.get("boom_joint", Vector2.ZERO) as Vector2
	var arm_limits := joint_limits.get("arm_joint", Vector2.ZERO) as Vector2
	var bucket_limits := joint_limits.get("bucket_joint", Vector2.ZERO) as Vector2
	var s_min := INF
	var s_max := -INF
	var steps := maxi(sweep_steps, 4)
	for i in steps:
		positions["boom_joint"] = lerpf(boom_limits.x, boom_limits.y, float(i) / float(steps - 1))
		for j in steps:
			positions["arm_joint"] = lerpf(arm_limits.x, arm_limits.y, float(j) / float(steps - 1))
			for k in steps:
				positions["bucket_joint"] = lerpf(bucket_limits.x, bucket_limits.y, float(k) / float(steps - 1))
				var frames: Dictionary = articulation.frames_for_positions(chassis_transform, positions)
				var bucket_frame := frames.get("bucket_link", Transform3D.IDENTITY) as Transform3D
				var tooth := bucket_frame * edge_local
				var s: float = profile.along(tooth)
				if absf(tooth.y - profile.height_at(s)) <= SURFACE_RIDE_TOL_M:
					s_min = minf(s_min, s)
					s_max = maxf(s_max, s)
	if s_min > s_max:
		return Vector2.ZERO
	return Vector2(s_min, s_max)
