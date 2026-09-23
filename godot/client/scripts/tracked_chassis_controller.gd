class_name TrackedChassisController
extends Node3D

const MODEL_CATALOG_PATH := "res://resources/models/model_catalog.json"
const INPUT_ACTIONS := {
	"track_left_forward": {"key": KEY_R, "joy_axis": JOY_AXIS_TRIGGER_LEFT, "joy_sign": 1.0},
	"track_left_reverse": {"key": KEY_F, "joy_button": JOY_BUTTON_LEFT_SHOULDER},
	"track_right_forward": {"key": KEY_Y, "joy_axis": JOY_AXIS_TRIGGER_RIGHT, "joy_sign": 1.0},
	"track_right_reverse": {"key": KEY_H, "joy_button": JOY_BUTTON_RIGHT_SHOULDER},
}
const TOGGLE_ACTIONS := {
	"operator_assist": [KEY_T],
}
const SlopePreviewVisual := preload("res://scripts/slope_cut_preview_visual.gd")

enum {
	SLOPE_MODE_OFF,
	SLOPE_MODE_PREVIEW,
	SLOPE_MODE_ACTIVE,
}
const SLOPE_DISTANCE_MIN_M := -20.0
const SLOPE_DISTANCE_MAX_M := 20.0
const SLOPE_ANGLE_MIN_DEG := -60.0
const SLOPE_ANGLE_MAX_DEG := 60.0
const SLOPE_PREVIEW_REFRESH_S := 0.15
const ASSIST_MENU_ENTRIES := [
	{"id": "level", "label": "平地辅助"},
	{"id": "slope", "label": "修坡辅助"},
]
const MENU_NAV_THRESHOLD := 0.5

@export var controller_enabled := false
@export var static_map_driving := false
@export var map_spawn_position := Vector3.ZERO
@export var map_spawn_yaw_rad := 0.0
@export_enum("python_kinematic", "jolt_shadow", "jolt_authoritative") var authority_profile := AuthorityProfile.JOLT_AUTHORITATIVE
@export var use_project_authority_profile := true
@export var ground_lift_enabled := true
@export var use_jolt_support_hints := true
@export var digging_response_enabled := true
@export var level_assist_enabled := false
@export var jolt_probe_height_m := 4.0
@export var jolt_hint_max_error_m := 0.2
@export_flags_3d_physics var terrain_collision_mask := 1
@export var motion_client_path := NodePath("../MotionClient")
@export var product_session_path := NodePath("../ProductSession")
@export var motion_presentation_path := NodePath("../MotionPresentation")
@export var terrain_world_path := NodePath("../TerrainRoot/TerrainWorld")
@export var terrain_collider_path := NodePath("../TerrainRoot/TerrainCollider")
@export var excavation_world_path := NodePath("../TerrainRoot/ExcavationWorld")

var locomotion_state := TrackedLocomotionState.new()
var ground_lift_reaction := BucketGroundLiftReaction.new()
var active_model_id := ""
var contract_error := ""
var _motion_client: MotionClient
var _product_session: ProductSession
var _motion_presentation: MotionPresentation
var _terrain_world: TerrainWorld
var _terrain_collider: TerrainCollider
var _excavation_world: ExcavationWorld
var _input_focused := true
var _jolt_hint_status := "unavailable"
var _base_local_transform := Transform3D.IDENTITY
var _jolt_runtime: JoltChassisTrackRuntime
var _use_test_commands := false
var _test_commands := Vector2.ZERO
var _test_wheel_commands := Vector4.ZERO
var _use_test_wheel_commands := false
var _use_test_equipment_commands := false
var _test_equipment_commands := Vector4.ZERO
var _test_input_focus_bypass := false
var _payload_identity := -1
var _last_payload_sample: Dictionary = {}
var _digging_response := DiggingResponseShaper.new()
var _bucket_ground_mode := BucketGroundInteractionMode.NORMAL
var _slope_mode := SLOPE_MODE_OFF
var _slope_distance_m := 3.0
var _slope_angle_deg := 30.0
var _slope_profile: RefCounted = null
var _slope_preview_result: Dictionary = {}
var _slope_preview_dirty := true
var _slope_preview_accum := 0.0
var _slope_preview_node: SlopePreviewVisual = null
var _assist_view_cache: Dictionary = {}
var _assist_menu_open := false
var _assist_menu_index := 0
var _menu_nav_axis := 0.0
var race_mode_enabled := false


func _ready() -> void:
	process_physics_priority = -20
	if use_project_authority_profile:
		authority_profile = String(ProjectSettings.get_setting("simulation/authority_profile", authority_profile))
	if not AuthorityProfile.is_valid(authority_profile):
		contract_error = "unknown authority profile: %s" % authority_profile
		set_physics_process(false)
		push_error(contract_error)
		return
	if AuthorityProfile.writes_product_pose(authority_profile):
		controller_enabled = true
	_ensure_input_actions()
	call_deferred("_connect_runtime")


func _physics_process(delta: float) -> void:
	if AuthorityProfile.writes_product_pose(authority_profile):
		_step_authoritative_chassis(delta)
		return
	if not controller_enabled or not locomotion_state.configured or _terrain_world == null:
		return
	var left := 0.0
	var right := 0.0
	if _input_focused:
		left = Input.get_action_strength("track_left_forward") - Input.get_action_strength("track_left_reverse")
		right = Input.get_action_strength("track_right_forward") - Input.get_action_strength("track_right_reverse")
	locomotion_state.set_commands(left, right)
	locomotion_state.step_fixed(delta, Callable(self, "_sample_terrain_height"))
	_base_local_transform = locomotion_state.chassis_transform
	ground_lift_reaction.enabled = ground_lift_enabled and not _bucket_ground_bypassed()
	if not ground_lift_reaction.enabled:
		ground_lift_reaction.clear_target()
	transform = _base_local_transform * ground_lift_reaction.step_fixed(delta)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_input_focused = false
		locomotion_state.stop_motion()
		if _jolt_runtime != null:
			_jolt_runtime.stop_motion()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_input_focused = true


func _exit_tree() -> void:
	var parent := get_parent()
	if parent != null and parent.is_queued_for_deletion():
		_jolt_runtime = null
		return
	if _jolt_runtime != null and is_instance_valid(_jolt_runtime) and not _jolt_runtime.is_inside_tree():
		_jolt_runtime.retire_deferred()
		_jolt_runtime = null
		return
	_destroy_jolt_runtime()


