class_name JoltChassisTrackRuntime
extends Node3D

const VoxelZone = preload("res://scripts/voxel_work_zone_config.gd")
const AssistPipeline = preload("res://scripts/equipment_assist_pipeline.gd")
const SlopeProfileScript := preload("res://scripts/slope_profile.gd")
const SlopeCutPreviewScript := preload("res://scripts/slope_cut_preview.gd")

signal post_step_snapshot_captured(snapshot: Dictionary)
signal performance_step_sampled(chassis_usec: int, tracks_usec: int)

## Owns one dynamic Jolt chassis plus a bounded kinematic work-equipment chain.
## Consumers read copied snapshots; queries and presentation never drive bodies.

const GRAVITY_M_S2 := 9.80665
const MAX_PAYLOAD_MASS_KG := 5000.0
const BODY_NAMES := ["chassis", "upper", "boom", "arm", "bucket"]
const JOINT_NAMES := ["swing_joint", "boom_joint", "arm_joint", "bucket_joint"]
# Cutting resistance: engagement normalizes edge penetration below grade and
# is low-passed so the load ramps smoothly instead of flickering per tick.
const MAX_CUT_DEPTH_M := 0.25
const CUT_ENGAGEMENT_SMOOTH_HZ := 6.0

var configured := false
var enabled := false
var model_id := ""
var rig_id := ""
var rig_version := ""
var contract_error := ""

var _body: RigidBody3D
var _bodies: Dictionary = {}
var _joints: Dictionary = {}
var _body_descriptors: Dictionary = {}
var _joint_descriptors: Dictionary = {}
var _terrain_world: TerrainWorld
var _terrain_collider: TerrainCollider
var _descriptor: Dictionary = {}
var _dynamics: Dictionary = {}
var _tracks: Dictionary = {}
var _track_solver := preload("res://scripts/track_contact_solver.gd").new()
var _race_track_solver := RaceTrackContactSolver.new()
var _tracks_base: Dictionary = {}
var _dynamics_base: Dictionary = {}
var race_mode := false
var _wheel_profile: WheeledMachineProfile
var _wheel_solver := WheeledLocomotionState.new()
var _race_wheel_solver := RaceWheeledLocomotionState.new()
var _wheel_snapshot: Dictionary = {}
var _wheel_command := Vector3.ZERO
var _wheel_drift := 0.0
var _wheel_neutral_armed := false
var _wheel_colliders: Array[CollisionShape3D] = []
var _track_probes: Array = []
var _track_rejections: Dictionary = {}
var _spawn_global_transform := Transform3D.IDENTITY
var _left_command := 0.0
var _right_command := 0.0
var _track_neutral_armed := false
var _left_effort_n := 0.0
var _right_effort_n := 0.0
var _equipment_commands := Vector4.ZERO
var _articulation := KinematicArticulationState.new()
var _bucket_sweeper := BucketProxySweeper.new()
var _solid_contacts := preload("res://scripts/bucket_solid_contact_solver.gd").new()
var solid_tool_identity := ""
var solid_tool_acceptor := Callable()
var _solid_tool_mount := Transform3D.IDENTITY
var _previous_solid_tool_mount := Transform3D.IDENTITY
var _previous_assist_tool_mount := Transform3D.IDENTITY
var _assist_mount_initialized := false
var _previous_solid_world := Transform3D.IDENTITY
var _assist_pipeline := AssistPipeline.new()
var _assist_context: Dictionary = {}
var _assist_enable: Dictionary = {}
var _assist_relaxed := false
var _assist_configured := false
# Cached level-assist reach band: the flat profile tracks the live forward
# axis, so its swept envelope is nearly invariant in profile space. Re-sweep
# only when the latched height or cutting edge changes (plus a slow drift
# fallback) instead of paying ~14k FK evaluations every refresh.
var _level_band := Vector2.ZERO
var _level_band_height := 0.0
var _level_band_edge := Vector3.ZERO
var _level_band_ms := 0
var _level_band_valid := false
# Same idea for the frozen-machine preview: the band only moves when the
# profile parameters (d/theta adjust) or the cutting edge do, so the
# expensive sweep runs on change instead of every refresh tick.
var _preview_band := Vector2.ZERO
var _preview_band_key := ""
var _preview_band_edge := Vector3.ZERO
var _preview_band_valid := false

func collision_layers_snapshot() -> Dictionary:
	if _descriptor.is_empty():
		return {}
	return (_descriptor.get("collision_layers", {}) as Dictionary).duplicate(true)
var _soil_contract: Dictionary = {}
var _cut_engagement := 0.0
var _external_digging_response_enabled := false
var _physics_tick := 0
var _terrain_identity := Vector2i(-1, -1)
var _terrain_identity_valid := false
var _static_map_root: Node3D
var _left_contact_count := 0
var _right_contact_count := 0
var _left_speed_m_s := 0.0
var _right_speed_m_s := 0.0
var _left_slip_ratio := 0.0
var _right_slip_ratio := 0.0
var _left_support_load_n := 0.0
var _right_support_load_n := 0.0
var _left_saturated := false
var _right_saturated := false
var _left_recovery_active := false
var _right_recovery_active := false
var _left_traction_floor_n := 0.0
var _right_traction_floor_n := 0.0
var _contacts: Array[Dictionary] = []
var _quality_flags: Array[String] = []
var _last_step_usec := 0
var _peak_step_usec := 0
var _pending_payload := {"mass_kg": 0.0, "center_of_mass_local": Vector3.ZERO, "identity": -1}
var _applied_payload := {"mass_kg": 0.0, "center_of_mass_local": Vector3.ZERO, "identity": -1}
var _post_step_snapshot: Dictionary = {}
var _command_identity := -1
var _authority_epoch := ""
var _bucket_motion_sequence := 0
var _bucket_query: Dictionary = {}
var _queued_support_wrench: Dictionary = {}
var _applied_support_wrench: Dictionary = {}
var _support_contact_ticks := 0
var _last_applied_support_request_id := ""
var _support_wrench_apply_count := 0
var _bucket_ground_mode := BucketGroundInteractionMode.NORMAL
var _bucket_query_submitted_count := 0
var _bucket_query_executed_count := 0
var _bucket_query_bypassed_count := 0
var _cut_probe_executed_count := 0
var _cut_probe_bypassed_count := 0
var _support_queued_count := 0
var _support_applied_count := 0
var _support_bypassed_count := 0
var _retirement_queued := false
var _posture_error_rad := 0.0
var _terrain_normal_alignment_deg := 0.0
var _lowest_clearance_m := 0.0
var _acceleration_elapsed_s := 0.0
var _acceleration_time_s := -1.0
var _acceleration_direction := 0.0
var _brake_elapsed_s := 0.0
var _brake_stop_time_s := -1.0
var _brake_stop_distance_m := 0.0
var _brake_start_position := Vector3.ZERO
var _brake_was_active := false
var _peak_pitch_angle_rad := 0.0
var _peak_pitch_rate_rad_s := 0.0
var _last_fixed_delta_s := 1.0 / 60.0
var _track_support_source_counts: Dictionary = {}
var attachment_bucket_limit_offsets_deg: Dictionary = {}


func _ready() -> void:
	process_physics_priority = 0
	add_to_group("chassis_performance_sources")


func set_attachment_bucket_limits(attachment_id: String) -> void:
	if _articulation == null:
		return
	# L/dump increases the canonical bucket coordinate on both host models.
	var coupler := attachment_id.get_slice("+", 0)
	# Articulated machines retain their validated cylinder/four-bar range.
	var default_offset := 130.0 if coupler == "xtr13" else 0.0
	var offset := deg_to_rad(float(attachment_bucket_limit_offsets_deg.get(coupler, default_offset)))
	if not is_equal_approx(_articulation.bucket_limit_offset_rad, offset):
		_articulation.bucket_limit_offset_rad = offset
		_level_band_valid = false


func configure_solid_tool(identity: String, contract: Dictionary) -> void:
	solid_tool_identity = identity
	_assist_pipeline.set_tool_geometry(contract)
	_assist_mount_initialized = false
	_solid_contacts.parts.clear()
	if not contract.is_empty():
		_solid_contacts.configure(contract, _layer_mask(int(_descriptor["collision_layers"]["terrain"])))
	_solid_tool_mount = Transform3D.IDENTITY
	_previous_solid_tool_mount = Transform3D.IDENTITY
	_previous_solid_world = Transform3D.IDENTITY
	_applied_support_wrench.clear()
	_reset_support_response(true)


func set_solid_tool_mount(mount: Transform3D) -> void:
	if mount.is_finite():
		_solid_tool_mount = mount
		if _previous_solid_world == Transform3D.IDENTITY:
			_previous_solid_tool_mount = mount
		if not _assist_mount_initialized:
			_previous_assist_tool_mount = mount
			_assist_mount_initialized = true
		_assist_pipeline.set_tool_mount(mount, _previous_assist_tool_mount)


func _physics_process(delta: float) -> void:
	if not configured or not has_body():
		return
	_last_fixed_delta_s = maxf(delta, 0.001)
	var started_usec := Time.get_ticks_usec()
	_physics_tick = Engine.get_physics_frames()
	_update_terrain_identity()
	_clear_tick_telemetry()
	_apply_pending_payload()
	_applied_support_wrench.clear()
	_update_joint_actuators(delta)
	var tracks_usec := 0
	if (enabled or uses_wheels()) and _terrain_identity_valid:
		var tracks_started := Time.get_ticks_usec()
		_apply_track_forces()
		tracks_usec = Time.get_ticks_usec() - tracks_started
	elif enabled:
		_quality_flags.append("terrain_collider_unavailable")
	_clamp_body_velocities()
	_update_response_telemetry(delta)
	_collect_bucket_query_contacts()
	if _left_contact_count + _right_contact_count == 0:
		_quality_flags.append("no_wheel_contact" if uses_wheels() else "no_track_contact")
	_last_step_usec = Time.get_ticks_usec() - started_usec
	_peak_step_usec = maxi(_peak_step_usec, _last_step_usec)
	_capture_post_step_snapshot()
	post_step_snapshot_captured.emit(get_post_step_snapshot())
	if performance_step_sampled.has_connections():
		performance_step_sampled.emit(Time.get_ticks_usec() - started_usec, tracks_usec)


