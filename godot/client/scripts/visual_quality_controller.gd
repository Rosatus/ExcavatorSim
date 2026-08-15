class_name VisualQualityController
extends Node

const PROFILES := {
	"low": {"particles": 500, "camera_far": 80.0, "shadows": false},
	"balanced": {"particles": 1800, "camera_far": 140.0, "shadows": true},
	"high": {"particles": 4200, "camera_far": 220.0, "shadows": true},
}

@export var profile := "balanced"
@export var target_fps := 60

var last_error := ""
var _applied := false


func _ready() -> void:
	if not apply_profile(profile):
		apply_profile("balanced")


func apply_profile(profile_name: String) -> bool:
	if not PROFILES.has(profile_name):
		last_error = "unknown_quality_profile"
		return false
	var settings: Dictionary = PROFILES[profile_name]
	var environment := get_node_or_null("../VisualEnvironment") as VisualEnvironment
	if is_inside_tree() and environment == null:
		_applied = false
		last_error = "visual_environment_unavailable"
		return false
	if environment != null and not environment.apply_profile(profile_name):
		_applied = false
		last_error = "visual_environment_profile_failed"
		return false
	profile = profile_name
	var camera := get_node_or_null("../Camera3D") as CameraRig
	if camera != null:
		camera.far = float(settings["camera_far"])
		camera.set_quality_distance_for_test(float(settings["camera_far"]) * 0.1)
	var effects := get_node_or_null("../SoilEffects") as SoilEffects
	if effects != null:
		effects.set_budget(int(settings["particles"]))
	Engine.max_fps = target_fps
	_applied = true
	last_error = ""
	return true


func get_quality_snapshot() -> Dictionary:
	var settings: Dictionary = PROFILES.get(profile, {})
	return {
		"profile": profile,
		"target_fps": target_fps,
		"particles": int(settings.get("particles", 0)),
		"camera_far": float(settings.get("camera_far", 0.0)),
		"shadows": bool(settings.get("shadows", false)),
		"applied": _applied,
		"last_error": last_error,
	}
