class_name AttachmentInputMapper
extends RefCounted

## Modifier-key layer for attachment axes declared by the attachment catalog.
## While the modifier is held, the catalog's action pair is redirected from the
## base equipment axes to the attachment axis; the other pairs in the same
## cluster keep their base function (e.g. Q+J/L tilts while Q+I/K still booms).
##
## `input_probe` (kind, name) -> float is injectable for headless tests:
## kind "key" returns 1.0 while the named modifier is held; kind "axis" is
## called with "negative_action|positive_action" and returns the axis value.

var input_probe: Callable = Callable()

var _tilt: Dictionary = {}
var _rotate: Dictionary = {}


func configure(controls: Dictionary) -> void:
	_tilt = (controls.get("tilt", {}) as Dictionary).duplicate(true)
	_rotate = (controls.get("rotate", {}) as Dictionary).duplicate(true)


func clear() -> void:
	_tilt = {}
	_rotate = {}


func is_active() -> bool:
	return not _tilt.is_empty() or not _rotate.is_empty()


## Vector2.x = tilt command, Vector2.y = rotation command, both in [-1, 1].
func read_attachment_axes() -> Vector2:
	return Vector2(_read_axis(_tilt), _read_axis(_rotate))


## Suppresses only the base axes whose action pairs are currently redirected.
func mask_operator_axes(axes: Vector4) -> Vector4:
	if _modifier_held(_tilt):
		axes = _suppress(axes, int(_tilt.get("masked_axis", -1)))
	if _modifier_held(_rotate):
		axes = _suppress(axes, int(_rotate.get("masked_axis", -1)))
	return axes


func _suppress(axes: Vector4, index: int) -> Vector4:
	match index:
		0: axes.x = 0.0
		1: axes.y = 0.0
		2: axes.z = 0.0
		3: axes.w = 0.0
	return axes


func _read_axis(spec: Dictionary) -> float:
	if spec.is_empty() or not _modifier_held(spec):
		return 0.0
	var negative := String(spec.get("negative_action", ""))
	var positive := String(spec.get("positive_action", ""))
	if negative.is_empty() or positive.is_empty():
		return 0.0
	return clampf(_probe_axis(negative, positive), -1.0, 1.0)


func _modifier_held(spec: Dictionary) -> bool:
	var key_name := String(spec.get("modifier_key", ""))
	if key_name.is_empty():
		return false
	if input_probe.is_valid():
		return input_probe.call("key", key_name) > 0.5
	var code := OS.find_keycode_from_string(key_name.trim_prefix("KEY_"))
	return code != KEY_NONE and Input.is_key_pressed(code)


func _probe_axis(negative_action: String, positive_action: String) -> float:
	if input_probe.is_valid():
		return input_probe.call("axis", "%s|%s" % [negative_action, positive_action])
	return Input.get_axis(negative_action, positive_action)