func configure(
	descriptor: PhysicsRigDescriptor,
	terrain_world: TerrainWorld,
	terrain_collider: TerrainCollider,
	spawn_global_transform: Transform3D,
	static_map_root: Node3D = null
) -> bool:
	teardown()
	if descriptor == null:
		return _reject("missing physics rig descriptor")
	_descriptor = descriptor.to_dictionary()
	model_id = String(_descriptor.get("model_id", ""))
	rig_id = String(_descriptor.get("rig_id", ""))
	rig_version = String(_descriptor.get("rig_version", ""))
	_dynamics = (_descriptor.get("chassis_dynamics", {}) as Dictionary).duplicate(true)
	_tracks = (_descriptor.get("tracks", {}) as Dictionary).duplicate(true)
	_wheel_profile = WheeledMachineProfile.load_for_model(model_id)
	if not _wheel_profile.error.is_empty():
		return _reject(_wheel_profile.error)
	if uses_wheels():
		if not _wheel_solver.configure(_wheel_profile.data.parameters, _wheel_profile.stations):
			return _reject(_wheel_solver.last_error)
		_dynamics["linear_damp"] = _wheel_profile.data.linear_damp
		_dynamics["angular_damp"] = _wheel_profile.data.angular_damp
		_dynamics["max_linear_speed_m_s"] = maxf(float(_dynamics["max_linear_speed_m_s"]), float(_wheel_solver.parameters.max_speed_mps) * 1.5)
	else:
		_track_solver.configure(_tracks, _dynamics)
	_tracks_base = _tracks.duplicate(true)
	_dynamics_base = _dynamics.duplicate(true)
	_apply_locomotion_mode()
	_terrain_world = terrain_world
	_terrain_collider = terrain_collider
	_static_map_root = static_map_root
	_spawn_global_transform = spawn_global_transform
	_index_descriptors()
	if _body_descriptors.size() != BODY_NAMES.size() or _joint_descriptors.size() != JOINT_NAMES.size():
		return _reject("descriptor does not contain the complete kinematic chain")
	if not _build_rig():
		_destroy_rig()
		return _reject("could not build hybrid Jolt rig")
	configured = true
	enabled = true
	contract_error = ""
	_authority_epoch = "%s:%d" % [model_id, Time.get_ticks_usec()]
	_update_terrain_identity()
	_set_invalid_bucket_query("bucket_query_not_sampled")
	_capture_post_step_snapshot()
	return true


func teardown() -> void:
	_static_map_root = null
	solid_tool_identity = ""
	_assist_mount_initialized = false
	_previous_assist_tool_mount = Transform3D.IDENTITY
	solid_tool_acceptor = Callable()
	_solid_tool_mount = Transform3D.IDENTITY
	_previous_solid_tool_mount = Transform3D.IDENTITY
	configured = false
	enabled = false
	set_commands(0.0, 0.0)
	set_equipment_commands(Vector4.ZERO)
	_destroy_rig()
	_descriptor.clear()
	_dynamics.clear()
	_tracks.clear()
	_tracks_base.clear()
	_dynamics_base.clear()
	_race_track_solver.reset()
	_race_track_solver.assist.clear()
	_race_wheel_solver.reset()
	_race_wheel_solver.assist.clear()
	_wheel_profile = null
	_wheel_snapshot.clear()
	_wheel_solver.reset()
	_wheel_neutral_armed = false
	_body_descriptors.clear()
	_joint_descriptors.clear()
	_contacts.clear()
	_quality_flags.clear()
	_articulation.reset()
	_bucket_sweeper.reset()
	_assist_pipeline.reset("teardown")
	_assist_context.clear()
	_assist_configured = false
	_soil_contract.clear()
	_cut_engagement = 0.0
	_post_step_snapshot.clear()
	_pending_payload = {"mass_kg": 0.0, "center_of_mass_local": Vector3.ZERO, "identity": -1}
	_applied_payload = _pending_payload.duplicate(true)
	_terrain_identity = Vector2i(-1, -1)
	_terrain_identity_valid = false
	_command_identity = -1
	_authority_epoch = ""
	_bucket_motion_sequence = 0
	_bucket_query.clear()
	_queued_support_wrench.clear()
	_applied_support_wrench.clear()
	_support_wrench_apply_count = 0
	_reset_response_telemetry()
	_reset_support_response(true)
	_clear_tick_telemetry()


func retire_deferred() -> void:
	if _retirement_queued or is_queued_for_deletion():
		return
	_retirement_queued = true
	call_deferred("_complete_deferred_retirement")


func _complete_deferred_retirement() -> void:
	teardown()
	queue_free()


func set_enabled(value: bool) -> void:
	enabled = value and configured
	if not enabled:
		stop_motion()
		_track_neutral_armed = false
		_track_solver.reset()
		_race_track_solver.reset()
		_race_wheel_solver.reset()
		_left_effort_n = 0.0
		_right_effort_n = 0.0


## Race mode swaps in a parallel solver pair tuned from the same descriptors;
## normal parameters are snapshotted at configure so toggling off restores them
## byte-for-byte. The flag survives model switches via configure().
func set_race_mode(value: bool) -> void:
	if race_mode == value:
		return
	race_mode = value
	stop_motion()
	_track_solver.reset()
	_race_track_solver.reset()
	_wheel_solver.reset()
	_race_wheel_solver.reset()
	_apply_locomotion_mode()
	_capture_post_step_snapshot()


func _apply_locomotion_mode() -> void:
	if _descriptor.is_empty() or _dynamics_base.is_empty():
		return
	_dynamics = _dynamics_base.duplicate(true)
	_tracks = _tracks_base.duplicate(true)
	var kind := "wheeled" if uses_wheels() else "tracked"
	var overlay := RaceModeProfile.overlay_for(model_id, kind) if race_mode else {}
	if race_mode and overlay.is_empty():
		_quality_flags.append("race_overlay_unavailable")
	if not race_mode:
		if uses_wheels():
			_wheel_solver.configure(_wheel_profile.data.parameters, _wheel_profile.stations)
		else:
			_track_solver.configure(_tracks, _dynamics)
	elif uses_wheels():
		var base_params := WheeledLocomotionState.DEFAULTS.duplicate(true)
		for key in _wheel_profile.data.parameters:
			base_params[key] = _wheel_profile.data.parameters[key]
		var wheel_params := RaceModeProfile.apply_overlay(base_params, overlay.get("params", {}))
		if not _race_wheel_solver.configure_race(
			wheel_params, _wheel_profile.stations, overlay.get("assist", {})
		):
			_quality_flags.append("race_wheel_rejected")
			race_mode = false
			_apply_locomotion_mode()
			return
		_dynamics = RaceModeProfile.apply_overlay(_dynamics, overlay.get("body", {}))
		_dynamics["max_linear_speed_m_s"] = maxf(
			float(_dynamics["max_linear_speed_m_s"]),
			float(wheel_params.get("max_speed_mps", 0.0)) * 1.5
		)
	else:
		_tracks = RaceModeProfile.apply_overlay(_tracks, overlay.get("params", {}))
		_dynamics = RaceModeProfile.apply_overlay(_dynamics, overlay.get("body", {}))
		_race_track_solver.configure_race(_tracks, _dynamics, overlay.get("assist", {}))
	if _body != null and is_instance_valid(_body):
		_body.linear_damp = float(_dynamics["linear_damp"])
		_body.angular_damp = float(_dynamics["angular_damp"])


func uses_wheels() -> bool:
	return _wheel_profile != null and _wheel_profile.enabled


func set_wheeled_commands(throttle: float, brake: float, steer: float, drift := 0.0) -> void:
	var command := Vector3(throttle, brake, steer)
	if not command.is_finite():
		command = Vector3(0, 1, 0)
		_wheel_neutral_armed = false
	if enabled and command.is_zero_approx():
		_wheel_neutral_armed = true
	_wheel_command = command if enabled and _wheel_neutral_armed else Vector3(0, 1, 0)
	_wheel_drift = clampf(drift, 0.0, 1.0) if enabled and _wheel_neutral_armed and is_finite(drift) else 0.0
	# Existing feedback/diagnostics retain common signed travel channels.
	_left_command = _wheel_command.x
	_right_command = _wheel_command.x


func set_commands(left: float, right: float) -> void:
	var next_left := clampf(left, -1.0, 1.0) if is_finite(left) else 0.0
	var next_right := clampf(right, -1.0, 1.0) if is_finite(right) else 0.0
	if absf(next_left) <= 0.001 and absf(next_right) <= 0.001:
		_track_neutral_armed = true
		_left_command = 0.0
		_right_command = 0.0
		return
	if not _track_neutral_armed:
		_left_command = 0.0
		_right_command = 0.0
		_quality_flags.append("track_neutral_rearm_required")
		return
	_left_command = next_left
	_right_command = next_right


func set_equipment_commands(commands: Vector4, identity: int = -1) -> void:
	if identity >= 0 and identity < _command_identity:
		return
	if identity >= 0:
		_command_identity = identity
	if not _finite_vector4(commands):
		_equipment_commands = Vector4.ZERO
		_articulation.neutral_armed = false
		return
	_equipment_commands = Vector4(
		clampf(commands.x, -1.0, 1.0),
		clampf(commands.y, -1.0, 1.0),
		clampf(commands.z, -1.0, 1.0),
		clampf(commands.w, -1.0, 1.0),
	)
	_articulation.set_commands(_equipment_commands, identity)


