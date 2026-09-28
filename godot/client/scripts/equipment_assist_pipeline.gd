class_name EquipmentAssistPipeline
extends RefCounted

## Ordered command-shaping pipeline between the operator Vector4 and the
## articulation integrator. Each enabled stage gets a shared per-tick
## EquipmentKinematicsContext; modulator stages reshape channels they declare
## in writes_mask while governor stages attenuate channels through "scale".
## Two invariants are enforced here rather than in stages: a channel outside
## a stage's writes_mask can never be written by it, and no stage may produce
## non-zero motion while the operator input is zero unless it declares
## holds_at_neutral. Stage conflicts resolve by registration order.

const KCtx := preload("res://scripts/equipment_kinematics_context.gd")
const BucketLevelAssistStage := preload("res://scripts/bucket_level_assist.gd")
const SlopeGradeAssistStage := preload("res://scripts/slope_grade_assist.gd")

const PROFILE_PATH := "res://resources/physics/assist_profiles.json"
const SCHEMA_VERSION := "assist-profiles-v1"
const NEUTRAL_EPS := 0.0001
const CHANNEL_COUNT := 4

var configured := false
var model_id := ""
var last_error := ""

var _descriptor: Dictionary = {}
var _soil_contract: Dictionary = {}
var _tool_contract: Dictionary = {}
var _exterior_local: Array[Vector3] = []
var _tool_mount := Transform3D.IDENTITY
var _previous_tool_mount := Transform3D.IDENTITY
var _joint_descriptors: Dictionary = {}
var _body_frames: Dictionary = {}
var _stage_order: Array = []
var _stages: Dictionary = {}


func configure(descriptor: Dictionary, soil_contract: Dictionary, requested_model_id: String) -> bool:
	configured = false
	_stages.clear()
	_stage_order.clear()
	_descriptor = descriptor.duplicate(true)
	_soil_contract = soil_contract.duplicate(true)
	_tool_contract = _soil_contract
	_cache_exterior()
	_tool_mount = Transform3D.IDENTITY
	_previous_tool_mount = Transform3D.IDENTITY
	_joint_descriptors.clear()
	_body_frames.clear()
	for body_value in _descriptor.get("bodies", []):
		var body := body_value as Dictionary
		_body_frames[String(body.get("name", ""))] = String(body.get("frame", ""))
	for joint_value in _descriptor.get("joints", []):
		var joint := joint_value as Dictionary
		_joint_descriptors[String(joint.get("name", ""))] = joint.duplicate(true)
	if _joint_descriptors.is_empty() or _body_frames.is_empty():
		last_error = "assist pipeline requires the full rig descriptor"
		return false
	var params := _load_params(requested_model_id)
	if params.is_empty():
		return false
	var level := BucketLevelAssistStage.new() as EquipmentAssistStage
	if not level.configure(_descriptor, _soil_contract, params.get("bucket_level", {}) as Dictionary):
		last_error = "bucket_level assist rejected its profile"
		return false
	_stages[level.stage_name] = level
	_stage_order.append(level)
	var slope := SlopeGradeAssistStage.new() as EquipmentAssistStage
	if not slope.configure(_descriptor, _soil_contract, params.get("slope_grade", {}) as Dictionary):
		last_error = "slope_grade assist rejected its profile"
		return false
	_stages[slope.stage_name] = slope
	_stage_order.append(slope)
	model_id = requested_model_id
	configured = true
	last_error = ""
	return true


## Geometry follows the active mount, independently of the solid-contact solver.
func set_tool_geometry(contract: Dictionary) -> void:
	_tool_contract = contract.duplicate(true)
	_cache_exterior()
	_tool_mount = Transform3D.IDENTITY
	_previous_tool_mount = Transform3D.IDENTITY
	reset("tool_changed")


func _cache_exterior() -> void:
	_exterior_local.clear()
	var tool := BucketSoilTool.new()
	if not _tool_contract.is_empty() and tool.configure(_tool_contract):
		_exterior_local = tool.exterior_contact_points()