func set_controller_enabled(value: bool) -> void:
	controller_enabled = value
	if not value:
		if AuthorityProfile.writes_product_pose(authority_profile):
			if _jolt_runtime != null:
				_jolt_runtime.set_enabled(false)
		else:
			_reset_motion()


func set_race_mode(value: bool) -> void:
	race_mode_enabled = value
	if _jolt_runtime != null:
		_jolt_runtime.set_race_mode(value)


func set_product_session_state(running: bool, focused: bool) -> void:
	if AuthorityProfile.writes_product_pose(authority_profile):
		controller_enabled = running
	_input_focused = focused
	if not running or not focused:
		stop_product_motion()


func stop_product_motion() -> void:
	locomotion_state.stop_motion()
	_test_commands = Vector2.ZERO
	_test_equipment_commands = Vector4.ZERO
	_digging_response.reset_response("stop_motion")
	if _jolt_runtime != null:
		_jolt_runtime.stop_motion()
		_jolt_runtime.set_commands(0.0, 0.0)
		_jolt_runtime.set_equipment_commands(Vector4.ZERO, Engine.get_physics_frames())


func configure_model_for_test(model_id: String) -> bool:
	if active_model_id == model_id and contract_error.is_empty():
		if AuthorityProfile.writes_product_pose(authority_profile):
			if _jolt_runtime != null and _jolt_runtime.configured:
				return true
		elif locomotion_state.configured:
			return true
	return _configure_model(model_id)


func set_commands_for_test(left: float, right: float) -> void:
	_use_test_commands = true
	_test_commands = Vector2(
		clampf(left, -1.0, 1.0) if is_finite(left) else 0.0,
		clampf(right, -1.0, 1.0) if is_finite(right) else 0.0
	)
	locomotion_state.set_commands(left, right)
	if _jolt_runtime != null:
		_jolt_runtime.set_commands(_test_commands.x, _test_commands.y)


func set_wheeled_commands_for_test(throttle: float, brake: float, steer: float, drift := 0.0) -> void:
	_use_test_wheel_commands = true
	_test_wheel_commands = Vector4(throttle, brake, steer, drift)


func clear_commands_for_test() -> void:
	_use_test_wheel_commands = false
	_test_wheel_commands = Vector4.ZERO
	_use_test_commands = false
	_test_commands = Vector2.ZERO
	locomotion_state.set_commands(0.0, 0.0)
	if _jolt_runtime != null:
		_jolt_runtime.set_commands(0.0, 0.0)


func set_equipment_commands_for_test(commands: Vector4) -> void:
	_use_test_equipment_commands = true
	_test_equipment_commands = commands if commands.is_finite() else Vector4.ZERO
	if _jolt_runtime != null:
		_jolt_runtime.set_equipment_commands(_test_equipment_commands)


func set_test_input_focus_bypass_for_test(enabled: bool) -> void:
	_test_input_focus_bypass = enabled
	if not enabled and not _input_focused and _jolt_runtime != null:
		_jolt_runtime.stop_motion()


func clear_equipment_commands_for_test() -> void:
	_use_test_equipment_commands = false
	_test_equipment_commands = Vector4.ZERO
	_payload_identity = -1
	_last_payload_sample.clear()
	if _jolt_runtime != null:
		_jolt_runtime.set_equipment_commands(Vector4.ZERO)


func step_fixed_for_test(delta: float, height_sampler: Callable) -> bool:
	var changed := locomotion_state.step_fixed(delta, height_sampler)
	_base_local_transform = locomotion_state.chassis_transform
	ground_lift_reaction.enabled = ground_lift_enabled and not _bucket_ground_bypassed()
	if not ground_lift_reaction.enabled:
		ground_lift_reaction.clear_target()
	transform = _base_local_transform * ground_lift_reaction.step_fixed(delta)
	return changed


func submit_bucket_support_contact(contact: Dictionary) -> void:
	if AuthorityProfile.writes_product_pose(authority_profile) or _bucket_ground_bypassed():
		ground_lift_reaction.reset()
		return
	ground_lift_reaction.enabled = ground_lift_enabled
	ground_lift_reaction.submit_contact(contact, _base_global_transform())


func clear_bucket_support_contact() -> void:
	if AuthorityProfile.writes_product_pose(authority_profile) or _bucket_ground_bypassed():
		ground_lift_reaction.reset()
		return
	ground_lift_reaction.submit_contact({}, _base_global_transform())


func raw_world_transform(world_transform: Transform3D) -> Transform3D:
	var effective_global := global_transform
	var base_global := _base_global_transform()
	return base_global * effective_global.affine_inverse() * world_transform


func reset_for_test() -> void:
	_reset_motion()


func sample_terrain_height_for_test(world_xz: Vector2) -> float:
	return _sample_terrain_height(world_xz)


func get_collision_layers() -> Dictionary:
	return _jolt_runtime.collision_layers_snapshot() if _jolt_runtime != null else {}


func get_status_snapshot() -> Dictionary:
	var status := (
		(
			_jolt_runtime.get_status_snapshot()
			if _jolt_runtime != null
			else _empty_authoritative_status()
		)
		if AuthorityProfile.writes_product_pose(authority_profile)
		else locomotion_state.get_status_snapshot()
	)
	status["enabled"] = controller_enabled
	status["focused"] = _input_focused
	status["model_id"] = active_model_id
	status["contract_error"] = contract_error
	status["jolt_hint_status"] = _jolt_hint_status
	status["ground_lift"] = (
		{"enabled": false, "active": false, "reason": "jolt_authoritative_contact_response"}
		if AuthorityProfile.writes_product_pose(authority_profile)
		else ground_lift_reaction.get_status_snapshot()
	)
	status["authority_profile"] = authority_profile
	status["digging_response"] = _digging_response.get_status_snapshot()
	status["bucket_ground_mode"] = _bucket_ground_mode
	status["level_assist_enabled"] = level_assist_enabled
	status["slope_assist"] = slope_status_snapshot()
	status["assist_menu"] = assist_menu_snapshot()
	status["assist_view"] = _assist_view_cache
	return status