func set_equipment_assist_enabled(stage_name: String, value: bool) -> bool:
	_assist_enable[stage_name] = value
	if not _assist_configured:
		return not value
	return _assist_pipeline.set_stage_enabled(stage_name, value)


func is_equipment_assist_enabled(stage_name: String) -> bool:
	return _assist_configured and _assist_pipeline.is_stage_enabled(stage_name)


## Runtime parameter injection for stages whose task is parameterized after
## configure (the confirmed slope profile arrives here from the controller).
func set_equipment_assist_params(stage_name: String, params: Dictionary) -> bool:
	# The relaxed-attitude toggle is a durable user option: persist it so a
	# configure() rebuild re-arms it; the single-use slope profile is NOT
	# persisted — replaying a consumed profile after a model switch would
	# re-anchor a stale surface.
	if params.has("relaxed_attitude"):
		_assist_relaxed = bool(params.get("relaxed_attitude"))
	if not _assist_configured:
		return false
	return _assist_pipeline.set_stage_params(stage_name, params)


## The configured profile parameters for a stage (adjustment rates, preview
## cadence) — read-only view for non-control consumers like the preview
## state machine.
func get_equipment_assist_params(stage_name: String) -> Dictionary:
	if not _assist_configured:
		return {}
	var stage := _assist_pipeline.get_stage(stage_name)
	return stage.profile_params if stage != null else {}


## Latest controller-pushed semantics for assist stages (soil status, external
## targets). Stages read it through EquipmentKinematicsContext.external; the
## pipeline never interprets it.
func set_assist_context(context: Dictionary) -> void:
	_assist_context = context.duplicate(true)


## Build the slope profile the current preview parameters imply: the anchor
## is the live tooth position, the axis the live outward direction, and the
## toe height the terrain under the toe point. Shared by the preview flash
## and the confirm step so what was shown is exactly what gets tracked.
func build_slope_profile(distance_m: float, angle_deg: float) -> RefCounted:
	if not _assist_configured or _articulation == null or _body == null:
		return null
	var ctx := _assist_pipeline.build_context(
		_articulation, _body.global_transform, 1.0 / 60.0, _assist_context,
		_body.linear_velocity, _body.angular_velocity
	)
	var toe_xz := Vector2(ctx.bucket_ref_world.x, ctx.bucket_ref_world.z) \
		+ Vector2(ctx.horizontal.x, ctx.horizontal.z) * distance_m
	var toe_height := _sample_soil_height(toe_xz)
	if not is_finite(toe_height):
		return null
	var profile := SlopeProfileScript.create(ctx.bucket_ref_world, ctx.horizontal, distance_m, angle_deg, toe_height)
	var stage := _assist_pipeline.get_stage("slope_grade")
	if stage != null:
		profile.knee_blend_m = float((stage.profile_params as Dictionary).get("knee_blend_m", 0.0))
	if ctx.joint_pivot_world.has("swing_joint"):
		var pivot := ctx.joint_pivot_world["swing_joint"] as Vector3
		profile.capture_anchor(Vector2(pivot.x, pivot.z))
	return profile


## Preview the pending cut: the reachable band along the profile axis plus
## the terrain cells rising above the target surface inside it. Returns
## {"ok", "profile", "result"} — result carries the sampled grids feeding
## the soil-shader band uniforms and the volume estimate for the HUD readout.
func update_slope_preview(profile: RefCounted) -> Dictionary:
	if profile == null or not _assist_configured or _articulation == null or _body == null:
		return {"ok": false}
	var ctx := _assist_pipeline.build_context(
		_articulation, _body.global_transform, 1.0 / 60.0, _assist_context,
		_body.linear_velocity, _body.angular_velocity
	)
	var stage := _assist_pipeline.get_stage("slope_grade")
	var params: Dictionary = stage.profile_params if stage != null else {}
	var sampler := func(world_xz: Vector2) -> float: return _sample_soil_height(world_xz)
	var edge := _cutting_edge_local()
	# The machine is frozen while previewing, so the swept reach band only
	# changes with the profile parameters the operator adjusts (or a tool
	# swap). Re-sweep on change at a reduced step count — the band is an
	# envelope for marking/volume, not a precision surface — and feed the
	# cheap terrain grid every refresh.
	var band_key := "%s|%s|%.3f|%.3f|%.4f|%.3f" % [
		str(profile.origin_xz), str(profile.axis), profile.toe_s,
		profile.toe_height, profile.grade, profile.knee_blend_m
	]
	if not _preview_band_valid or band_key != _preview_band_key or edge != _preview_band_edge:
		_preview_band = SlopeCutPreviewScript.reach_band(
			profile,
			_articulation,
			_body.global_transform,
			edge,
			ctx.joint_limits,
			mini(int(params.get("preview_sweep_steps", 24)), 12)
		)
		_preview_band_key = band_key
		_preview_band_edge = edge
		_preview_band_valid = true
	var result := SlopeCutPreviewScript.compute(
		profile,
		_articulation,
		_body.global_transform,
		edge,
		ctx.joint_limits,
		sampler,
		float(params.get("preview_cell_m", 0.25)),
		_cutting_edge_half_width(),
		int(params.get("preview_sweep_steps", 24)),
		_preview_band
	)
	# The voxel soil material marks the would-be-removed surface itself:
	# mode 1 blinks while the operator adjusts, mode 2 keeps a static tint
	# while the assist cuts (the mark self-erases as soil actually leaves).
	var half_width := _cutting_edge_half_width()
	set_slope_cut_preview(
		SlopeCutPreviewScript.preview_uniforms(
			profile,
			float(result.get("s_min", 0.0)),
			float(result.get("s_max", 0.0)),
			half_width,
			1,
			float(params.get("preview_pulse_hz", 2.2))
		)
	)
	return {"ok": true, "profile": profile, "result": result}


## Confirm the previewed slope: inject the frozen profile and enable the
## stage (mutual exclusion drops the level assist if it was on). The preview
## band arrives with the call so the soil mark can flip from blinking to a
## static tint without re-sweeping reachability.
func confirm_slope_assist(profile: RefCounted, preview_result: Dictionary = {}) -> bool:
	if profile == null or not _assist_configured:
		return false
	if not _assist_pipeline.set_stage_params("slope_grade", {"profile": profile}):
		return false
	var half_width := float(preview_result.get("half_width_m", _cutting_edge_half_width()))
	set_slope_cut_preview(
		SlopeCutPreviewScript.preview_uniforms(
			profile,
			float(preview_result.get("s_min", 0.0)),
			float(preview_result.get("s_max", 0.0)),
			half_width,
			2
		)
	)
	return set_equipment_assist_enabled("slope_grade", true)


## Feed the analytic preview into the voxel soil material — the terrain marks
## its own would-be-removed surface. Missing zone is a no-op (static maps and
## bare runtimes have no voxel work zone sibling).
func set_slope_cut_preview(uniforms: Dictionary) -> void:
	var zone := _voxel_preview_sink()
	if zone != null:
		zone.set_cut_preview(uniforms)


func clear_slope_cut_preview() -> void:
	var zone := _voxel_preview_sink()
	if zone != null:
		zone.clear_cut_preview()


## Re-push the mode-2 soil mark while the assist runs: the profile
## re-anchors onto the live heading every tick, so the static tint must
## chase it or the mark stays where the machine was at confirm.
func refresh_slope_cut_mark(profile: RefCounted, preview_result: Dictionary) -> void:
	if profile == null:
		return
	set_slope_cut_preview(
		SlopeCutPreviewScript.preview_uniforms(
			profile,
			float(preview_result.get("s_min", 0.0)),
			float(preview_result.get("s_max", 0.0)),
			float(preview_result.get("half_width_m", _cutting_edge_half_width())),
			2
		)
	)


## Duck-typed lookup: the work zone sits next to TerrainWorld under the same
## terrain root, reached by capability rather than a hardcoded sibling path.
func _voxel_preview_sink() -> Node:
	if _terrain_world == null or not _terrain_world.is_inside_tree():
		return null
	var parent := _terrain_world.get_parent()
	if parent == null:
		return null
	for child in parent.get_children():
		if child.has_method("set_cut_preview"):
			return child
	return null


## Everything the side-view HUD draws in one frame: joint pivots and tooth
## projected into the profile plane, the centerline terrain strip, and the
## live tooth-to-target offset. terrain polyline is (s, h) pairs so the view
## needs no projection math beyond the static helper.
func slope_view_snapshot(
	profile: RefCounted,
	s_min: float,
	s_max: float,
	half_width_m: float,
	volume_m3: float,
	mode: String
) -> Dictionary:
	return _view_snapshot(profile, s_min, s_max, half_width_m, volume_m3, mode)


## Level-assist guidance frame: the latched horizontal plane is a degenerate
## slope profile (grade 0, toe at the anchor), so the same snapshot shape —
## and therefore the same HUD panel — carries it. The reach band is swept
## against that flat surface exactly like the slope band. The profile rides
## along in the dict so the controller can rebuild the world-space ribbon.
func level_view_snapshot() -> Dictionary:
	if not _assist_configured or _articulation == null or _body == null:
		return {}
	var stage := _assist_pipeline.get_stage("bucket_level")
	if stage == null or not stage.enabled:
		return {}
	var ctx := _assist_pipeline.build_context(
		_articulation, _body.global_transform, 1.0 / 60.0, _assist_context,
		_body.linear_velocity, _body.angular_velocity
	)
	var height_ref := float((stage.get_status_snapshot() as Dictionary).get("height_ref_m", 0.0))
	var profile := SlopeProfileScript.create(
		ctx.bucket_ref_world, ctx.horizontal, 0.0, 0.0, height_ref
	)
	var edge := _cutting_edge_local()
	var need_sweep := not _level_band_valid \
		or absf(height_ref - _level_band_height) > 0.05 \
		or edge != _level_band_edge \
		or Time.get_ticks_msec() - _level_band_ms > 5000
	if need_sweep:
		_level_band = SlopeCutPreviewScript.reach_band(
			profile,
			_articulation,
			_body.global_transform,
			edge,
			ctx.joint_limits,
			10
		)
		_level_band_height = height_ref
		_level_band_edge = edge
		_level_band_ms = Time.get_ticks_msec()
		_level_band_valid = true
	var view := _view_snapshot(
		profile, _level_band.x, _level_band.y, _cutting_edge_half_width(), 0.0, "level"
	)
	view["profile"] = profile
	return view