func set_tool_mount(mount: Transform3D, previous_mount: Variant = null) -> void:
	_tool_mount = mount
	_previous_tool_mount = previous_mount if previous_mount is Transform3D else mount


func reset(reason := "reset") -> void:
	for stage in _stage_order:
		(stage as EquipmentAssistStage).reset(reason)


func any_enabled() -> bool:
	for stage in _stage_order:
		if (stage as EquipmentAssistStage).enabled:
			return true
	return false


func set_stage_enabled(stage_name: String, value: bool) -> bool:
	var stage := _stages.get(stage_name) as EquipmentAssistStage
	if stage == null or not stage.configured:
		return false
	# Mutual exclusion: enabling a grouped stage switches off its siblings —
	# level and slope guidance cannot both own the work equipment.
	if value and not stage.exclusive_group.is_empty():
		for other_value in _stage_order:
			var other := other_value as EquipmentAssistStage
			if other != stage and other.exclusive_group == stage.exclusive_group:
				other.set_enabled(false)
	stage.set_enabled(value)
	return true


## Runtime parameter injection for stages whose task is parameterized after
## configure (the confirmed slope profile). Returns false when the stage is
## unknown or rejects the params.
func set_stage_params(stage_name: String, params: Dictionary) -> bool:
	var stage := _stages.get(stage_name) as EquipmentAssistStage
	if stage == null or not stage.configured:
		return false
	return stage.apply_params(params)


func is_stage_enabled(stage_name: String) -> bool:
	var stage := _stages.get(stage_name) as EquipmentAssistStage
	return stage != null and stage.enabled


func get_stage(stage_name: String) -> EquipmentAssistStage:
	return _stages.get(stage_name) as EquipmentAssistStage


## Transform one operator command sample. articulation supplies the accepted
## joint state and frames; external carries controller-pushed semantics for
## future stages (soil status, targets). Returns {"commands", "flags"}.
func step(
	commands: Vector4,
	articulation: KinematicArticulationState,
	chassis_transform: Transform3D,
	delta: float,
	external: Dictionary,
	chassis_linear_velocity := Vector3.ZERO,
	chassis_angular_velocity := Vector3.ZERO
) -> Dictionary:
	var flags: Array = []
	if not configured or not any_enabled() or articulation == null or not articulation.configured:
		return {"commands": commands, "flags": flags}
	var ctx := build_context(
		articulation, chassis_transform, delta, external,
		chassis_linear_velocity, chassis_angular_velocity
	)
	var current := commands
	var channel_scale := [1.0, 1.0, 1.0, 1.0]
	var claimed := 0
	for stage_value in _stage_order:
		var stage := stage_value as EquipmentAssistStage
		if not stage.enabled or not stage.configured:
			continue
		var usable_mask := stage.writes_mask & ~claimed
		if usable_mask != stage.writes_mask:
			flags.append("assist_channel_conflict:%s" % stage.stage_name)
		claimed |= stage.writes_mask
		var result := stage.step(ctx, current)
		var produced := result.get("commands", current) as Vector4
		current = _apply_masked(current, produced, usable_mask)
		var scale := float(result.get("scale", 1.0))
		if scale < 1.0:
			for index in CHANNEL_COUNT:
				if usable_mask & (1 << index):
					channel_scale[index] = minf(float(channel_scale[index]), clampf(scale, 0.0, 1.0))
		for flag in result.get("flags", []):
			flags.append(String(flag))
	for index in CHANNEL_COUNT:
		current[index] = clampf(current[index] * float(channel_scale[index]), -1.0, 1.0)
	if commands.length_squared() <= NEUTRAL_EPS * NEUTRAL_EPS and not _any_holds():
		if current.length_squared() > NEUTRAL_EPS * NEUTRAL_EPS:
			flags.append("assist_neutral_guard")
		current = Vector4.ZERO
	return {"commands": current, "flags": flags}


