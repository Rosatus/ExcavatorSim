class_name VisualEnvironment
extends Node

@export var world_environment_path := NodePath("../WorldEnvironment")
@export var key_light_path := NodePath("../KeyLight")
@export var profile := "balanced"

var environment_ready := false


func _ready() -> void:
	apply_profile(profile)


func apply_profile(profile_name: String) -> bool:
	if profile_name not in ["low", "balanced", "high"]:
		return false
	profile = profile_name
	var world := get_node_or_null(world_environment_path) as WorldEnvironment
	if world == null:
		return false
	var environment := world.environment
	if environment == null:
		environment = Environment.new()
	world.environment = environment
	# Environment enum values are stable in Godot 4: BG_SKY=2,
	# AMBIENT_SOURCE_SKY=3, ACES tonemapping=2.
	environment.background_mode = 2
	var sky := Sky.new()
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color("#183249")
	sky_material.sky_horizon_color = Color("#a8b5bd")
	sky_material.ground_horizon_color = Color("#756b5c")
	sky_material.ground_bottom_color = Color("#302d2a")
	sky_material.sun_angle_max = 18.0
	sky_material.sun_curve = 0.08
	sky_material.energy_multiplier = 0.85
	sky.sky_material = sky_material
	environment.sky = sky
	environment.ambient_light_source = 3
	environment.ambient_light_energy = 0.7 if profile != "low" else 0.55
	environment.tonemap_mode = 2
	environment.tonemap_exposure = 1.0
	environment.tonemap_white = 1.2
	environment.glow_enabled = profile == "high"
	environment.ssao_enabled = profile != "low"
	environment.ssao_radius = 1.5
	environment.ssao_intensity = 1.4
	environment.fog_enabled = true
	environment.fog_light_color = Color("#9aa9b0")
	environment.fog_light_energy = 0.45
	environment.fog_density = 0.004 if profile == "high" else 0.0025
	environment.fog_height = 0.0
	environment.fog_height_density = 0.04
	var key_light := get_node_or_null(key_light_path) as DirectionalLight3D
	if key_light != null:
		key_light.shadow_enabled = profile != "low"
		key_light.directional_shadow_max_distance = 80.0 if profile == "high" else 55.0
		key_light.light_energy = 1.25 if profile == "high" else 1.1
		key_light.light_color = Color("#fff1d6")
		key_light.light_angular_distance = 0.35
	environment_ready = true
	return true


func get_visual_snapshot() -> Dictionary:
	return {
		"profile": profile,
		"environment_ready": environment_ready,
		"target_fps": 60,
		"renderer": "Forward+",
		"shadows": profile != "low",
	}