func _view_snapshot(
	profile: RefCounted,
	s_min: float,
	s_max: float,
	half_width_m: float,
	volume_m3: float,
	mode: String
) -> Dictionary:
	if profile == null or not _assist_configured or _articulation == null or _body == null:
		return {}
	var ctx := _assist_pipeline.build_context(
		_articulation, _body.global_transform, 1.0 / 60.0, _assist_context,
		_body.linear_velocity, _body.angular_velocity
	)
	var joints := {}
	for joint_name in ["swing_joint", "boom_joint", "arm_joint", "bucket_joint"]:
		joints[joint_name] = ctx.joint_pivot_world.get(joint_name, Vector3.ZERO)
	var tooth: Vector3 = ctx.bucket_ref_world
	var machine_s: float = profile.along(joints.get("swing_joint", tooth))
	return {
		"mode": mode,
		"origin_xz": profile.origin_xz,
		"axis": profile.axis,
		"toe_s": profile.toe_s,
		"toe_h": profile.toe_height,
		"grade": profile.grade,
		"angle_deg": profile.angle_deg,
		"knee_w": profile.knee_blend_m,
		"s_min": s_min,
		"s_max": s_max,
		"half_width": half_width_m,
		"volume_m3": volume_m3,
		"joints": joints,
		"tooth": tooth,
		"tooth_err": tooth.y - profile.height_at(profile.along(tooth)),
		"terrain": _sample_profile_centerline(
			profile, minf(minf(s_min - 1.0, -6.0), machine_s - 2.0), maxf(s_max + 1.0, machine_s + 2.0)
		),
	}


## Terrain heights along the profile centerline (t = 0): the soil strip the
## bucket actually rides, sampled through the same authoritative query the
## cut probe uses so the drawn line matches what gets dug.
func _sample_profile_centerline(
	profile: RefCounted, s0: float, s1: float, step_m: float = 0.25
) -> PackedVector2Array:
	var line := PackedVector2Array()
	var s := s0
	while s <= s1 + 0.0001:
		var world_xz: Vector2 = profile.origin_xz + profile.axis * s
		var height := _sample_soil_height(world_xz)
		if is_finite(height):
			line.append(Vector2(s, height))
		s += step_m
	return line


func _cutting_edge_local() -> Vector3:
	var edge := (_soil_contract.get("proxies", {}) as Dictionary).get("cutting_edge", {}) as Dictionary
	var rows := edge.get("center_godot", [0.0, 0.0, 0.0]) as Array
	return Vector3(float(rows[0]), float(rows[1]), float(rows[2])) if rows.size() == 3 else Vector3.ZERO


func _cutting_edge_half_width() -> float:
	var edge := (_soil_contract.get("proxies", {}) as Dictionary).get("cutting_edge", {}) as Dictionary
	return float(edge.get("half_width_m", 0.6))


## Authoritative soil height: the same TerrainState the cut-penetration
## probe reads, so the flash marks exactly the soil the dig system sees.
## Outside the heightfield grid a downward terrain raycast fills in (the
## voxel work zone owns its own collider inside the pit).
func _sample_soil_height(world_xz: Vector2) -> float:
	if _terrain_world != null and _terrain_world.terrain_state != null \
			and _terrain_world.terrain_state.is_inside_grid(world_xz):
		var height := _terrain_world.terrain_state.sample_surface_bilinear_at(world_xz)
		if is_finite(height):
			return height
	if _body == null:
		return NAN
	var space := _body.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(world_xz.x, 60.0, world_xz.y),
		Vector3(world_xz.x, -40.0, world_xz.y)
	)
	query.collision_mask = 1
	var hit := space.intersect_ray(query)
	return float((hit.get("position", Vector3.ZERO) as Vector3).y) if not hit.is_empty() else NAN


func set_bucket_payload(mass_kg: float, center_of_mass_local: Vector3, identity: int) -> bool:
	var latest_identity := maxi(int(_pending_payload["identity"]), int(_applied_payload["identity"]))
	if (
		not is_finite(mass_kg) or mass_kg < 0.0 or not center_of_mass_local.is_finite()
		or identity <= latest_identity or not _payload_center_in_bucket(center_of_mass_local)
	):
		return false
	_pending_payload = {
		"mass_kg": minf(mass_kg, MAX_PAYLOAD_MASS_KG),
		"center_of_mass_local": center_of_mass_local,
		"identity": identity,
	}
	return true


func get_bucket_payload_identity() -> int:
	return maxi(int(_pending_payload["identity"]), int(_applied_payload["identity"]))


func set_external_digging_response_enabled(value: bool) -> void:
	_external_digging_response_enabled = value
	if value:
		_articulation.set_cut_resistance(0.0)


func _payload_center_in_bucket(center: Vector3) -> bool:
	var bucket_data := _body_descriptors.get("bucket", {}) as Dictionary
	if bucket_data.is_empty():
		return false
	var shape := bucket_data.get("shape", {}) as Dictionary
	if shape.is_empty():
		return false
	var shape_center := _vector3(shape["center_m"])
	var half_size := 0.5 * _vector3(shape["size_m"])
	var offset := center - shape_center
	return absf(offset.x) <= half_size.x and absf(offset.y) <= half_size.y and absf(offset.z) <= half_size.z


func stop_motion() -> void:
	_wheel_command = Vector3(0, 1, 0)
	_wheel_drift = 0.0
	_wheel_neutral_armed = false
	set_commands(0.0, 0.0)
	set_equipment_commands(Vector4.ZERO)
	_assist_pipeline.reset("stop_motion")
	_queued_support_wrench.clear()
	_applied_support_wrench.clear()
	_reset_support_response(true)


func set_bucket_ground_mode(value: String) -> bool:
	if not BucketGroundInteractionMode.is_valid(value):
		return false
	var entering_passthrough := (
		BucketGroundInteractionMode.is_passthrough(value)
		and not BucketGroundInteractionMode.is_passthrough(_bucket_ground_mode)
	)
	if entering_passthrough and not _clear_bucket_payload_for_policy_transition():
		return false
	_bucket_ground_mode = value
	if BucketGroundInteractionMode.is_passthrough(value):
		if not _queued_support_wrench.is_empty():
			_support_bypassed_count += 1
		_queued_support_wrench.clear()
		_applied_support_wrench.clear()
		_cut_engagement = 0.0
		_articulation.set_cut_resistance(0.0)
		_reset_support_response(true)
		_set_invalid_bucket_query("bucket_ground_interaction_bypassed")
	_capture_post_step_snapshot()
	return true


func _clear_bucket_payload_for_policy_transition() -> bool:
	var identity := get_bucket_payload_identity() + 1
	if not _articulation.set_payload(0.0, Vector3.ZERO, identity):
		return false
	_applied_payload = _articulation.payload_snapshot()
	_pending_payload = _applied_payload.duplicate(true)
	return true


func reset(spawn_global_transform := Transform3D.IDENTITY) -> void:
	_spawn_global_transform = spawn_global_transform
	stop_motion()
	_destroy_rig()
	_command_identity = -1
	_applied_payload = {"mass_kg": 0.0, "center_of_mass_local": Vector3.ZERO, "identity": -1}
	_pending_payload = _applied_payload.duplicate(true)
	configured = _build_rig()
	enabled = configured
	if not configured:
		contract_error = "could not rebuild hybrid Jolt rig"
	_authority_epoch = "%s:%d" % [model_id, Time.get_ticks_usec()]
	_bucket_motion_sequence = 0
	_update_terrain_identity()
	_set_invalid_bucket_query("bucket_query_not_sampled")
	_queued_support_wrench.clear()
	_applied_support_wrench.clear()
	_support_wrench_apply_count = 0
	_reset_response_telemetry()
	_reset_support_response(true)
	_clear_tick_telemetry()
	_capture_post_step_snapshot()


func has_body() -> bool:
	return (
		configured
		and _body != null
		and is_instance_valid(_body)
		and _body.is_inside_tree()
		and _bodies.size() == 1
		and _joints.is_empty()
		and _articulation.configured
	)


func get_body_global_transform() -> Transform3D:
	return _body.global_transform if has_body() else Transform3D.IDENTITY


func get_post_step_snapshot() -> Dictionary:
	return _post_step_snapshot.duplicate(true)


## Read-only borrow of the last completed step's snapshot. The dictionary is
## rebuilt each physics step; callers must read it inside the current fixed
## step and must never retain or mutate it. Mirrors cell_patch_read_snapshot.
func peek_post_step_snapshot() -> Dictionary:
	return _post_step_snapshot if not _post_step_snapshot.is_empty() else _empty_snapshot()


func get_status_snapshot() -> Dictionary:
	var snapshot := get_post_step_snapshot()
	if snapshot.is_empty():
		snapshot = _empty_snapshot()
	snapshot["authority_mode"] = AuthorityProfile.JOLT_AUTHORITATIVE
	snapshot["configured"] = configured
	snapshot["enabled"] = enabled
	snapshot["model_id"] = model_id
	snapshot["rig_id"] = rig_id
	snapshot["rig_version"] = rig_version
	snapshot["contract_error"] = contract_error
	snapshot["peak_step_usec"] = _peak_step_usec
	return snapshot