func build_context(
	articulation: KinematicArticulationState,
	chassis_transform: Transform3D,
	delta: float,
	external: Dictionary,
	chassis_linear_velocity := Vector3.ZERO,
	chassis_angular_velocity := Vector3.ZERO
) -> EquipmentKinematicsContext:
	var ctx := KCtx.new() as EquipmentKinematicsContext
	ctx.delta = delta
	ctx.chassis_transform = chassis_transform
	ctx.chassis_linear_velocity = chassis_linear_velocity
	ctx.chassis_angular_velocity = chassis_angular_velocity
	ctx.external = external
	ctx.cut_engagement = articulation.cut_engagement
	ctx.motion_load_factor = articulation.motion_load_factor
	var frames := articulation.frames_at_chassis(chassis_transform)
	for state_value in articulation.joint_states():
		var state := state_value as Dictionary
		var joint_name := String(state.get("name", ""))
		ctx.joint_positions[joint_name] = float(state.get("position_rad", 0.0))
		ctx.joint_velocities[joint_name] = float(state.get("velocity_rad_s", 0.0))
		ctx.joint_accelerations[joint_name] = float(state.get("acceleration_rad_s2", 0.0))
	for joint_name in _joint_descriptors:
		var joint := _joint_descriptors[joint_name] as Dictionary
		var parent_frame := frames.get(_parent_frame_name(joint), Transform3D.IDENTITY) as Transform3D
		var anchor_world := parent_frame * _rows_to_transform(joint.get("parent_anchor_godot", []))
		var axis := _vector3(joint.get("axis", [0.0, 0.0, 0.0]))
		ctx.joint_axis_world[joint_name] = (anchor_world.basis * axis).normalized()
		ctx.joint_pivot_world[joint_name] = anchor_world.origin
		var actuator := joint.get("actuator", {}) as Dictionary
		var load_factor := 1.0 if joint_name == "swing_joint" else ctx.motion_load_factor
		ctx.joint_ceiling[joint_name] = float(actuator.get("max_velocity_rad_s", 0.0)) * load_factor
		ctx.joint_accel_limits[joint_name] = Vector2(
			float(actuator.get("max_acceleration_rad_s2", 0.0)) * load_factor,
			float(actuator.get("max_jerk_rad_s3", 0.0)) * load_factor
		)
		if String(joint.get("type", "")) != "continuous_hinge":
			var limits := articulation.effective_joint_limits(joint_name)
			if limits.size() == 2:
				ctx.joint_limits[joint_name] = Vector2(float(limits[0]), float(limits[1]))
	ctx.bucket_link = (frames.get("bucket_link", Transform3D.IDENTITY) as Transform3D) * _tool_mount
	var edge := (_tool_contract.get("proxies", {}) as Dictionary).get("cutting_edge", {}) as Dictionary
	var ref_local := _vector3(edge.get("center_godot", [0.0, 0.0, 0.0]))
	var dir_local := _vector3(edge.get("direction_godot", [0.0, 0.0, -1.0]))
	ctx.cutting_edge_available = not edge.is_empty()
	var half_edge := Vector3.RIGHT * float(edge.get("half_width_m", 0.0))
	# Relaxed guidance follows the same outer tooth segment used by cutting,
	# not the radius center, whose offset rotates when pitch is released.
	var relaxed := false
	for stage in _stage_order:
		if stage.enabled and stage.relaxed_attitude:
			relaxed = true
	if relaxed:
		ctx.cutting_edge_available = ctx.cutting_edge_available and not _exterior_local.is_empty()
		for region in (_tool_contract.get("bucket_tool", {}) as Dictionary).get("regions", []):
			var shape := (region as Dictionary).get("shape", {}) as Dictionary
			if String(region.get("kind", "")) != "teeth" or String(shape.get("kind", "")) != "segment":
				continue
			var outward := _vector3(region.get("outward_normal_godot", [0.0, 0.0, -1.0])).normalized()
			ref_local = _vector3(region.get("center_godot", [0.0, 0.0, 0.0])) + outward * float(shape.get("radius_m", 0.0))
			half_edge = _vector3(shape.get("axis_godot", [1.0, 0.0, 0.0])).normalized() * float(shape.get("half_length_m", 0.0))
			break
	ctx.bucket_edge_half_world = ctx.bucket_link.basis * half_edge
	ctx.bucket_ref_world = ctx.bucket_link * ref_local
	if relaxed:
		var host := frames.get("bucket_link", Transform3D.IDENTITY) as Transform3D
		for point in _exterior_local:
			ctx.exterior_points.append(ctx.bucket_link * point)
			ctx.exterior_mount_velocities.append(host.basis * ((_tool_mount * point) - (_previous_tool_mount * point)) / delta if delta > 0.0 else Vector3.ZERO)
	if delta > 0.0:
		var host := frames.get("bucket_link", Transform3D.IDENTITY) as Transform3D
		ctx.tool_point_velocity = host.basis * ((_tool_mount * ref_local) - (_previous_tool_mount * ref_local)) / delta
	ctx.bucket_ref_dir_world = (ctx.bucket_link.basis * dir_local).normalized()
	ctx.hinge_normal = ctx.joint_axis_world.get("bucket_joint", Vector3.RIGHT) as Vector3
	var flat := ctx.up.cross(ctx.hinge_normal)
	if flat.length() < 0.001:
		flat = ctx.chassis_transform.basis.z
	ctx.horizontal = flat.normalized()
	var outward := ctx.bucket_ref_world - Vector3(ctx.joint_pivot_world.get("swing_joint", ctx.chassis_transform.origin))
	outward.y = 0.0
	if outward.length_squared() > 0.0001 and ctx.horizontal.dot(outward) < 0.0:
		ctx.horizontal = -ctx.horizontal
	return ctx


