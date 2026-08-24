class_name DiggingResponseShaper
extends RefCounted

## Normalized game-feel response at the equipment command boundary. This is
## deliberately not a hydraulic model: it publishes phases/intensity and only
## slows commands that continue working into soil.

const SCHEMA_VERSION := "digging-response-v1"
const PROFILE_PATH := "res://resources/physics/digging_response_profiles.json"
const PHASES := ["free", "contact", "scrape", "cut", "load", "overflow", "blocked", "dump", "escape"]
const WORKING_AXIS_INDICES := [1, 2, 3]

var configured := false
var enabled := true
var model_id := ""

var _model: Dictionary = {}
var _materials: Dictionary = {}
var _phases: Dictionary = {}
var _phase := "free"
var _intensity := 0.0
var _speed_scales := Vector4.ONE
var _blocked_time_s := 0.0
var _sequence := 0
var _last_snapshot: Dictionary = {}


func configure(requested_model_id: String) -> bool:
	reset()
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PROFILE_PATH))
	if not parsed is Dictionary:
		return false
	var root := parsed as Dictionary
	if root.get("schema_version", "") != "digging-response-profiles-v1":
		return false
	var models := root.get("models", {}) as Dictionary
	var materials := root.get("materials", {}) as Dictionary
	var phases := root.get("phases", {}) as Dictionary
	if not models.has(requested_model_id) or materials.size() != 4 or phases.size() != PHASES.size():
		return false
	var candidate := models[requested_model_id] as Dictionary
	var axis_weights := candidate.get("axis_weights", []) as Array
	if (
		axis_weights.size() != 4
		or float(candidate.get("minimum_speed_scale", 0.0)) <= 0.0
		or float(candidate.get("minimum_speed_scale", 1.0)) >= 1.0
		or float(candidate.get("attack_hz", 0.0)) <= 0.0
		or float(candidate.get("release_hz", 0.0)) <= 0.0
		or float(candidate.get("escape_release_hz", 0.0)) <= 0.0
		or float(candidate.get("maximum_scale_slew_per_s", 0.0)) <= 0.0
		or float(candidate.get("blocked_delay_s", 0.0)) <= 0.0
		or float(candidate.get("flow_reference_m3_per_tick", 0.0)) <= 0.0
	):
		return false
	for phase in PHASES:
		if not phases.has(phase):
			return false
	_model = candidate.duplicate(true)
	_materials = materials.duplicate(true)
	_phases = phases.duplicate(true)
	model_id = requested_model_id
	configured = true
	_last_snapshot = _snapshot(Vector4.ZERO, Vector4.ZERO, "unavailable", 0.0, 0.0, 0.0, "configured")
	return true


func reset() -> void:
	configured = false
	model_id = ""
	_model.clear()
	_materials.clear()
	_phases.clear()
	_phase = "free"
	_intensity = 0.0
	_speed_scales = Vector4.ONE
	_blocked_time_s = 0.0
	_sequence = 0
	_last_snapshot.clear()


func reset_response(reason: String = "reset") -> void:
	_phase = "free"
	_intensity = 0.0
	_speed_scales = Vector4.ONE
	_blocked_time_s = 0.0
	_sequence += 1
	_last_snapshot = _snapshot(Vector4.ZERO, Vector4.ZERO, "unavailable", 0.0, 0.0, 0.0, reason)


func set_enabled(value: bool) -> void:
	enabled = value
	if not value:
		reset_response("disabled")