func _index_descriptors() -> void:
	_body_descriptors.clear()
	_joint_descriptors.clear()
	for body_value in _descriptor.get("bodies", []):
		var body := body_value as Dictionary
		_body_descriptors[String(body.get("name", ""))] = body.duplicate(true)
	for joint_value in _descriptor.get("joints", []):
		var joint := joint_value as Dictionary
		_joint_descriptors[String(joint.get("name", ""))] = joint.duplicate(true)


func _build_rig() -> bool:
	_body = _build_body()
	if _body == null:
		return false
	add_child(_body)
	_body.global_transform = _spawn_global_transform
	_bodies["chassis"] = _body
	if not _articulation.configure(_descriptor, _spawn_global_transform):
		return false
	_soil_contract = _load_soil_contract()
	if _soil_contract.is_empty():
		return false
	_assist_configured = _assist_pipeline.configure(_descriptor, _soil_contract, model_id)
	for stage_name in _assist_enable.keys():
		_assist_pipeline.set_stage_enabled(String(stage_name), bool(_assist_enable[stage_name]))
	if _assist_relaxed:
		for stage_name in ["bucket_level", "slope_grade"]:
			_assist_pipeline.set_stage_params(stage_name, {"relaxed_attitude": true})
	if not _solid_contacts.configure(_soil_contract, _layer_mask(int(_descriptor["collision_layers"]["terrain"]))):
		return false
	return _bucket_sweeper.configure(
		model_id,
		_soil_contract,
		_terrain_collider,
		_layer_mask(int(_descriptor["collision_layers"]["terrain"])),
		_static_map_root,
	)


func _build_body() -> RigidBody3D:
	var body := RigidBody3D.new()
	body.name = "AuthoritativeChassisBody"
	body.mass = float(_dynamics["mass_kg"])
	body.inertia = _vector3(_dynamics["inertia_diagonal_kg_m2"])
	body.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	body.center_of_mass = _vector3(_dynamics["center_of_mass_m"])
	body.linear_damp = float(_dynamics["linear_damp"])
	body.angular_damp = float(_dynamics["angular_damp"])
	body.can_sleep = bool(_dynamics["can_sleep"])
	body.continuous_cd = bool(_dynamics["continuous_collision_detection"])
	var contact_material := PhysicsMaterial.new()
	contact_material.bounce = 0.0
	contact_material.friction = 0.35
	contact_material.rough = true
	body.physics_material_override = contact_material
	body.contact_monitor = true
	body.max_contacts_reported = 32
	body.collision_layer = _layer_mask(int(_descriptor["collision_layers"]["machine"]))
	# Obstacle/bottoming collision remains enabled throughout support changes.
	body.collision_mask = _layer_mask(int(_descriptor["collision_layers"]["terrain"]))
	if uses_wheels():
		_add_wheel_collision_shapes(body)
	else:
		_track_solver.add_collision_shapes(body)
	return body


func _update_joint_actuators(delta: float) -> void:
	_articulation.set_cut_resistance(
		0.0
		if _external_digging_response_enabled or _bucket_ground_bypassed()
		else _cut_engagement
	)
	if _assist_configured and _assist_pipeline.any_enabled():
		var assist := _assist_pipeline.step(
			_equipment_commands,
			_articulation,
			_body.global_transform,
			delta,
			_assist_context,
			# RigidBody velocity is measured at COM; context transport starts
			# at chassis origin, which differs while the chassis rocks.
			_body.linear_velocity - _body.angular_velocity.cross(_body.global_basis * _body.center_of_mass),
			_body.angular_velocity,
		)
		var effective := assist.get("commands", _equipment_commands) as Vector4
		for flag in assist.get("flags", []):
			_quality_flags.append(String(flag))
		if effective != _equipment_commands:
			_articulation.set_commands(effective, _command_identity)
	var proposal := _articulation.propose_step(delta, _body.global_transform, enabled)
	if proposal.is_empty():
		_quality_flags.append("kinematic_articulation_unavailable")
		return
	for flag in proposal.get("quality_flags", []):
		_quality_flags.append(String(flag))
	var accepted_fraction := 1.0
	var previous_frames := _articulation.frames_at_chassis(_body.global_transform)
	var candidate_frames := proposal.get("frames", {}) as Dictionary
	if previous_frames.has("bucket_link") and candidate_frames.has("bucket_link"):
		_bucket_query_submitted_count += 1
	if _bucket_ground_bypassed():
		_bucket_motion_sequence += 1
		_bucket_query_bypassed_count += 1
		_cut_probe_bypassed_count += 1
		_support_bypassed_count += 1
		_cut_engagement = 0.0
		_queued_support_wrench.clear()
		_applied_support_wrench.clear()
		_reset_support_response(true)
		_set_invalid_bucket_query(
			"bucket_ground_interaction_bypassed",
			previous_frames.get("bucket_link", Transform3D.IDENTITY) as Transform3D,
			candidate_frames.get("bucket_link", Transform3D.IDENTITY) as Transform3D,
		)
		_articulation.accept_step(proposal, 1.0)
		_previous_assist_tool_mount = _solid_tool_mount
		var passthrough_frames := _articulation.accepted_frames()
		if passthrough_frames.has("bucket_link"):
			_bucket_query["accepted_bucket_transform"] = passthrough_frames["bucket_link"]
		return
	var solid: Dictionary = {"contacts": [], "accepted_fraction": 1.0}
	var current_tool := Transform3D.IDENTITY
	var candidate_tool := Transform3D.IDENTITY
	if previous_frames.has("bucket_link") and candidate_frames.has("bucket_link"):
		_bucket_motion_sequence += 1
		_bucket_query_executed_count += 1
		current_tool = (previous_frames["bucket_link"] as Transform3D) * _previous_solid_tool_mount
		candidate_tool = (candidate_frames["bucket_link"] as Transform3D) * _solid_tool_mount
		solid = _solid_contacts.query_contacts(get_world_3d().direct_space_state,
			current_tool, candidate_tool, _body,
			Callable(self, "_accept_bucket_solid_hit"), _previous_solid_world)
		accepted_fraction = float(solid["accepted_fraction"])
		_bucket_query = {
			"valid": true, "accepted_fraction": accepted_fraction, "contacts": [],
			"model_id": model_id, "proxy_version": "solid-contact-v1:" + model_id,
			"terrain_generation": _terrain_identity.x, "terrain_revision": _terrain_identity.y,
			"physics_tick": _physics_tick, "authority_epoch": _authority_epoch,
			"motion_sequence": _bucket_motion_sequence, "quality_flags": [],
			"previous_bucket_transform": previous_frames["bucket_link"],
			"candidate_bucket_transform": candidate_frames["bucket_link"],
		}
		for value in solid["contacts"]:
			var contact := (value as Dictionary).duplicate()
			contact["contact_id"] = "%d:%d:%s" % [_physics_tick, _bucket_motion_sequence, contact["region_id"]]
			contact["query_source"] = "solid_collider"
			contact["point_valid"] = true
			contact["initial_overlap"] = false
			contact["travel_fraction"] = accepted_fraction
			contact["quality"] = "solid_contact"
			contact["classification"] = "blocked"
			_bucket_query["contacts"].append(contact)
		# Voxel cutting retains its independent analytic resistance. Solid contacts
		# never use tooth direction or surface-up thresholds to choose collision.
		var raw_engagement := 0.0
		if _terrain_world != null and _terrain_world.terrain_state != null:
			_cut_probe_executed_count += 1
			var bucket: Transform3D = candidate_frames["bucket_link"]
			if solid["contacts"].is_empty():
				raw_engagement = clampf(_bucket_sweeper.probe_cut_penetration(bucket,
					_terrain_world.terrain_state) / _max_cut_depth_m(), 0.0, 1.0)
		_cut_engagement = lerpf(_cut_engagement, raw_engagement,
			clampf(1.0 - exp(-CUT_ENGAGEMENT_SMOOTH_HZ * delta), 0.0, 1.0))
		if not solid["contacts"].is_empty():
			_cut_engagement = 0.0
	else:
		_set_invalid_bucket_query("bucket_query_unavailable")
	_articulation.accept_step(proposal, accepted_fraction)
	if accepted_fraction < 1.0 and solid_tool_acceptor.is_valid():
		var accepted_mount: Variant = solid_tool_acceptor.call(accepted_fraction)
		if accepted_mount is Transform3D:
			_solid_tool_mount = accepted_mount
	var accepted_frames := _articulation.accepted_frames()
	if not _bucket_query.is_empty() and accepted_frames.has("bucket_link"):
		_bucket_query["accepted_bucket_transform"] = accepted_frames["bucket_link"]
	var accepted_tool: Transform3D = accepted_frames.get("bucket_link", Transform3D.IDENTITY) * _solid_tool_mount
	if enabled and not solid["contacts"].is_empty():
		var response := _solid_contacts.solve(solid["contacts"], current_tool, accepted_tool, _body, delta)
		_apply_solid_contact_response(response, solid["contacts"])
	else:
		_reset_support_response()
	_previous_solid_world = accepted_tool
	_previous_solid_tool_mount = _solid_tool_mount
	_previous_assist_tool_mount = _solid_tool_mount


func _accept_bucket_solid_hit(hit: Dictionary) -> bool:
	var collider := instance_from_id(int(hit.get("collider_id", 0))) as Node
	# Voxel chunks share the environment layer, but remain exclusively soil-owned.
	var ancestor := collider
	while ancestor != null:
		if ancestor.is_class("VoxelTerrain") or ancestor.is_class("VoxelLodTerrain"):
			return false
		ancestor = ancestor.get_parent()
	if collider == _body or (collider != null and is_ancestor_of(collider)):
		return false
	if collider != null and _terrain_collider != null and _terrain_collider.is_ancestor_of(collider):
		return _terrain_identity_valid
	return true


func _max_cut_depth_m() -> float:
	var interaction := (_soil_contract.get("interaction", {}) as Dictionary)
	return maxf(0.01, float(interaction.get("maximum_cut_depth_m", MAX_CUT_DEPTH_M)))


