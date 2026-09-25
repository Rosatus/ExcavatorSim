class_name AttachmentInputMapper
extends RefCounted

## Modifier layer for secondary axes. Two independent modifier families per
## spec: a keyboard modifier_key (e.g. Q+J/L tilts while Q+I/K still booms)
## and a pad-layer action bound to a D-pad direction (hold + right stick).
## While a modifier is held, its configured action pair is redirected from
## the base equipment axes to the secondary axis; the other pairs in the same
## cluster keep their base function.
##
## `input_probe` (kind, name) -> float is injectable for headless tests:
## kind "key" returns 1.0 while the named keyboard modifier is held, kind
## "pad" returns 1.0 while the named pad-layer action is held, and kind
## "axis" is called with "negative_action|positive_action" and returns the
## axis value.

## D-pad directions doubled as the pad modifier layer after camera presets
## moved to the View button; the names stay semantic for reuse by menus.
const PAD_LAYER_ACTIONS := {
	"pad_layer_dpad_up": JOY_BUTTON_DPAD_UP,
	"pad_layer_dpad_down": JOY_BUTTON_DPAD_DOWN,
	"pad_layer_dpad_left": JOY_BUTTON_DPAD_LEFT,
	"pad_layer_dpad_right": JOY_BUTTON_DPAD_RIGHT,
}

## Base action -> authoritative axis index (AXIS_ORDER: swing, boom, arm,
## bucket). Pad pairs reuse the operator actions, so the suppressed base
## axis is derived from the pair instead of a second manifest field.
const ACTION_AXIS_INDEX := {
	"operator_swing_left": 0,
	"operator_swing_right": 0,
	"operator_boom_lower": 1,
	"operator_boom_raise": 1,
	"operator_arm_retract": 2,
	"operator_arm_extend": 2,
	"operator_bucket_curl": 3,
	"operator_bucket_dump": 3,
}

## Pad layer for manifest local_articulation axes, keyed by axis_id. The pad
## direction matches the motion plane: boom_swing rides right-stick X while
## D-pad Left is held, boom_fold rides right-stick Y while D-pad Up is held.
const LOCAL_PAD_LAYERS := {
	"boom_swing": {
		"pad_modifier_action": "pad_layer_dpad_left",
		"pad_negative_action": "operator_bucket_dump",
		"pad_positive_action": "operator_bucket_curl",
	},
	"boom_fold": {
		"pad_modifier_action": "pad_layer_dpad_up",
		"pad_negative_action": "operator_boom_raise",
		"pad_positive_action": "operator_boom_lower",
	},
}

var input_probe: Callable = Callable()

var _tilt: Dictionary = {}
var _rotate: Dictionary = {}
var _local_specs: Dictionary = {}


func configure(controls: Dictionary) -> void:
	_tilt = (controls.get("tilt", {}) as Dictionary).duplicate(true)
	_rotate = (controls.get("rotate", {}) as Dictionary).duplicate(true)


func clear() -> void:
	_tilt = {}
	_rotate = {}


## Registers the pad layer for the model's manifest-declared local axes.
## Models without local axes pass an empty list so their pad directions
## stay pure no-ops and never mask base equipment axes.
func configure_local_axes(axis_ids: Array) -> void:
	_local_specs.clear()
	for axis_id in axis_ids:
		var spec: Variant = LOCAL_PAD_LAYERS.get(String(axis_id))
		if spec is Dictionary:
			_local_specs[String(axis_id)] = spec


func clear_local_axes() -> void:
	_local_specs.clear()


func is_active() -> bool:
	return not _tilt.is_empty() or not _rotate.is_empty()


## Vector2.x = tilt command, Vector2.y = rotation command, both in [-1, 1].
func read_attachment_axes() -> Vector2:
	return Vector2(_read_axis(_tilt), _read_axis(_rotate))


## Model-local presentation axis in [-1, 1]. While the axis's pad modifier
## is held, the pad action pair replaces the keyboard pair; otherwise the
## base actions (e.g. E/U) answer directly.
func read_local_axis(axis_id: String, negative_action: String, positive_action: String) -> float:
	var spec := _local_specs.get(axis_id, {}) as Dictionary
	if _pad_modifier_held(spec):
		var value := _probe_axis(
			String(spec.get("pad_negative_action", "")),
			String(spec.get("pad_positive_action", ""))
		)
		return clampf(value, -1.0, 1.0)
	return Input.get_axis(negative_action, positive_action)


## Suppresses only the base axes whose action pairs are currently redirected.
func mask_operator_axes(axes: Vector4) -> Vector4:
	for spec in [_tilt, _rotate]:
		if _key_modifier_held(spec):
			axes = _suppress(axes, int(spec.get("masked_axis", -1)))
		if _pad_modifier_held(spec):
			axes = _suppress(axes, _pad_masked_axis(spec))
	for spec_value in _local_specs.values():
		var local_spec := spec_value as Dictionary
		if _pad_modifier_held(local_spec):
			axes = _suppress(axes, _pad_masked_axis(local_spec))
	return axes


func _suppress(axes: Vector4, index: int) -> Vector4:
	match index:
		0: axes.x = 0.0
		1: axes.y = 0.0
		2: axes.z = 0.0
		3: axes.w = 0.0
	return axes


func _read_axis(spec: Dictionary) -> float:
	var pair := _active_pair(spec)
	if pair.is_empty():
		return 0.0
	return clampf(_probe_axis(pair[0], pair[1]), -1.0, 1.0)


## Picks the live action pair for a spec: the pad pair while the D-pad
## modifier is held, otherwise the keyboard modifier's base pair. Empty
## array means no modifier is held.
func _active_pair(spec: Dictionary) -> Array:
	if spec.is_empty():
		return []
	var negative := ""
	var positive := ""
	if _pad_modifier_held(spec):
		negative = String(spec.get("pad_negative_action", ""))
		positive = String(spec.get("pad_positive_action", ""))
	elif _key_modifier_held(spec):
		negative = String(spec.get("negative_action", ""))
		positive = String(spec.get("positive_action", ""))
	if negative.is_empty() or positive.is_empty():
		return []
	return [negative, positive]


func _key_modifier_held(spec: Dictionary) -> bool:
	var key_name := String(spec.get("modifier_key", ""))
	if key_name.is_empty():
		return false
	if input_probe.is_valid():
		return input_probe.call("key", key_name) > 0.5
	var code := OS.find_keycode_from_string(key_name.trim_prefix("KEY_"))
	return code != KEY_NONE and Input.is_key_pressed(code)


func _pad_modifier_held(spec: Dictionary) -> bool:
	var action := String(spec.get("pad_modifier_action", ""))
	if action.is_empty():
		return false
	if input_probe.is_valid():
		return input_probe.call("pad", action) > 0.5
	return InputMap.has_action(action) and Input.is_action_pressed(action)


func _pad_masked_axis(spec: Dictionary) -> int:
	var positive := String(spec.get("pad_positive_action", ""))
	return int(ACTION_AXIS_INDEX.get(positive, -1))


func _probe_axis(negative_action: String, positive_action: String) -> float:
	if negative_action.is_empty() or positive_action.is_empty():
		return 0.0
	if input_probe.is_valid():
		return input_probe.call("axis", "%s|%s" % [negative_action, positive_action])
	return Input.get_axis(negative_action, positive_action)
