class_name VisualEnvironment
extends Node

const FIXED_DAYTIME_HOURS := 10.5
const FIXED_LATITUDE_RADIANS := deg_to_rad(16.0)
const FIXED_LONGITUDE_RADIANS := deg_to_rad(108.0)
const FIXED_UTC_OFFSET_HOURS := 7.0
const HORIZON_GROUND_COLOR := Color("#46513d")
const SKY_PROFILES := {
	"low": {
		"ambient_energy": 0.58,
		"sun_energy": 1.02,
		"cloud_intensity": 0.0,
		"cirrus_intensity": 0.0,
		"clouds": false,
		"fog": false,
		"fog_density": 0.0,
		"shadows": false,
	},
	"balanced": {
		"ambient_energy": 0.72,
		"sun_energy": 1.16,
		"cloud_intensity": 0.65,
		"cirrus_intensity": 1.15,
		"clouds": true,
		"fog": true,
		"fog_density": 0.00045,
		"shadows": true,
	},
	"high": {
		"ambient_energy": 0.78,
		"sun_energy": 1.2,
		"cloud_intensity": 0.78,
		"cirrus_intensity": 1.35,
		"clouds": true,
		"fog": true,
		"fog_density": 0.00065,
		"shadows": true,
	},
}

@export var world_environment_path := NodePath("../WorldEnvironment")
@export var key_light_path := NodePath("../KeyLight")
@export var profile := "balanced"

var environment_ready := false


func _ready() -> void:
	apply_profile(profile)


func apply_profile(profile_name: String) -> bool:
	if not SKY_PROFILES.has(profile_name):
		return false
	var world := get_node_or_null(world_environment_path) as Sky3D
	if world == null:
		return false
	profile = profile_name
	var settings: Dictionary = SKY_PROFILES[profile_name]
	_configure_fixed_daytime(world)
	world.sky3d_enabled = true
	world.sky_enabled = true
	world.lights_enabled = true
	world.clouds_enabled = bool(settings["clouds"])
	world.fog_enabled = bool(settings["fog"])
	world.ambient_energy = float(settings["ambient_energy"])
	world.cloud_intensity = float(settings["cloud_intensity"])
	world.sun_energy = float(settings["sun_energy"])
	world.sun_shadow_opacity = 1.0 if bool(settings["shadows"]) else 0.0
	var environment := world.environment
	if environment == null or environment.sky == null:
		return false
	environment.ambient_light_energy = float(settings["ambient_energy"])
	environment.tonemap_exposure = 0.96
	environment.tonemap_white = 5.5
	environment.glow_enabled = profile == "high"
	environment.ssao_enabled = profile != "low"
	environment.ssao_radius = 1.25
	environment.ssao_intensity = 1.62
	environment.adjustment_enabled = true
	environment.adjustment_brightness = 1.01
	environment.adjustment_contrast = 1.06
	environment.adjustment_saturation = 0.94
	# Sky3D owns the screen-space atmosphere. Built-in fog remains off so the
	# two fog systems never stack.
	environment.fog_enabled = false
	if world.sky != null:
		world.sky.fog_density = float(settings["fog_density"])
		world.sky.ground_color = HORIZON_GROUND_COLOR
		world.sky.horizon_offset = -0.005
		world.sky.wind_speed = 0.0
		world.sky.cirrus_intensity = float(settings["cirrus_intensity"])
		world.sky.cirrus_coverage = 0.34 if profile_name == "high" else 0.26
		world.sky.cumulus_coverage = 0.48 if profile_name == "high" else 0.38
		world.sky.moon_light_enabled = false
	if world.sun != null:
		world.sun.shadow_enabled = bool(settings["shadows"])
		world.sun.directional_shadow_max_distance = 80.0 if profile_name == "high" else 55.0
		world.sun.light_angular_distance = 0.35
		world.sun.light_color = Color("fff1dc")
		world.sun.shadow_bias = 0.035
		world.sun.shadow_normal_bias = 1.15
		world.sun.shadow_blur = 0.85
	if world.moon != null:
		world.moon.visible = false
		world.moon.shadow_enabled = false
		world.moon.light_energy = 0.0
	var key_light := get_node_or_null(key_light_path) as DirectionalLight3D
	if key_light != null:
		key_light.visible = false
		key_light.shadow_enabled = false
		key_light.light_energy = 0.0
	environment_ready = true
	return true


func get_active_sun() -> DirectionalLight3D:
	var world := get_node_or_null(world_environment_path) as Sky3D
	return world.sun if world != null else null


func get_visual_snapshot() -> Dictionary:
	var world := get_node_or_null(world_environment_path) as Sky3D
	return {
		"profile": profile,
		"environment_ready": environment_ready,
		"target_fps": 60,
		"renderer": "Forward+",
		"shadows": profile != "low",
		"backend": "Sky3D" if world != null else "unavailable",
		"fixed_time": world.current_time if world != null else -1.0,
		"time_progression": world.game_time_enabled if world != null else false,
		"clouds": world.clouds_enabled if world != null else false,
		"fog": world.fog_enabled if world != null else false,
	}


func _configure_fixed_daytime(world: Sky3D) -> void:
	world.editor_time_enabled = false
	world.game_time_enabled = false
	if world.tod != null:
		world.tod.system_sync = false
		world.tod.celestials_calculations = TimeOfDay.CelestialMode.SIMPLE
		world.tod.latitude = FIXED_LATITUDE_RADIANS
		world.tod.longitude = FIXED_LONGITUDE_RADIANS
		world.tod.utc = FIXED_UTC_OFFSET_HOURS
		world.tod.compute_moon_coords = false
		world.tod.compute_deep_space_coords = false
	world.current_time = FIXED_DAYTIME_HOURS
	world.pause()