func _apply_pending_payload() -> void:
	if int(_pending_payload["identity"]) <= int(_applied_payload.get("identity", -1)):
		return
	if not _articulation.set_payload(
		float(_pending_payload["mass_kg"]),
		_pending_payload["center_of_mass_local"] as Vector3,
		int(_pending_payload["identity"]),
	):
		return
	_applied_payload = _articulation.payload_snapshot()


func _capture_post_step_snapshot() -> void:
	var body_states: Array[Dictionary] = []
	var chassis := _bodies.get("chassis") as RigidBody3D
	var chassis_available := chassis != null and is_instance_valid(chassis) and chassis.is_inside_tree()
	if chassis_available:
		body_states.append({
			"name": "chassis",
			"transform": chassis.global_transform,
			"linear_velocity": chassis.linear_velocity,
			"angular_velocity": chassis.angular_velocity,
			"sleeping": chassis.sleeping,
		})
	var frame_states: Array[Dictionary] = []
	var frames := _articulation.accepted_frames()
	for frame_name in ["upper_structure_link", "boom_link", "arm_link", "bucket_link"]:
		if frames.has(frame_name):
			frame_states.append({"name": frame_name, "transform": frames[frame_name]})
	_post_step_snapshot = {
		"physics_tick": _physics_tick,
		"authority_epoch": _authority_epoch,
		"configured": configured,
		"enabled": enabled,
		"model_id": model_id,
		"body_transform": chassis.global_transform if chassis_available else Transform3D.IDENTITY,
		"linear_velocity": chassis.linear_velocity if chassis_available else Vector3.ZERO,
		"angular_velocity": chassis.angular_velocity if chassis_available else Vector3.ZERO,
		"sleeping": chassis.sleeping if chassis_available else false,
		"bodies": body_states,
		"kinematic_frames": frame_states,
		"joints": _articulation.joint_states(),
		"payload": _articulation.payload_snapshot(),
		"neutral_armed": _articulation.neutral_armed,
		"command_identity": _command_identity,
		"bucket_motion_sequence": _bucket_motion_sequence,
		"bucket_query": _bucket_query.duplicate(true),
		"cut_engagement": _cut_engagement,
		"assist_pipeline": _assist_pipeline.get_status_snapshot() if _assist_configured else {"configured": false},
		"queued_chassis_wrench": _queued_support_wrench.duplicate(true),
		"applied_chassis_wrench": _applied_support_wrench.duplicate(true),
		"support_wrench_apply_count": _support_wrench_apply_count,
		"bucket_ground_interaction": _bucket_ground_interaction_status(),
		"left_command": _left_command, "right_command": _right_command,
		"track_neutral_armed": _wheel_neutral_armed if uses_wheels() else _track_neutral_armed,
		"left_effort_n": _left_effort_n, "right_effort_n": _right_effort_n,
		"left_speed_mps": _left_speed_m_s, "right_speed_mps": _right_speed_m_s,
		"left_slip_ratio": _left_slip_ratio, "right_slip_ratio": _right_slip_ratio,
		"left_support_load_n": _left_support_load_n, "right_support_load_n": _right_support_load_n,
		"hull_terrain_collision_released": false,
		"hull_collision_switch_count": 0,
		"track_contact_model": "wheel_suspension_v1" if uses_wheels() else "swept_stations_v1",
		"locomotion_mode": "wheeled" if uses_wheels() else "tracked",
		"race_mode": race_mode,
		"race_assist": (
			(_race_wheel_solver.assist_telemetry if uses_wheels() else _race_track_solver.assist_telemetry)
			if race_mode else {}
		),
		"wheeled_locomotion": _wheel_snapshot.duplicate(true),
		"track_probes": _track_probes.duplicate(true),
		"track_rejections": _track_rejections.duplicate(true),
		"left_contact_count": _left_contact_count, "right_contact_count": _right_contact_count,
		"left_saturated": _left_saturated, "right_saturated": _right_saturated,
		"left_recovery_active": _left_recovery_active, "right_recovery_active": _right_recovery_active,
		"left_traction_floor_n": _left_traction_floor_n, "right_traction_floor_n": _right_traction_floor_n,
		"grounded": _left_contact_count + _right_contact_count > 0,
		"track_support_source_counts": _track_support_source_counts.duplicate(true),
		"terrain_generation": _terrain_identity.x, "terrain_revision": _terrain_identity.y,
		"terrain_identity_valid": _terrain_identity_valid,
		"contacts": _contacts.duplicate(true), "quality_flags": _quality_flags.duplicate(),
		"last_step_usec": _last_step_usec,
		"posture_error_rad": _posture_error_rad,
		"terrain_normal_alignment_deg": _terrain_normal_alignment_deg,
		"lowest_clearance_m": _lowest_clearance_m,
		"forward_speed_m_s": _forward_speed_m_s(),
		"local_forward_axis": String(_tracks.get("local_forward_axis", "-Z")),
		"vehicle_forward_world": _vehicle_forward_world(),
		"acceleration_time_s": _acceleration_time_s,
		"brake_stop_time_s": _brake_stop_time_s,
		"brake_stop_distance_m": _brake_stop_distance_m,
		"peak_pitch_angle_rad": _peak_pitch_angle_rad,
		"peak_pitch_rate_rad_s": _peak_pitch_rate_rad_s,
	}


func _collect_bucket_query_contacts() -> void:
	for contact_value in _bucket_query.get("contacts", []):
		var contact := contact_value as Dictionary
		_contacts.append({
			"body": "bucket_kinematic",
			"other": String(contact.get("collider_name", "terrain")),
			"point": contact.get("point_world", Vector3.ZERO),
			"normal": contact.get("normal_world", Vector3.UP),
			"impulse_n_s": 0.0,
			"penetration_m": float(contact.get("penetration_m", 0.0)),
			"proxy_role": String(contact.get("proxy_role", "")),
			"travel_fraction": float(contact.get("travel_fraction", 1.0)),
			"support_source": String(contact.get("query_source", "unknown")),
		})


func _destroy_rig() -> void:
	_wheel_colliders.clear()
	_joints.clear()
	for body_value in _bodies.values():
		var body := body_value as RigidBody3D
		if not is_instance_valid(body):
			continue
		body.linear_velocity = Vector3.ZERO
		body.angular_velocity = Vector3.ZERO
		body.collision_layer = 0
		body.collision_mask = 0
		body.freeze = true
		if body.is_inside_tree():
			body.queue_free()
		else:
			body.free()
	_bodies.clear()
	_body = null
	_articulation.reset()
	_bucket_sweeper.reset()
	_soil_contract.clear()
	_cut_engagement = 0.0
	_bucket_query.clear()
	_queued_support_wrench.clear()
	_applied_support_wrench.clear()
	_reset_support_response(true)


func _set_invalid_bucket_query(
	reason: String,
	previous_bucket := Transform3D.IDENTITY,
	candidate_bucket := Transform3D.IDENTITY
) -> void:
	var frames := _articulation.accepted_frames()
	var accepted_bucket := frames.get("bucket_link", previous_bucket) as Transform3D
	_bucket_query = {
		"valid": false,
		"accepted_fraction": 1.0,
		"authority_epoch": _authority_epoch,
		"physics_tick": _physics_tick,
		"motion_sequence": _bucket_motion_sequence,
		"terrain_generation": _terrain_identity.x,
		"terrain_revision": _terrain_identity.y,
		"previous_bucket_transform": previous_bucket if previous_bucket != Transform3D.IDENTITY else accepted_bucket,
		"candidate_bucket_transform": candidate_bucket if candidate_bucket != Transform3D.IDENTITY else accepted_bucket,
		"accepted_bucket_transform": accepted_bucket,
		"contacts": [],
		"quality_flags": [reason],
	}


func _apply_solid_contact_response(response: Dictionary, contacts: Array) -> void:
	if not enabled or _bucket_ground_bypassed() or not has_body():
		return
	var request_id := "%s:%d:%d" % [_authority_epoch, _physics_tick, _bucket_motion_sequence]
	if request_id == _last_applied_support_request_id:
		return
	var force: Vector3 = response["force"]
	var torque: Vector3 = response["torque"]
	if not force.is_finite() or not torque.is_finite():
		_quality_flags.append("solid_contact_invalid_response")
		return
	_support_contact_ticks += 1
	_body.apply_central_force(force)
	_body.apply_torque(torque)
	for value in response["forces"]:
		var reaction := value as Dictionary
		var other := instance_from_id(int(reaction["collider_id"])) as RigidBody3D
		if other != null and not other.freeze and other.get_rid() == reaction["rid"]:
			var opposite: Vector3 = -reaction["force"]
			var lever: Vector3 = reaction["point"] - _solid_contacts.center_of_mass_world(other)
			other.apply_central_force(opposite)
			other.apply_torque(lever.cross(opposite))
	var contact := contacts[0] as Dictionary
	_applied_support_wrench = {
		"request_id": request_id, "authority_epoch": _authority_epoch, "model_id": model_id,
		"source_physics_tick": _physics_tick, "eligible_apply_tick": _physics_tick,
		"expiry_tick": _physics_tick, "applied_physics_tick": _physics_tick,
		"terrain_generation": _terrain_identity.x, "terrain_revision": _terrain_identity.y,
		"point_world": contact["point_world"], "normal_world": contact["normal_world"],
		"blocked_distance_m": contact["penetration_m"], "classification": "support",
		"applied_force": force, "applied_torque": torque, "support_contact_ticks": _support_contact_ticks,
	}
	_last_applied_support_request_id = request_id
	_support_wrench_apply_count += 1
	_support_applied_count += 1


func _reset_support_response(clear_request_identity := false) -> void:
	_support_contact_ticks = 0
	if clear_request_identity:
		_last_applied_support_request_id = ""
		_previous_solid_world = Transform3D.IDENTITY
		_previous_solid_tool_mount = _solid_tool_mount