func step_fixed(delta: float, raw_commands: Vector4, soil_status: Dictionary) -> Dictionary:
	if not configured or not raw_commands.is_finite() or not is_finite(delta) or delta <= 0.0:
		return _snapshot(raw_commands if raw_commands.is_finite() else Vector4.ZERO, Vector4.ZERO, "unavailable", 0.0, 0.0, 0.0, "invalid_input")
	if not enabled:
		_speed_scales = Vector4.ONE
		_phase = "free"
		_intensity = 0.0
		_sequence += 1
		_last_snapshot = _snapshot(raw_commands, raw_commands, "unavailable", 0.0, 0.0, 0.0, "disabled")
		return _last_snapshot.duplicate(true)
	var inputs := _derive_inputs(raw_commands, soil_status)
	var raw_phase := String(inputs["phase"])
	var raw_intensity := float(inputs["intensity"])
	var working_against_soil := bool(inputs["working_against_soil"])
	if working_against_soil and raw_intensity >= float(_model["engage_threshold"]):
		_blocked_time_s += delta if bool(inputs["low_flow_contact"]) else -delta * 2.0
	else:
		_blocked_time_s = 0.0
	_blocked_time_s = maxf(_blocked_time_s, 0.0)
	if _blocked_time_s >= float(_model["blocked_delay_s"]):
		raw_phase = "blocked"
		raw_intensity = 1.0
	var escaping := _has_escape_command(raw_commands) and (
		_phase not in ["free", "dump", "escape"] or raw_phase in ["contact", "blocked"]
	)
	if escaping:
		raw_phase = "escape"
		raw_intensity = 0.0
		working_against_soil = false
	var target_intensity := raw_intensity if working_against_soil else 0.0
	if target_intensity < float(_model["disengage_threshold"]) and _intensity < float(_model["engage_threshold"]):
		target_intensity = 0.0
	var intensity_hz := float(_model["attack_hz"]) if target_intensity > _intensity else float(_model["release_hz"])
	if escaping or raw_phase == "dump":
		intensity_hz = float(_model["escape_release_hz"])
	_intensity = lerpf(_intensity, target_intensity, _response_alpha(intensity_hz, delta))
	if _intensity <= float(_model["disengage_threshold"]) and raw_phase not in ["dump", "escape"]:
		_phase = "free"
	elif raw_phase in PHASES:
		_phase = raw_phase
	var target_scales := _target_scales(raw_commands, _phase, _intensity)
	for index in 4:
		var scale_hz := float(_model["attack_hz"]) if target_scales[index] < _speed_scales[index] else float(_model["release_hz"])
		if escaping or raw_phase == "dump":
			scale_hz = float(_model["escape_release_hz"])
		var filtered_scale := lerpf(_speed_scales[index], target_scales[index], _response_alpha(scale_hz, delta))
		_speed_scales[index] = move_toward(
			_speed_scales[index],
			filtered_scale,
			float(_model["maximum_scale_slew_per_s"]) * delta,
		)
	var scaled_commands := Vector4(
		raw_commands.x * _speed_scales.x,
		raw_commands.y * _speed_scales.y,
		raw_commands.z * _speed_scales.z,
		raw_commands.w * _speed_scales.w,
	)
	_sequence += 1
	_last_snapshot = _snapshot(
		raw_commands,
		scaled_commands,
		String(inputs["ledger_identity"]),
		float(inputs["flow_volume_m3"]),
		float(inputs["fill_ratio"]),
		float(inputs["overflow_volume_m3"]),
		"stepped",
	)
	_last_snapshot["raw_phase"] = String(inputs["phase"])
	_last_snapshot["raw_intensity"] = raw_intensity
	_last_snapshot["working_against_soil"] = working_against_soil
	_last_snapshot["persistent_contact"] = bool(inputs["persistent_contact"])
	_last_snapshot["active_contact"] = bool(inputs["active_contact"])
	_last_snapshot["blocked_time_s"] = _blocked_time_s
	_last_snapshot["material_preset"] = String(inputs["material_preset"])
	return _last_snapshot.duplicate(true)


func get_status_snapshot() -> Dictionary:
	return _last_snapshot.duplicate(true)