## Read-only borrow of the latest chassis snapshot for per-tick consumers
## (truth build, voxel identity, feedback loops). Callers must read it inside
## the current fixed step and must never retain or mutate it.
func peek_runtime_snapshot() -> Dictionary:
	if AuthorityProfile.writes_product_pose(authority_profile):
		return _jolt_runtime.peek_post_step_snapshot() if _jolt_runtime != null else _empty_authoritative_status()
	return locomotion_state.get_status_snapshot()


func get_digging_response_snapshot() -> Dictionary:
	return _digging_response.get_status_snapshot()


func is_input_focused() -> bool:
	return _input_focused


func set_digging_response_enabled(value: bool) -> void:
	digging_response_enabled = value
	_digging_response.set_enabled(value)
	if _jolt_runtime != null:
		_jolt_runtime.set_external_digging_response_enabled(
			value and _digging_response.configured and not _bucket_ground_bypassed()
		)


func set_level_assist_enabled(value: bool) -> bool:
	level_assist_enabled = value
	if _jolt_runtime == null:
		return false
	var applied := _jolt_runtime.set_equipment_assist_enabled("bucket_level", value)
	if value:
		# Prime the shared cadence so the side view + flat ribbon appear on
		# the next tick instead of after one refresh interval.
		_slope_preview_accum = SLOPE_PREVIEW_REFRESH_S
	elif String(_assist_view_cache.get("mode", "")) == "level":
		_assist_view_cache = {}
		_hide_slope_preview()
	return applied


## Advance the slope-assist state machine (bound to T/Enter and the UI control):
## off -> preview -> active -> off. Preview freezes the machine and flashes the
## soil volume the confirmed cut would remove; active hands boom/arm/bucket/swing
## to the profile-following stage.
func advance_slope_mode() -> String:
	match _slope_mode:
		SLOPE_MODE_OFF:
			if _jolt_runtime == null or not _jolt_runtime.configured:
				return slope_mode_state()
			if level_assist_enabled:
				set_level_assist_enabled(false)
			set_assist_menu_open(false)
			_slope_mode = SLOPE_MODE_PREVIEW
			_slope_preview_dirty = true
			_slope_preview_accum = SLOPE_PREVIEW_REFRESH_S
		SLOPE_MODE_PREVIEW:
			if _jolt_runtime == null:
				_exit_slope_mode()
				return slope_mode_state()
			var profile: RefCounted = _jolt_runtime.build_slope_profile(_slope_distance_m, _slope_angle_deg)
			if profile != null and _jolt_runtime.confirm_slope_assist(profile, _slope_preview_result):
				_slope_profile = profile
				_slope_mode = SLOPE_MODE_ACTIVE
				# The finished-surface ribbon stays up as the design reference
				# while the soil mark flips from blinking to a static tint.
		SLOPE_MODE_ACTIVE:
			_exit_slope_mode()
	return slope_mode_state()


func cancel_slope_mode() -> void:
	if _slope_mode != SLOPE_MODE_OFF:
		_exit_slope_mode()


func slope_mode_state() -> String:
	match _slope_mode:
		SLOPE_MODE_PREVIEW:
			return "preview"
		SLOPE_MODE_ACTIVE:
			return "active"
	return "off"


func slope_status_snapshot() -> Dictionary:
	var snapshot := {
		"state": slope_mode_state(),
		"distance_m": _slope_distance_m,
		"angle_deg": _slope_angle_deg,
	}
	if _slope_mode == SLOPE_MODE_PREVIEW:
		snapshot["cut_volume_m3"] = float(_slope_preview_result.get("volume_m3", 0.0))
		snapshot["max_depth_m"] = float(_slope_preview_result.get("max_depth_m", 0.0))
	if _slope_mode == SLOPE_MODE_ACTIVE and _slope_profile != null:
		snapshot["toe_distance_m"] = _slope_profile.toe_s
		snapshot["angle_deg"] = _slope_profile.angle_deg
	return snapshot


## Latest side-view snapshot for whichever terminal-surface assist is live —
## slope preview/active or level grading — empty otherwise. One channel so
## the HUD panel needs no per-assist lookup.
func assist_view_snapshot() -> Dictionary:
	return _assist_view_cache


func _exit_slope_mode() -> void:
	if _jolt_runtime != null:
		_jolt_runtime.set_equipment_assist_enabled("slope_grade", false)
		_jolt_runtime.clear_slope_cut_preview()
	_slope_mode = SLOPE_MODE_OFF
	_slope_profile = null
	_slope_preview_result = {}
	_assist_view_cache = {}
	_hide_slope_preview()


## Single-hotkey assist picker: T opens the menu (machine frozen while open,
## same intercept point as slope preview), W/S rides the arm axis for
## navigation, Enter activates the highlighted entry, T/Esc closes. Each entry
## maps to the owning assist's own advance/toggle semantics; cross-assist
## exclusivity is the pipeline's terminal_surface group.
func set_assist_menu_open(open: bool) -> void:
	if open and _slope_mode == SLOPE_MODE_PREVIEW:
		return
	_assist_menu_open = open
	_menu_nav_axis = 0.0
	if open:
		_assist_menu_index = clampi(_assist_menu_index, 0, ASSIST_MENU_ENTRIES.size() - 1)


func is_assist_menu_open() -> bool:
	return _assist_menu_open


func activate_assist_entry(index: int) -> String:
	if index < 0 or index >= ASSIST_MENU_ENTRIES.size():
		return ""
	set_assist_menu_open(false)
	match String(ASSIST_MENU_ENTRIES[index].get("id", "")):
		"level":
			set_level_assist_enabled(not level_assist_enabled)
			return "level"
		"slope":
			return "slope:" + advance_slope_mode()
	return ""


func assist_menu_snapshot() -> Dictionary:
	var entries: Array = []
	for entry in ASSIST_MENU_ENTRIES:
		var row := {"id": entry["id"], "label": entry["label"], "state": "off"}
		match String(entry["id"]):
			"level":
				row["state"] = "on" if level_assist_enabled else "off"
			"slope":
				row["state"] = slope_mode_state()
		entries.append(row)
	return {
		"open": _assist_menu_open,
		"index": _assist_menu_index,
		"entries": entries,
	}