func _apply_track_forces() -> void:
	if uses_wheels():
		_apply_wheel_forces()
		return
	if not is_inside_tree() or get_world_3d() == null:
		_quality_flags.append("physics_space_unavailable")
		return
	var solver := _race_track_solver if race_mode else _track_solver
	var result: Dictionary = solver.step(
		_body, Vector2(_left_command, _right_command), _last_fixed_delta_s,
		_layer_mask(int(_descriptor["collision_layers"]["terrain"])),
		Callable(self, "_accept_track_support_hit")
	)
	var left: Dictionary = result["left"]
	var right: Dictionary = result["right"]
	_left_contact_count = int(left["contact_count"])
	_right_contact_count = int(right["contact_count"])
	_left_speed_m_s = float(left["speed_m_s"])
	_right_speed_m_s = float(right["speed_m_s"])
	_left_slip_ratio = float(left["slip_ratio"])
	_right_slip_ratio = float(right["slip_ratio"])
	_left_support_load_n = float(left["support_load_n"])
	_right_support_load_n = float(right["support_load_n"])
	_left_effort_n = float(left["effort_n"])
	_right_effort_n = float(right["effort_n"])
	_left_saturated = bool(left["saturated"])
	_right_saturated = bool(right["saturated"])
	_left_recovery_active = bool(left.get("recovery_active", false))
	_right_recovery_active = bool(right.get("recovery_active", false))
	_left_traction_floor_n = float(left.get("traction_floor_n", 0.0))
	_right_traction_floor_n = float(right.get("traction_floor_n", 0.0))
	_contacts.assign(result["contacts"])
	_track_support_source_counts = result["sources"]
	_track_probes = result["probes"]
	_track_rejections = result["rejections"]


func _accept_track_support_hit(hit: Dictionary) -> Dictionary:
	var collider: Variant = hit.get("collider")
	if collider is Node:
		var voxel_owner := _find_voxel_support_owner(collider as Node)
		if voxel_owner != null:
			if not bool(voxel_owner.call("is_support_ready_at", hit["position"])):
				return {}
			hit["support_source"] = "voxel_terrain"
			return hit
	if is_instance_valid(_static_map_root):
		var map_ground := _static_map_root.get_node_or_null("Ground") as Terrain3D
		if map_ground != null and map_ground.collision != null and hit.get("rid", RID()) == map_ground.collision.get_rid():
			hit["collider"] = map_ground
			hit["support_source"] = "static_map"
			return hit
		if collider is Node and (_static_map_root == collider or _static_map_root.is_ancestor_of(collider)):
			hit["support_source"] = "static_map"
			return hit
		return {}
	if collider is Node and _terrain_collider != null and _terrain_collider.is_ancestor_of(collider as Node):
		hit["support_source"] = "terrain_collider"
		return hit
	return {}


func _find_voxel_support_owner(collider: Node) -> Node:
	var current: Node = collider
	while current != null:
		if current.is_class("VoxelTerrain"):
			var owner := current.get_parent()
			return owner if owner != null and owner.has_method("is_support_ready_at") else null
		current = current.get_parent()
	return null


func _sample_heightfield_clamped(state: TerrainState, world_xz: Vector2) -> float:
	var maximum := state.origin_xz + Vector2(
		float(state.columns - 1) * state.spacing_m,
		float(state.rows - 1) * state.spacing_m
	)
	var clamped_xz := Vector2(
		clampf(world_xz.x, state.origin_xz.x, maximum.x),
		clampf(world_xz.y, state.origin_xz.y, maximum.y)
	)
	return state.sample_surface_bilinear_at(clamped_xz)


func _update_terrain_identity() -> void:
	_terrain_identity_valid = false
	if is_instance_valid(_static_map_root):
		_terrain_identity = Vector2i(0, 0)
		_terrain_identity_valid = _static_map_root.is_inside_tree()
		return
	if _terrain_world == null or _terrain_world.terrain_state == null or _terrain_collider == null:
		_terrain_identity = Vector2i(-1, -1)
		return
	_terrain_identity = Vector2i(_terrain_world.terrain_state.world_generation, _terrain_world.terrain_state.terrain_revision)
	_terrain_identity_valid = _terrain_collider.available and _terrain_collider.get_applied_identity() == _terrain_identity


func _clamp_body_velocities() -> void:
	if _body == null:
		return
	if not _body.linear_velocity.is_finite():
		_body.linear_velocity = Vector3.ZERO
		_quality_flags.append("invalid_linear_velocity_cleared")
	if not _body.angular_velocity.is_finite():
		_body.angular_velocity = Vector3.ZERO
		_quality_flags.append("invalid_angular_velocity_cleared")
	var max_linear := float(_dynamics["max_linear_speed_m_s"])
	var max_angular := float(_dynamics["max_angular_speed_rad_s"])
	if _body.linear_velocity.length() > max_linear:
		_body.linear_velocity = _body.linear_velocity.normalized() * max_linear
		_quality_flags.append("linear_speed_clamped")
	if _body.angular_velocity.length() > max_angular:
		_body.angular_velocity = _body.angular_velocity.normalized() * max_angular
		_quality_flags.append("angular_speed_clamped")


func _clamp_body_velocity() -> void:
	# Phase 1 test seam retained for the single dynamic chassis.
	_clamp_body_velocities()
	_capture_post_step_snapshot()


func _clear_tick_telemetry() -> void:
	if uses_wheels():
		_left_effort_n = 0.0
		_right_effort_n = 0.0
	_left_contact_count = 0
	_right_contact_count = 0
	_left_speed_m_s = 0.0
	_right_speed_m_s = 0.0
	_left_slip_ratio = 0.0
	_right_slip_ratio = 0.0
	_left_support_load_n = 0.0
	_right_support_load_n = 0.0
	_left_saturated = false
	_right_saturated = false
	_left_recovery_active = false
	_right_recovery_active = false
	_left_traction_floor_n = 0.0
	_right_traction_floor_n = 0.0
	_contacts.clear()
	_quality_flags.clear()
	_track_support_source_counts.clear()
	_track_probes.clear()
	_track_rejections.clear()


func _reset_response_telemetry() -> void:
	_wheel_neutral_armed = false
	_wheel_command = Vector3.ZERO
	_wheel_drift = 0.0
	_wheel_solver.reset()
	_race_wheel_solver.reset()
	_wheel_snapshot.clear()
	_track_neutral_armed = false
	_track_solver.reset()
	_race_track_solver.reset()
	_left_effort_n = 0.0
	_right_effort_n = 0.0
	_posture_error_rad = 0.0
	_terrain_normal_alignment_deg = 0.0
	_lowest_clearance_m = 0.0
	_acceleration_elapsed_s = 0.0
	_acceleration_time_s = -1.0
	_acceleration_direction = 0.0
	_brake_elapsed_s = 0.0
	_brake_stop_time_s = -1.0
	_brake_stop_distance_m = 0.0
	_brake_start_position = _body.global_position if _body != null and is_instance_valid(_body) and _body.is_inside_tree() else Vector3.ZERO
	_brake_was_active = false
	_peak_pitch_angle_rad = 0.0
	_peak_pitch_rate_rad_s = 0.0


func _forward_speed_m_s() -> float:
	if _body == null or not is_instance_valid(_body) or not _body.is_inside_tree():
		return 0.0
	return _body.linear_velocity.dot(_vehicle_forward_world())


func _local_forward_sign() -> float:
	return 1.0 if String(_tracks.get("local_forward_axis", "-Z")) == "+Z" else -1.0


func _vehicle_forward_world() -> Vector3:
	if _body == null or not is_instance_valid(_body) or not _body.is_inside_tree():
		return Vector3.FORWARD
	return (_body.global_basis.z * _local_forward_sign()).normalized()


func _vehicle_right_world() -> Vector3:
	if _body == null or not is_instance_valid(_body) or not _body.is_inside_tree():
		return Vector3.RIGHT
	return _vehicle_forward_world().cross(_body.global_basis.y.normalized()).normalized()


func _update_response_telemetry(delta: float) -> void:
	if _body == null or not is_instance_valid(_body) or not _body.is_inside_tree():
		return
	var forward_speed := _forward_speed_m_s()
	var command_axis := 0.5 * (_left_command + _right_command)
	var straight_command := _left_command * _right_command > 0.0 and absf(_left_command - _right_command) <= 0.1
	if straight_command and absf(command_axis) > 0.05:
		var direction := signf(command_axis)
		if not is_equal_approx(direction, _acceleration_direction):
			_acceleration_direction = direction
			_acceleration_elapsed_s = 0.0
			_acceleration_time_s = -1.0
		if _acceleration_time_s < 0.0:
			_acceleration_elapsed_s += delta
			var target_speed := absf(command_axis) * float(_tracks.get("max_belt_speed_m_s", 0.0))
			if forward_speed * direction >= target_speed * 0.65:
				_acceleration_time_s = _acceleration_elapsed_s
	else:
		_acceleration_elapsed_s = 0.0
		_acceleration_direction = 0.0
	var neutral_command := is_zero_approx(_left_command) and is_zero_approx(_right_command)
	var braking := neutral_command and absf(forward_speed) > 0.05
	if braking and not _brake_was_active:
		_brake_start_position = _body.global_position
		_brake_elapsed_s = 0.0
		_brake_stop_time_s = -1.0
		_brake_stop_distance_m = 0.0
		_brake_was_active = true
	if _brake_was_active:
		_brake_elapsed_s += delta
		_brake_stop_distance_m = _body.global_position.distance_to(_brake_start_position)
		if neutral_command and absf(forward_speed) <= 0.05:
			_brake_stop_time_s = _brake_elapsed_s
			_brake_was_active = false
		elif not neutral_command:
			_brake_was_active = false
	var terrain_normal := _sample_terrain_normal()
	if terrain_normal.length_squared() > 0.5:
		_posture_error_rad = _body.global_basis.y.normalized().angle_to(terrain_normal)
		_terrain_normal_alignment_deg = rad_to_deg(_posture_error_rad)
		_lowest_clearance_m = _lowest_shape_clearance()
	var forward := _vehicle_forward_world()
	var pitch_angle := atan2(forward.y, maxf(Vector2(forward.x, forward.z).length(), 0.001))
	var pitch_rate := absf(_body.angular_velocity.dot(_body.global_basis.x))
	_peak_pitch_angle_rad = maxf(_peak_pitch_angle_rad, absf(pitch_angle))
	_peak_pitch_rate_rad_s = maxf(_peak_pitch_rate_rad_s, pitch_rate)