func _derive_inputs(commands: Vector4, status: Dictionary) -> Dictionary:
	var lifecycle := status.get("soil_lifecycle_active", {}) as Dictionary
	if not bool(lifecycle.get("configured", false)):
		lifecycle = status.get("soil_lifecycle_shadow", {}) as Dictionary
	var lifecycle_available := bool(lifecycle.get("configured", false))
	var selected := status.get("selected_soil_payload", {}) as Dictionary
	var fill_ratio := float(lifecycle.get("fill_ratio", selected.get("fill_ratio", status.get("fill_ratio", 0.0)))) if lifecycle_available else float(selected.get("fill_ratio", status.get("fill_ratio", 0.0)))
	var material := String(lifecycle.get("material_preset", "loose")) if lifecycle_available else "loose"
	if not _materials.has(material):
		material = "loose"
	var overflow := float(lifecycle.get("overflow_volume_m3", 0.0)) if lifecycle_available else 0.0
	var last_transaction := lifecycle.get("last_transaction", {}) as Dictionary if lifecycle_available else {}
	var transaction_kind := String(last_transaction.get("kind", ""))
	var accepted_flow := float(last_transaction.get("accepted_volume_m3", status.get("flow_volume_m3", 0.0))) if lifecycle_available else float(status.get("flow_volume_m3", 0.0))
	var batch := status.get("soil_interaction_batch", {}) as Dictionary
	var tool := batch.get("soil_tool_classification", batch.get("soil_tool_shadow", {})) as Dictionary
	var maximum_penetration := maxf(0.0, float(batch.get("analytic_penetration_m", 0.0)))
	var stable_action := ""
	var persistent_contact := maximum_penetration > 0.001
	var active_contact := false
	for candidate_value in tool.get("candidates", []):
		var candidate := candidate_value as Dictionary
		maximum_penetration = maxf(maximum_penetration, float(candidate.get("penetration_m", 0.0)))
		var role_scope := String(candidate.get("role_scope", "none"))
		var action := String(candidate.get("classification", "none"))
		persistent_contact = persistent_contact or role_scope == "stable" or (bool(candidate.get("overlap", false)) and role_scope != "active")
		active_contact = active_contact or role_scope == "active"
		if role_scope == "stable" and action != "none" and stable_action.is_empty():
			stable_action = action
	var operation := String(batch.get("operation", status.get("interaction_state", "idle")))
	var working := _has_working_command(commands)
	var phase := "free"
	if operation in ["dump", "spill"] or transaction_kind in ["dump", "spill"]:
		phase = "dump"
	elif overflow > 0.000001:
		phase = "overflow"
	elif transaction_kind in ["cut", "side_cut"] or stable_action in ["cut", "side_cut"] or operation in ["cut", "cutting"]:
		phase = "load" if fill_ratio >= 0.78 else "cut"
	elif transaction_kind in ["scrape", "grade"] or stable_action in ["scrape", "grade", "push", "back_drag"] or operation == "push":
		phase = "scrape"
	elif persistent_contact:
		phase = "contact"
	var penetration_intensity := clampf(maximum_penetration / 0.10, 0.0, 1.0)
	var flow_intensity := clampf(accepted_flow / float(_model["flow_reference_m3_per_tick"]), 0.0, 1.0)
	var intensity := 0.0
	match phase:
		"contact":
			intensity = 0.18 + 0.45 * penetration_intensity
		"scrape":
			intensity = 0.28 + 0.40 * penetration_intensity + 0.18 * flow_intensity
		"cut":
			intensity = 0.30 + 0.34 * penetration_intensity + 0.28 * flow_intensity + 0.08 * fill_ratio
		"load":
			intensity = 0.42 + 0.24 * penetration_intensity + 0.20 * flow_intensity + 0.22 * fill_ratio
		"overflow":
			intensity = 0.78 + 0.22 * clampf(overflow / maxf(float(lifecycle.get("bucket_capacity_m3", 0.35)) * 0.1, 0.001), 0.0, 1.0)
		_:
			intensity = 0.0
	intensity *= float((_materials[material] as Dictionary).get("intensity_scale", 1.0))
	intensity = clampf(intensity, 0.0, 1.0)
	return {
		"phase": phase,
		"intensity": intensity,
		"working_against_soil": working and phase not in ["free", "dump"],
		"low_flow_contact": persistent_contact and accepted_flow <= 0.000001,
		"persistent_contact": persistent_contact,
		"active_contact": active_contact,
		"flow_volume_m3": accepted_flow,
		"fill_ratio": fill_ratio,
		"overflow_volume_m3": overflow,
		"material_preset": material,
		"ledger_identity": String(lifecycle.get("ledger_identity", selected.get("ledger_identity", "unavailable"))),
	}


func _target_scales(commands: Vector4, phase: String, intensity: float) -> Vector4:
	var result := Vector4.ONE
	if phase in ["free", "dump", "escape"] or intensity <= 0.0:
		return result
	var strength := float((_phases.get(phase, {"strength": 0.0}) as Dictionary).get("strength", 0.0))
	var minimum := float(_model["minimum_speed_scale"])
	var weights := _model["axis_weights"] as Array
	for index in WORKING_AXIS_INDICES:
		if commands[index] >= -0.0001:
			result[index] = 1.0
			continue
		var response := clampf(intensity * strength * float(weights[index]), 0.0, 1.0)
		result[index] = lerpf(1.0, minimum, response)
	result.x = 1.0
	return result


func _has_working_command(commands: Vector4) -> bool:
	return commands.y < -0.0001 or commands.z < -0.0001 or commands.w < -0.0001


func _has_escape_command(commands: Vector4) -> bool:
	return commands.y > 0.05 or commands.z > 0.05 or commands.w > 0.05


func _response_alpha(rate_hz: float, delta: float) -> float:
	return clampf(1.0 - exp(-maxf(rate_hz, 0.001) * delta), 0.0, 1.0)


func _snapshot(
	raw_commands: Vector4,
	scaled_commands: Vector4,
	ledger_identity: String,
	flow_volume_m3: float,
	fill_ratio: float,
	overflow_volume_m3: float,
	reason: String
) -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION,
		"configured": configured,
		"enabled": enabled,
		"model_id": model_id,
		"sequence": _sequence,
		"phase": _phase,
		"intensity": _intensity,
		"speed_scales": _speed_scales,
		"raw_commands": raw_commands,
		"scaled_commands": scaled_commands,
		"ledger_identity": ledger_identity,
		"flow_volume_m3": maxf(0.0, flow_volume_m3),
		"fill_ratio": clampf(fill_ratio, 0.0, 1.5),
		"overflow_volume_m3": maxf(0.0, overflow_volume_m3),
		"reason": reason,
	}
