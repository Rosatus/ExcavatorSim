class_name SoilEffects
extends Node3D

@export var excavation_world_path := NodePath("../TerrainRoot/ExcavationWorld")
@export var max_particles := 96
@export var emission_enabled := true

var _particles: GPUParticles3D
var _generation := -1
var _budget := 96


func _ready() -> void:
	_build_particles()
	_connect_excavation()


func set_budget(count: int) -> void:
	_budget = clampi(count, 0, max_particles)
	if _particles != null:
		_particles.amount = _budget


func clear_for_generation(generation: int) -> void:
	if generation < _generation:
		return
	_generation = generation
	if _particles != null:
		_particles.restart()
		_particles.emitting = false


func get_effect_snapshot() -> Dictionary:
	return {
		"enabled": emission_enabled,
		"budget": _budget,
		"generation": _generation,
		"particle_node": _particles != null,
	}


func _build_particles() -> void:
	_particles = GPUParticles3D.new()
	_particles.name = "SoilDustParticles"
	_particles.amount = _budget
	_particles.lifetime = 0.8
	_particles.one_shot = true
	_particles.emitting = false
	var process_material := ParticleProcessMaterial.new()
	process_material.direction = Vector3.UP
	process_material.spread = 38.0
	process_material.initial_velocity_min = 0.35
	process_material.initial_velocity_max = 1.1
	process_material.gravity = Vector3(0.0, -2.8, 0.0)
	process_material.scale_min = 0.55
	process_material.scale_max = 1.15
	_particles.process_material = process_material
	var clump := SphereMesh.new()
	clump.radius = 0.025
	clump.height = 0.05
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("#6b4c32")
	material.roughness = 0.95
	clump.material = material
	_particles.draw_pass_1 = clump
	_particles.visibility_aabb = AABB(Vector3(-2.0, -1.0, -2.0), Vector3(4.0, 4.0, 4.0))
	add_child(_particles)


func _connect_excavation() -> void:
	var excavation := get_node_or_null(excavation_world_path) as ExcavationWorld
	if excavation == null:
		call_deferred("_connect_excavation")
		return
	excavation.excavation_changed.connect(_on_excavation_changed)
	_generation = int(excavation.get_status_snapshot().get("world_generation", -1))


func _on_excavation_changed(status: Dictionary) -> void:
	var generation := int(status.get("world_generation", -1))
	if generation < _generation:
		return
	if generation > _generation:
		clear_for_generation(generation)
		return
	if not emission_enabled or _particles == null:
		return
	var changed := bool(status.get("last_result", {}).get("changed", false))
	if changed:
		_particles.restart()
		_particles.emitting = true