func get_status_snapshot() -> Dictionary:
	var stages := {}
	for stage_value in _stage_order:
		var stage := stage_value as EquipmentAssistStage
		stages[stage.stage_name] = stage.get_status_snapshot()
	return {
		"configured": configured,
		"model_id": model_id,
		"last_error": last_error,
		"stages": stages,
	}


func _any_holds() -> bool:
	for stage_value in _stage_order:
		var stage := stage_value as EquipmentAssistStage
		if stage.enabled and stage.holds_at_neutral:
			return true
	return false


func _apply_masked(input: Vector4, produced: Vector4, mask: int) -> Vector4:
	var result := input
	for index in CHANNEL_COUNT:
		if mask & (1 << index):
			result[index] = produced[index]
	return result


func _parent_frame_name(joint: Dictionary) -> String:
	return String(_body_frames.get(String(joint.get("parent_body", "")), ""))


func _load_params(requested_model_id: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PROFILE_PATH))
	if not parsed is Dictionary:
		last_error = "assist profile is unavailable"
		return {}
	var root := parsed as Dictionary
	if String(root.get("schema_version", "")) != SCHEMA_VERSION:
		last_error = "assist profile schema mismatch"
		return {}
	var models := root.get("models", {}) as Dictionary
	var entry: Variant = models.get(requested_model_id, models.get("default"))
	if not entry is Dictionary:
		last_error = "assist profile has no entry for %s" % requested_model_id
		return {}
	return entry as Dictionary


func _rows_to_transform(value: Variant) -> Transform3D:
	var rows := value as Array
	if rows == null or rows.size() != 4:
		return Transform3D.IDENTITY
	return Transform3D(
		Basis(
			Vector3(float(rows[0][0]), float(rows[1][0]), float(rows[2][0])),
			Vector3(float(rows[0][1]), float(rows[1][1]), float(rows[2][1])),
			Vector3(float(rows[0][2]), float(rows[1][2]), float(rows[2][2])),
		),
		Vector3(float(rows[0][3]), float(rows[1][3]), float(rows[2][3])),
	)


func _vector3(value: Variant) -> Vector3:
	var data := value as Array
	if data == null or data.size() != 3:
		return Vector3.ZERO
	return Vector3(float(data[0]), float(data[1]), float(data[2]))