func _navigate_assist_menu(axis: float) -> void:
	var count := ASSIST_MENU_ENTRIES.size()
	if count == 0:
		return
	var direction := 0
	if axis >= MENU_NAV_THRESHOLD and _menu_nav_axis < MENU_NAV_THRESHOLD:
		direction = -1
	elif axis <= -MENU_NAV_THRESHOLD and _menu_nav_axis > -MENU_NAV_THRESHOLD:
		direction = 1
	_menu_nav_axis = axis
	if direction != 0:
		_assist_menu_index = (_assist_menu_index + direction + count) % count


func _adjust_slope_params(equipment_axes: Vector4, delta: float) -> void:
	## W/S rides the arm axis (z), A/D rides the swing axis (x): while the machine
	## is frozen those two input axes become distance/angle adjustment instead.
	var dist_dir := equipment_axes.z
	var angle_dir := equipment_axes.x
	if absf(dist_dir) < 0.05 and absf(angle_dir) < 0.05:
		return
	var rates := _slope_adjust_rates()
	_slope_distance_m = clampf(
		_slope_distance_m + dist_dir * rates.x * delta, SLOPE_DISTANCE_MIN_M, SLOPE_DISTANCE_MAX_M
	)
	_slope_angle_deg = clampf(
		_slope_angle_deg + angle_dir * rates.y * delta, SLOPE_ANGLE_MIN_DEG, SLOPE_ANGLE_MAX_DEG
	)
	_slope_preview_dirty = true


func _slope_adjust_rates() -> Vector2:
	var defaults := Vector2(1.5, 15.0)
	if _jolt_runtime == null:
		return defaults
	var params := _jolt_runtime.get_equipment_assist_params("slope_grade")
	if params.is_empty():
		return defaults
	return Vector2(
		float(params.get("distance_adjust_rate_m_s", defaults.x)),
		float(params.get("angle_adjust_rate_deg_s", defaults.y))
	)


func _refresh_slope_preview(delta: float) -> void:
	if _jolt_runtime == null:
		return
	if _slope_mode == SLOPE_MODE_OFF:
		_refresh_level_view(delta)
		return
	if _slope_mode == SLOPE_MODE_ACTIVE:
		_refresh_slope_view(delta)
		return
	_slope_preview_accum += delta
	if _slope_preview_accum < SLOPE_PREVIEW_REFRESH_S or not _slope_preview_dirty:
		return
	_slope_preview_accum = 0.0
	_slope_preview_dirty = false
	var profile: RefCounted = _jolt_runtime.build_slope_profile(_slope_distance_m, _slope_angle_deg)
	if profile == null:
		_hide_slope_preview()
		return
	var preview := _jolt_runtime.update_slope_preview(profile)
	if not bool(preview.get("ok", false)):
		_hide_slope_preview()
		return
	_slope_preview_result = preview.get("result", {})
	_slope_profile = profile
	var node := _ensure_slope_preview_node()
	node.show_preview(_slope_preview_result, profile)
	_assist_view_cache = _jolt_runtime.slope_view_snapshot(
		profile,
		float(_slope_preview_result.get("s_min", 0.0)),
		float(_slope_preview_result.get("s_max", 0.0)),
		float(_slope_preview_result.get("half_width_m", 0.6)),
		float(_slope_preview_result.get("volume_m3", 0.0)),
		"preview"
	)


## Active-mode follow, every physics tick: the stage re-anchors the
## profile onto the live heading at the same rate, so chasing it is a
## handful of shader-uniform writes and one ribbon transform — no mesh
## rebuilds, no terrain sweeps. The heavier snapshot (context + centerline
## strip) rides the same cadence so the HUD glides instead of stepping;
## the genuinely expensive FK reach sweep stays preview-only.
func _refresh_slope_view(delta: float) -> void:
	if _slope_profile == null:
		return
	_jolt_runtime.refresh_slope_cut_mark(_slope_profile, _slope_preview_result)
	_ensure_slope_preview_node().follow_profile(_slope_profile)
	_assist_view_cache = _jolt_runtime.slope_view_snapshot(
		_slope_profile,
		float(_slope_preview_result.get("s_min", 0.0)),
		float(_slope_preview_result.get("s_max", 0.0)),
		float(_slope_preview_result.get("half_width_m", 0.6)),
		float(_slope_preview_result.get("volume_m3", 0.0)),
		"active"
	)


## Level assist rides the same side-view + ribbon machinery minus the blink:
## while it owns the equipment the flat tracked plane refreshes on the shared
## cadence and the world ghost shows the pad height the tooth is holding.
func _refresh_level_view(delta: float) -> void:
	if not level_assist_enabled:
		return
	_slope_preview_accum += delta
	if _slope_preview_accum < SLOPE_PREVIEW_REFRESH_S:
		return
	_slope_preview_accum = 0.0
	var view := _jolt_runtime.level_view_snapshot()
	if view.is_empty():
		_assist_view_cache = {}
		_hide_slope_preview()
		return
	_assist_view_cache = view
	var profile: RefCounted = view.get("profile")
	if profile != null:
		_ensure_slope_preview_node().show_preview(
			{
				"s_min": float(view.get("s_min", 0.0)),
				"s_max": float(view.get("s_max", 0.0)),
				"half_width_m": float(view.get("half_width", 0.6)),
			},
			profile
		)


func _ensure_slope_preview_node() -> SlopePreviewVisual:
	if _slope_preview_node == null or not is_instance_valid(_slope_preview_node):
		_slope_preview_node = SlopePreviewVisual.new()
		_slope_preview_node.name = "SlopeCutPreview"
		get_parent().add_child(_slope_preview_node)
	return _slope_preview_node


func _hide_slope_preview() -> void:
	if _slope_preview_node != null and is_instance_valid(_slope_preview_node):
		_slope_preview_node.hide_preview()


func can_set_bucket_ground_mode(value: String) -> bool:
	return BucketGroundInteractionMode.is_valid(value)


func set_bucket_ground_mode(value: String) -> bool:
	if not can_set_bucket_ground_mode(value):
		return false
	if _jolt_runtime != null:
		if not _jolt_runtime.set_bucket_ground_mode(value):
			return false
		_payload_identity = maxi(_payload_identity, _jolt_runtime.get_bucket_payload_identity())
	_bucket_ground_mode = value
	if _bucket_ground_bypassed():
		ground_lift_reaction.reset()
		_digging_response.reset_response("bucket_ground_interaction_bypassed")
	if _jolt_runtime != null:
		_jolt_runtime.set_external_digging_response_enabled(
			digging_response_enabled
			and _digging_response.configured
			and not _bucket_ground_bypassed()
		)
	return true