func _sample_terrain_normal() -> Vector3:
	if _terrain_world == null or _terrain_world.terrain_state == null:
		return Vector3.UP
	var state := _terrain_world.terrain_state
	var p := Vector2(_body.global_position.x, _body.global_position.z)
	if not state.is_inside_grid(p):
		return Vector3.UP
	var spacing := state.spacing_m
	var left_height := _sample_heightfield_clamped(state, p - Vector2(spacing, 0.0))
	var right_height := _sample_heightfield_clamped(state, p + Vector2(spacing, 0.0))
	var rear_height := _sample_heightfield_clamped(state, p - Vector2(0.0, spacing))
	var front_height := _sample_heightfield_clamped(state, p + Vector2(0.0, spacing))
	return Vector3((left_height - right_height) / (2.0 * spacing), 1.0, (rear_height - front_height) / (2.0 * spacing)).normalized()


func _lowest_shape_clearance() -> float:
	if _body == null or not is_instance_valid(_body) or _terrain_world == null:
		return 0.0
	var state := _terrain_world.terrain_state
	var lowest := INF
	for shape_value in _dynamics.get("compound_shapes", []):
		var shape := shape_value as Dictionary
		var center := _vector3(shape.get("center_m", [0.0, 0.0, 0.0]))
		var half := 0.5 * _vector3(shape.get("size_m", [1.0, 1.0, 1.0]))
		for sx in [-1.0, 1.0]:
			for sy in [-1.0, 1.0]:
				for sz in [-1.0, 1.0]:
					var point_world := _body.global_transform * (center + Vector3(sx * half.x, sy * half.y, sz * half.z))
					var ground := state.sample_surface_bilinear_at(Vector2(point_world.x, point_world.z))
					if is_finite(ground):
						lowest = minf(lowest, point_world.y - ground)
	return 0.0 if is_inf(lowest) else lowest


func _empty_snapshot() -> Dictionary:
	return {
		"physics_tick": _physics_tick,
		"authority_epoch": _authority_epoch,
		"body_transform": Transform3D.IDENTITY,
		"linear_velocity": Vector3.ZERO,
		"angular_velocity": Vector3.ZERO,
		"sleeping": false,
		"bodies": [],
		"kinematic_frames": [],
		"joints": [],
		"payload": _articulation.payload_snapshot(),
		"neutral_armed": false,
		"track_neutral_armed": false,
		"left_effort_n": 0.0,
		"right_effort_n": 0.0,
		"bucket_query": {},
		"cut_engagement": 0.0,
		"queued_chassis_wrench": {},
		"applied_chassis_wrench": {},
		"support_wrench_apply_count": 0,
		"bucket_ground_interaction": _bucket_ground_interaction_status(),
		"left_support_load_n": 0.0,
		"right_support_load_n": 0.0,
		"left_recovery_active": false, "right_recovery_active": false,
		"left_traction_floor_n": 0.0, "right_traction_floor_n": 0.0,
		"posture_error_rad": 0.0,
		"terrain_normal_alignment_deg": 0.0,
		"lowest_clearance_m": 0.0,
		"forward_speed_m_s": 0.0,
		"local_forward_axis": "-Z",
		"vehicle_forward_world": Vector3.FORWARD,
		"acceleration_time_s": -1.0,
		"brake_stop_time_s": -1.0,
		"brake_stop_distance_m": 0.0,
		"peak_pitch_angle_rad": 0.0,
		"peak_pitch_rate_rad_s": 0.0,
		"contacts": [],
		"track_support_source_counts": {},
		"quality_flags": ["authoritative_runtime_unavailable"],
	}


func _bucket_ground_bypassed() -> bool:
	return BucketGroundInteractionMode.is_passthrough(_bucket_ground_mode)


func _bucket_ground_interaction_status() -> Dictionary:
	return {
		"mode": _bucket_ground_mode,
		"query_submitted": _bucket_query_submitted_count,
		"query_executed": _bucket_query_executed_count,
		"query_bypassed": _bucket_query_bypassed_count,
		"cut_probe_executed": _cut_probe_executed_count,
		"cut_probe_bypassed": _cut_probe_bypassed_count,
		"support_queued": _support_queued_count,
		"support_applied": _support_applied_count,
		"support_bypassed": _support_bypassed_count,
	}


func _reject(message: String) -> bool:
	contract_error = message
	configured = false
	enabled = false
	return false


func _load_soil_contract() -> Dictionary:
	var descriptor := SoilContractDescriptor.load_for_model(model_id)
	if descriptor == null or not descriptor.is_valid_for(model_id):
		contract_error = "soil_contract: %s" % (
			"descriptor_unavailable" if descriptor == null else descriptor.validation_error()
		)
		return {}
	return descriptor.to_dictionary()


func _rows_to_transform(value: Variant) -> Transform3D:
	var rows := value as Array
	return Transform3D(Basis(Vector3(float(rows[0][0]), float(rows[1][0]), float(rows[2][0])), Vector3(float(rows[0][1]), float(rows[1][1]), float(rows[2][1])), Vector3(float(rows[0][2]), float(rows[1][2]), float(rows[2][2]))), Vector3(float(rows[0][3]), float(rows[1][3]), float(rows[2][3])))


func _basis_with_z_axis(axis: Vector3) -> Basis:
	var z_axis := axis.normalized()
	var helper := Vector3.UP if absf(z_axis.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var x_axis := helper.cross(z_axis).normalized()
	return Basis(x_axis, z_axis.cross(x_axis).normalized(), z_axis)


func _vector3(value: Variant) -> Vector3:
	var data := value as Array
	return Vector3(float(data[0]), float(data[1]), float(data[2]))


func _finite_vector4(value: Vector4) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z) and is_finite(value.w)


func _layer_mask(layer_number: int) -> int:
	return 1 << (layer_number - 1)


func _add_wheel_collision_shapes(body: RigidBody3D) -> void:
	for hull: Dictionary in _wheel_profile.data.hulls:
		var node := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = WheeledMachineProfile.vec(hull.size_m)
		node.shape = shape
		node.position = WheeledMachineProfile.vec(hull.center_m)
		body.add_child(node)
	for station: Dictionary in _wheel_profile.stations:
		var node := CollisionShape3D.new()
		var shape := CylinderShape3D.new()
		# A small tire skin keeps the constraint hull from double-supporting a
		# ray-loaded tire on flat ground; the hull still blocks walls/large curbs.
		shape.radius = float(station.radius_m) - 0.025
		shape.height = float(_wheel_profile.data.collision_wheel_width_m)
		shape.margin = 0.005
		node.shape = shape
		node.position = station.mount - Vector3.UP * float(station.rest_suspension_length_m)
		node.basis = Basis(Vector3.BACK, PI * 0.5)
		body.add_child(node)
		_wheel_colliders.append(node)


func _apply_wheel_forces() -> void:
	var command := _wheel_command if enabled else Vector3(0, 1, 0)
	# Neutral holds a work machine through bounded service braking. Suspension
	# remains live while paused, so disabling input does not drop the chassis.
	var brake := maxf(command.y, 1.0 if absf(command.x) < 0.001 else 0.0)
	var solver: WheeledLocomotionState = _race_wheel_solver if race_mode else _wheel_solver
	solver.set_commands(command.x, brake, command.z)
	solver.set_drift(_wheel_drift)
	_wheel_snapshot = solver.step(_body, _last_fixed_delta_s,
		_layer_mask(int(_descriptor["collision_layers"]["terrain"])), Callable(self, "_accept_track_support_hit"))
	var samples: Array = _wheel_snapshot.get("wheels", [])
	for index in samples.size():
		var sample: Dictionary = samples[index]
		if index < _wheel_colliders.size():
			_wheel_colliders[index].position = sample.center_local
			_wheel_colliders[index].basis = Basis(Vector3.UP, -float(sample.steer_angle_rad)) * Basis(Vector3.BACK, PI * 0.5)
		if not sample.grounded:
			continue
		var left := (_wheel_profile.stations[index].mount as Vector3).x < 0.0
		var speed: float = _wheel_snapshot.get("speed_mps", 0.0)
		if left:
			_left_contact_count += 1
			_left_speed_m_s = speed
			_left_support_load_n += float(sample.load_n)
			_left_slip_ratio += float(sample.slip_ratio)
			_left_effort_n += float(sample.tire_force_n.x)
		else:
			_right_contact_count += 1
			_right_speed_m_s = speed
			_right_support_load_n += float(sample.load_n)
			_right_slip_ratio += float(sample.slip_ratio)
			_right_effort_n += float(sample.tire_force_n.x)
		var source := String(sample.support_source)
		_track_support_source_counts[source] = int(_track_support_source_counts.get(source, 0)) + 1
		_contacts.append({"body": "chassis", "other": sample.collider_name,
			"point": sample.point_world, "normal": sample.normal_world,
			"impulse_n_s": float(sample.load_n) * _last_fixed_delta_s, "penetration_m": 0.0,
			"wheel_index": index, "support_source": source})
	_left_slip_ratio /= maxi(_left_contact_count, 1)
	_right_slip_ratio /= maxi(_right_contact_count, 1)