func _empty_authoritative_status() -> Dictionary:
	return {
		"authority_mode": AuthorityProfile.JOLT_AUTHORITATIVE,
		"configured": false,
		"body_transform": global_transform if is_inside_tree() else Transform3D.IDENTITY,
		"linear_velocity": Vector3.ZERO,
		"angular_velocity": Vector3.ZERO,
		"sleeping": false,
		"left_command": 0.0,
		"right_command": 0.0,
		"left_speed_mps": 0.0,
		"right_speed_mps": 0.0,
		"left_slip_ratio": 0.0,
		"right_slip_ratio": 0.0,
		"left_contact_count": 0,
		"right_contact_count": 0,
		"left_saturated": false,
		"right_saturated": false,
		"grounded": false,
		"terrain_generation": -1,
		"terrain_revision": -1,
		"terrain_identity_valid": false,
		"contacts": [],
		"bucket_ground_interaction": _empty_bucket_ground_interaction_status(),
		"quality_flags": ["authoritative_runtime_unavailable"],
	}


func _connect_runtime() -> void:
	_motion_client = get_node_or_null(motion_client_path) as MotionClient
	_product_session = get_node_or_null(product_session_path) as ProductSession
	_motion_presentation = get_node_or_null(motion_presentation_path) as MotionPresentation
	_terrain_world = get_node_or_null(terrain_world_path) as TerrainWorld
	_terrain_collider = get_node_or_null(terrain_collider_path) as TerrainCollider
	_excavation_world = get_node_or_null(excavation_world_path) as ExcavationWorld
	if _motion_client != null and not _motion_client.pose_cleared.is_connected(_on_pose_cleared):
		_motion_client.pose_cleared.connect(_on_pose_cleared)
	if _motion_presentation != null:
		if not _motion_presentation.model_activated.is_connected(_on_model_activated):
			_motion_presentation.model_activated.connect(_on_model_activated)
		var current_model := _motion_presentation.get_active_model_id()
		if not current_model.is_empty():
			_configure_model(current_model)
	if _terrain_world != null and not _terrain_world.world_reset.is_connected(_on_world_reset):
		_terrain_world.world_reset.connect(_on_world_reset)
	if _motion_presentation == null or _terrain_world == null:
		contract_error = "TrackedChassisController requires MotionPresentation and TerrainWorld"
		push_warning(contract_error)


func _configure_model(model_id: String) -> bool:
	var catalog := _read_json(MODEL_CATALOG_PATH)
	var entries: Array = catalog.get("models", [])
	for candidate in entries:
		if candidate is Dictionary and String(candidate.get("model_id", "")) == model_id:
			var parameters: Variant = candidate.get("tracked_locomotion")
			if not parameters is Dictionary or not locomotion_state.configure(parameters as Dictionary):
				contract_error = "model_contract_mismatch: invalid tracked locomotion for %s" % model_id
				active_model_id = ""
				if AuthorityProfile.writes_product_pose(authority_profile):
					_destroy_jolt_runtime()
				_reset_motion()
				return false
			active_model_id = model_id
			contract_error = ""
			if not _digging_response.configure(model_id):
				contract_error = "model_contract_mismatch: invalid digging response for %s" % model_id
				active_model_id = ""
				_reset_motion()
				return false
			_digging_response.set_enabled(digging_response_enabled)
			_base_local_transform = locomotion_state.chassis_transform
			ground_lift_reaction.configure(parameters as Dictionary)
			if AuthorityProfile.writes_product_pose(authority_profile):
				if not _configure_jolt_runtime(candidate as Dictionary):
					active_model_id = ""
					return false
			else:
				transform = _base_local_transform * ground_lift_reaction.step_fixed(0.0)
			return true
	contract_error = "unknown_model: %s" % model_id
	active_model_id = ""
	if AuthorityProfile.writes_product_pose(authority_profile):
		_destroy_jolt_runtime()
	_reset_motion()
	return false


func _sample_terrain_height(world_xz: Vector2) -> float:
	if _terrain_world == null or _terrain_world.terrain_state == null:
		_jolt_hint_status = "terrain_unavailable"
		return NAN
	var authoritative_height := _terrain_world.terrain_state.sample_surface_bilinear_at(world_xz)
	if not is_finite(authoritative_height):
		_jolt_hint_status = "outside_terrain"
		return NAN
	if not use_jolt_support_hints:
		_jolt_hint_status = "disabled"
		return authoritative_height
	if _terrain_collider == null or not _terrain_collider.available:
		_jolt_hint_status = "collider_unavailable"
		return authoritative_height
	var terrain_identity := Vector2i(
		_terrain_world.terrain_state.world_generation,
		_terrain_world.terrain_state.terrain_revision
	)
	if _terrain_collider.get_applied_identity() != terrain_identity:
		_jolt_hint_status = "identity_mismatch"
		return authoritative_height
	if not is_inside_tree() or get_world_3d() == null:
		_jolt_hint_status = "physics_unavailable"
		return authoritative_height
	var ray_from := Vector3(world_xz.x, authoritative_height + jolt_probe_height_m, world_xz.y)
	var ray_to := Vector3(world_xz.x, authoritative_height - jolt_probe_height_m, world_xz.y)
	var query := PhysicsRayQueryParameters3D.create(ray_from, ray_to, terrain_collision_mask)
	query.collide_with_areas = false
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	var collider: Variant = hit.get("collider")
	if hit.is_empty() or not collider is Node or not _terrain_collider.is_ancestor_of(collider as Node):
		_jolt_hint_status = "ray_miss"
		return authoritative_height
	var hit_position: Variant = hit.get("position")
	if not hit_position is Vector3:
		_jolt_hint_status = "invalid_hit"
		return authoritative_height
	var hinted_height := (hit_position as Vector3).y
	if not is_finite(hinted_height) or absf(hinted_height - authoritative_height) > jolt_hint_max_error_m:
		_jolt_hint_status = "height_mismatch"
		return authoritative_height
	_jolt_hint_status = "used"
	return hinted_height


func _reset_motion() -> void:
	locomotion_state.reset()
	ground_lift_reaction.reset()
	_base_local_transform = Transform3D.IDENTITY
	_use_test_commands = false
	_test_commands = Vector2.ZERO
	_use_test_equipment_commands = false
	_test_equipment_commands = Vector4.ZERO
	_digging_response.reset_response("motion_reset")
	_exit_slope_mode()
	set_assist_menu_open(false)
	if AuthorityProfile.writes_product_pose(authority_profile) and _jolt_runtime != null:
		var descriptor := PhysicsRigDescriptor.load_for_model(active_model_id)
		var spawn := _authoritative_spawn_transform(descriptor) if descriptor != null else Transform3D.IDENTITY
		_jolt_runtime.reset(spawn)
		_jolt_runtime.set_bucket_ground_mode(_bucket_ground_mode)
		_sync_visual_to_jolt_body()
	else:
		transform = Transform3D.IDENTITY


func _base_global_transform() -> Transform3D:
	var parent := get_parent_node_3d()
	return (parent.global_transform if parent != null else Transform3D.IDENTITY) * _base_local_transform


func _on_model_activated(model_id: String, _asset_root: Node3D) -> void:
	_configure_model(model_id)


func _on_pose_cleared(_generation: int, _reason: String) -> void:
	_reset_motion()


func _on_world_reset(_generation: int) -> void:
	if AuthorityProfile.writes_product_pose(authority_profile):
		_ensure_authoritative_terrain_collider()
	_reset_motion()


func _step_authoritative_chassis(delta: float) -> void:
	if _jolt_runtime == null or not _jolt_runtime.configured:
		return
	if controller_enabled and _input_focused:
		if _assist_menu_open:
			if Input.is_action_just_pressed("operator_assist") or Input.is_action_just_pressed("ui_cancel"):
				set_assist_menu_open(false)
			elif Input.is_action_just_pressed("ui_accept"):
				activate_assist_entry(_assist_menu_index)
		elif Input.is_action_just_pressed("operator_assist"):
			if _slope_mode == SLOPE_MODE_PREVIEW:
				advance_slope_mode()
			else:
				set_assist_menu_open(true)
		elif _slope_mode == SLOPE_MODE_PREVIEW and Input.is_action_just_pressed("ui_accept"):
			advance_slope_mode()
		elif _slope_mode == SLOPE_MODE_PREVIEW and Input.is_action_just_pressed("ui_cancel"):
			_exit_slope_mode()
	var left := 0.0
	var right := 0.0
	if controller_enabled and (
		_input_focused or (_test_input_focus_bypass and _use_test_commands)
	):
		if _use_test_commands:
			left = _test_commands.x
			right = _test_commands.y
		else:
			left = Input.get_action_strength("track_left_forward") - Input.get_action_strength("track_left_reverse")
			right = Input.get_action_strength("track_right_forward") - Input.get_action_strength("track_right_reverse")
	if _slope_mode == SLOPE_MODE_PREVIEW or _assist_menu_open:
		left = 0.0
		right = 0.0
	_jolt_runtime.set_enabled(controller_enabled)
	if _jolt_runtime.uses_wheels():
		if not controller_enabled or not _input_focused or _slope_mode == SLOPE_MODE_PREVIEW or _assist_menu_open:
			_jolt_runtime.stop_motion()
		else:
			var command := _test_wheel_commands if _use_test_wheel_commands else WheeledVehicleController.read_machine_input()
			_jolt_runtime.set_wheeled_commands(command.x, command.y, command.z, command.w)
	else:
		_jolt_runtime.set_commands(left, right)
	var equipment_axes := Vector4.ZERO
	if controller_enabled and (
		_input_focused or (_test_input_focus_bypass and _use_test_equipment_commands)
	):
			equipment_axes = (
			_test_equipment_commands
			if _use_test_equipment_commands
			else (
				_product_session.get_equipment_input_axes()
				if _product_session != null
				else (_motion_client.get_authoritative_input_axes() if _motion_client != null else Vector4.ZERO)
			)
		)
	if _slope_mode == SLOPE_MODE_PREVIEW:
		_adjust_slope_params(equipment_axes, delta)
		equipment_axes = Vector4.ZERO
	elif _assist_menu_open:
		_navigate_assist_menu(equipment_axes.z)
		equipment_axes = Vector4.ZERO
	_jolt_runtime.set_attachment_bucket_limits(
		_motion_presentation.get_active_attachment_id() if _motion_presentation != null else ""
	)
	_refresh_slope_preview(delta)
	var scaled_axes := equipment_axes
	if _bucket_ground_bypassed():
		_digging_response.reset_response("bucket_ground_interaction_bypassed")
	else:
		var soil_status := _excavation_world.get_interaction_snapshot() if _excavation_world != null else {}
		var response := _digging_response.step_fixed(delta, equipment_axes, soil_status)
		scaled_axes = response.get("scaled_commands", equipment_axes) as Vector4
	_jolt_runtime.set_external_digging_response_enabled(
		digging_response_enabled and _digging_response.configured and not _bucket_ground_bypassed()
	)
	_jolt_runtime.set_equipment_commands(scaled_axes, Engine.get_physics_frames())
	_submit_authoritative_payload()


func _configure_jolt_runtime(catalog_entry: Dictionary) -> bool:
	_destroy_jolt_runtime()
	_payload_identity = -1
	_last_payload_sample.clear()
	if _terrain_world == null or _terrain_world.terrain_state == null or _terrain_collider == null:
		contract_error = "jolt_authoritative requires TerrainWorld and TerrainCollider"
		return false
	var descriptor := PhysicsRigDescriptor.load_for_model(active_model_id)
	var model_version := String(catalog_entry.get("model_version", ""))
	if descriptor == null or not descriptor.is_valid_for(active_model_id, model_version):
		contract_error = (
			"missing physics rig descriptor for %s" % active_model_id
			if descriptor == null
			else descriptor.validation_error()
		)
		return false
	if not _ensure_authoritative_terrain_collider():
		contract_error = "jolt_authoritative terrain collider identity is unavailable"
		return false
	_jolt_runtime = JoltChassisTrackRuntime.new()
	_jolt_runtime.attachment_bucket_limit_offsets_deg = catalog_entry.get("attachment_bucket_limit_offsets_deg", {}).duplicate()
	_jolt_runtime.name = "JoltChassisTrackRuntime"
	var parent := get_parent()
	if parent == null:
		contract_error = "jolt_authoritative chassis has no scene parent"
		_jolt_runtime.free()
		_jolt_runtime = null
		return false
	parent.add_child(_jolt_runtime)
	if not _jolt_runtime.post_step_snapshot_captured.is_connected(_on_jolt_post_step_snapshot):
		_jolt_runtime.post_step_snapshot_captured.connect(_on_jolt_post_step_snapshot)
	if not _jolt_runtime.configure(
		descriptor,
		null if static_map_driving else _terrain_world,
		_terrain_collider,
		_authoritative_spawn_transform(descriptor),
		get_node_or_null("../StaticMap") as Node3D if static_map_driving else null
	):
		contract_error = _jolt_runtime.contract_error
		_destroy_jolt_runtime()
		return false
	_jolt_runtime.set_enabled(controller_enabled)
	_jolt_runtime.set_race_mode(race_mode_enabled)
	if not _jolt_runtime.set_bucket_ground_mode(_bucket_ground_mode):
		contract_error = "could not apply bucket-ground interaction policy"
		_destroy_jolt_runtime()
		return false
	_payload_identity = maxi(_payload_identity, _jolt_runtime.get_bucket_payload_identity())
	_jolt_runtime.set_external_digging_response_enabled(
		digging_response_enabled and _digging_response.configured and not _bucket_ground_bypassed()
	)
	_jolt_runtime.set_equipment_assist_enabled("bucket_level", level_assist_enabled)
	_on_jolt_post_step_snapshot(_jolt_runtime.get_post_step_snapshot())
	return true


func _destroy_jolt_runtime() -> void:
	_assist_view_cache = {}
	_hide_slope_preview()
	if _jolt_runtime == null:
		return
	_jolt_runtime.teardown()
	if _jolt_runtime.is_inside_tree():
		_jolt_runtime.name = "RetiredJoltChassisTrackRuntime"
		_jolt_runtime.queue_free()
	else:
		_jolt_runtime.free()
	_jolt_runtime = null


func _ensure_authoritative_terrain_collider() -> bool:
	if static_map_driving:
		return get_node_or_null("../StaticMap") != null
	if _terrain_world == null or _terrain_world.terrain_state == null or _terrain_collider == null:
		return false
	_terrain_collider.enabled = true
	var identity := Vector2i(
		_terrain_world.terrain_state.world_generation,
		_terrain_world.terrain_state.terrain_revision
	)
	if _terrain_collider.get_applied_identity() != identity:
		_terrain_collider.queue_snapshot(_terrain_world.terrain_state.surface_snapshot())
		_terrain_collider.apply_pending()
	return _terrain_collider.available and _terrain_collider.get_applied_identity() == identity


func _authoritative_spawn_transform(descriptor: PhysicsRigDescriptor) -> Transform3D:
	var parent := get_parent_node_3d()
	var spawn := parent.global_transform if parent != null else Transform3D.IDENTITY
	spawn.basis = spawn.basis.orthonormalized()
	if static_map_driving:
		spawn.origin = map_spawn_position
	var dynamics := descriptor.chassis_dynamics()
	var spawn_yaw := float(dynamics.get("spawn_yaw_rad", 0.0))
	spawn.basis = Basis(Vector3.UP, map_spawn_yaw_rad) if static_map_driving else (spawn.basis * Basis(Vector3.UP, spawn_yaw)).orthonormalized()
	var terrain_normal := Vector3.UP if static_map_driving else _sample_authoritative_terrain_normal(spawn.origin)
	if terrain_normal.length_squared() > 0.5:
		var forward := (-spawn.basis.z).slide(terrain_normal)
		if forward.length_squared() < 0.25:
			forward = spawn.basis.x.cross(terrain_normal)
		if forward.length_squared() > 0.25:
			forward = forward.normalized()
			var right := forward.cross(terrain_normal).normalized()
			spawn.basis = Basis(right, terrain_normal, -forward).orthonormalized()
	var surface_y := map_spawn_position.y if static_map_driving else 0.0
	var terrain_state: TerrainState = null
	if not static_map_driving and _terrain_world != null and _terrain_world.terrain_state != null:
		terrain_state = _terrain_world.terrain_state
		var sampled := terrain_state.sample_surface_bilinear_at(Vector2(spawn.origin.x, spawn.origin.z))
		if is_finite(sampled):
			surface_y = sampled
	var data := descriptor.to_dictionary()
	var wheel_profile := WheeledMachineProfile.load_for_model(active_model_id)
	if wheel_profile.enabled:
		var params: Dictionary = wheel_profile.data.parameters
		var sag := float(dynamics.mass_kg) * 9.80665 / (float(params.spring_n_m) * wheel_profile.stations.size())
		var origin_y := -INF
		for wheel: Dictionary in wheel_profile.stations:
			var offset: Vector3 = spawn.basis * (wheel.mount - Vector3.UP * (float(params.suspension_travel_m) - sag + float(wheel.radius_m)))
			var ground_y := surface_y
			if terrain_state != null:
				var sampled := terrain_state.sample_surface_bilinear_at(Vector2(spawn.origin.x + offset.x, spawn.origin.z + offset.z))
				if is_finite(sampled):
					ground_y = sampled
			origin_y = maxf(origin_y, ground_y - offset.y)
		spawn.origin.y = origin_y + 0.01
		return spawn
	var ground_clearance := float(dynamics.get("ground_clearance_m", 0.05))
	var tracks := data.get("tracks", {}) as Dictionary
	var stiffness := float(tracks.get("support_stiffness_n_per_m", 0.0))
	var probe_count := maxi(1, int(tracks.get("traction_points_per_side", 1)) * 2)
	var support_sag := 0.0
	if stiffness > 0.0:
		support_sag = clampf(float(dynamics.get("mass_kg", 0.0)) * 9.80665 / (stiffness * float(probe_count)), 0.0, 0.12)
	var minimum_bottom := INF
	var required_origin_y := -INF
	for shape_value in dynamics.get("compound_shapes", []):
		if not shape_value is Dictionary:
			continue
		var shape := shape_value as Dictionary
		var center := _vector3(shape.get("center_m", [0.0, 0.0, 0.0]))
		var size := _vector3(shape.get("size_m", [1.0, 1.0, 1.0]))
		var half := 0.5 * size
		for sx in [-1.0, 1.0]:
			for sy in [-1.0, 1.0]:
				for sz in [-1.0, 1.0]:
					var offset := spawn.basis * (center + Vector3(sx * half.x, sy * half.y, sz * half.z))
					minimum_bottom = minf(minimum_bottom, offset.y)
					if terrain_state != null:
						var corner_ground := terrain_state.sample_surface_bilinear_at(
							Vector2(spawn.origin.x + offset.x, spawn.origin.z + offset.z)
						)
						if is_finite(corner_ground):
							required_origin_y = maxf(required_origin_y, corner_ground + ground_clearance + support_sag - offset.y)
	if is_inf(minimum_bottom):
		minimum_bottom = 0.0
	spawn.origin.y = (
		required_origin_y
		if not is_inf(required_origin_y)
		else surface_y - minimum_bottom + ground_clearance + support_sag
	)
	return spawn


func _sample_authoritative_terrain_normal(world_position: Vector3) -> Vector3:
	if _terrain_world == null or _terrain_world.terrain_state == null:
		return Vector3.UP
	var state := _terrain_world.terrain_state
	var p := Vector2(world_position.x, world_position.z)
	if not state.is_inside_grid(p):
		return Vector3.UP
	var spacing := state.spacing_m
	var left_height := state.sample_surface_bilinear_at(p - Vector2(spacing, 0.0))
	var right_height := state.sample_surface_bilinear_at(p + Vector2(spacing, 0.0))
	var rear_height := state.sample_surface_bilinear_at(p - Vector2(0.0, spacing))
	var front_height := state.sample_surface_bilinear_at(p + Vector2(0.0, spacing))
	if not is_finite(left_height) or not is_finite(right_height) or not is_finite(rear_height) or not is_finite(front_height):
		return Vector3.UP
	return Vector3((left_height - right_height) / (2.0 * spacing), 1.0, (rear_height - front_height) / (2.0 * spacing)).normalized()


func _sync_visual_to_jolt_body() -> void:
	if _jolt_runtime == null or not _jolt_runtime.has_body():
		return
	_on_jolt_post_step_snapshot(_jolt_runtime.get_post_step_snapshot())


func _on_jolt_post_step_snapshot(snapshot: Dictionary) -> void:
	var body_transform: Variant = snapshot.get("body_transform")
	if not body_transform is Transform3D or not (body_transform as Transform3D).is_finite():
		return
	global_transform = body_transform as Transform3D
	_base_local_transform = transform
	ground_lift_reaction.reset()
	if _motion_presentation != null:
		_motion_presentation.apply_physics_snapshot(snapshot)


func _submit_authoritative_payload() -> void:
	if _jolt_runtime == null or _excavation_world == null:
		return
	var soil := _excavation_world.get_selected_soil_payload_snapshot()
	var center: Variant = soil.get("center_of_mass_local", Vector3.ZERO)
	if not center is Vector3:
		center = Vector3.ZERO
	var sample := {
		"mass_kg": float(soil.get("payload_mass_kg", 0.0)),
		"center_of_mass_local": center as Vector3,
		"world_generation": int(soil.get("world_generation", 0)),
		"ledger_identity": String(soil.get("ledger_identity", "legacy:unavailable")),
	}
	if sample == _last_payload_sample:
		return
	_payload_identity += 1
	if _jolt_runtime.set_bucket_payload(sample["mass_kg"], sample["center_of_mass_local"], _payload_identity):
		_last_payload_sample = sample


func _bucket_ground_bypassed() -> bool:
	return BucketGroundInteractionMode.is_passthrough(_bucket_ground_mode)


func _empty_bucket_ground_interaction_status() -> Dictionary:
	return {
		"mode": _bucket_ground_mode,
		"query_submitted": 0,
		"query_executed": 0,
		"query_bypassed": 0,
		"cut_probe_executed": 0,
		"cut_probe_bypassed": 0,
		"support_queued": 0,
		"support_applied": 0,
		"support_bypassed": 0,
	}


func _vector3(value: Variant) -> Vector3:
	var data := value as Array
	return Vector3(float(data[0]), float(data[1]), float(data[2]))


func _ensure_input_actions() -> void:
	WheeledVehicleController.ensure_input_actions()
	for action in INPUT_ACTIONS:
		if not InputMap.has_action(action):
			InputMap.add_action(action, 0.08)
		# These four product actions own one keyboard and one XInput-style binding.
		# Replace stale runtime events so old layouts cannot remain active.
		for existing in InputMap.action_get_events(action):
			if existing is InputEventKey or existing is InputEventJoypadMotion or existing is InputEventJoypadButton:
				InputMap.action_erase_event(action, existing)
		var definition: Dictionary = INPUT_ACTIONS[action]
		_add_key_event(action, int(definition["key"]))
		if definition.has("joy_axis"):
			_add_joy_axis_event(action, int(definition["joy_axis"]), float(definition["joy_sign"]))
		else:
			_add_joy_button_event(action, int(definition["joy_button"]))
	for action in TOGGLE_ACTIONS:
		if not InputMap.has_action(action):
			InputMap.add_action(action, 0.08)
		for existing in InputMap.action_get_events(action):
			if existing is InputEventKey:
				InputMap.action_erase_event(action, existing)
		for keycode in TOGGLE_ACTIONS[action]:
			_add_key_event(action, keycode)


func _add_key_event(action: String, keycode: int) -> void:
	for existing in InputMap.action_get_events(action):
		if existing is InputEventKey and (existing as InputEventKey).physical_keycode == keycode:
			return
	var event := InputEventKey.new()
	event.physical_keycode = keycode as Key
	InputMap.action_add_event(action, event)


func _add_joy_axis_event(action: String, axis: int, axis_value: float) -> void:
	var event := InputEventJoypadMotion.new()
	event.axis = axis as JoyAxis
	event.axis_value = axis_value
	InputMap.action_add_event(action, event)


func _add_joy_button_event(action: String, button_index: int) -> void:
	var event := InputEventJoypadButton.new()
	event.button_index = button_index as JoyButton
	InputMap.action_add_event(action, event)


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed as Dictionary if parsed is Dictionary else {}
