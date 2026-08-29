class_name SoilEffects
extends Node3D

@export var excavation_world_path := NodePath("../TerrainRoot/ExcavationWorld")
@export var max_particles := 5000
@export var emission_enabled := true
@export var max_clods := 48

var _flow_particles: GPUParticles3D
var _flow_material: ParticleProcessMaterial
var _dust_particles: GPUParticles3D
var _dust_material: ParticleProcessMaterial
var _fill_mesh: MeshInstance3D
var _fill_material: StandardMaterial3D
var _last_fill_ratio := -1.0
var _last_cavity_size := Vector3.ZERO
var _generation := -1
var _budget := 1800
var _excavation: ExcavationWorld
var _clods: Array[RigidBody3D] = []
var _clod_ages: Dictionary = {}
var _active_clod_cap := 32
var _clod_spawn_accumulator := 0.0
var _last_visual_snapshot: Dictionary = {}
var _spawn_sequence := 0
var _bucket_ground_mode := BucketGroundInteractionMode.NORMAL
var _update_executed_count := 0
var _update_bypassed_count := 0
var _last_clear_reason := ""


func _ready() -> void:
	_build_fill_mesh()
	_build_particles()
	_build_dust_particles()
	_build_clod_pool()
	_connect_excavation()


func _physics_process(delta: float) -> void:
	if BucketGroundInteractionMode.is_passthrough(_bucket_ground_mode):
		_update_bypassed_count += 1
		return
	_update_executed_count += 1
	if _excavation != null:
		_last_visual_snapshot = _excavation.get_soil_visual_snapshot()
		_apply_visual_snapshot(_last_visual_snapshot)
	_update_clods(delta, _last_visual_snapshot)


func set_budget(count: int) -> void:
	_budget = clampi(count, 0, max_particles)
	if _flow_particles != null:
		_flow_particles.amount = maxi(_budget, 1)
	if _dust_particles != null:
		_dust_particles.amount = maxi(1, mini(720, _budget / 4))
	_active_clod_cap = 0 if _budget < 1000 else (32 if _budget < 3000 else max_clods)


func set_emission_enabled(value: bool) -> void:
	emission_enabled = value
	if emission_enabled:
		return
	if _flow_particles != null:
		_flow_particles.emitting = false
		_flow_particles.restart()
		_flow_particles.emitting = false
	if _dust_particles != null:
		_dust_particles.emitting = false
		_dust_particles.restart()
		_dust_particles.emitting = false
	_clod_spawn_accumulator = 0.0
	for clod in _clods:
		_deactivate_clod(clod)


func set_bucket_ground_mode(value: String) -> bool:
	if not BucketGroundInteractionMode.is_valid(value):
		return false
	if _bucket_ground_mode == value:
		return true
	_bucket_ground_mode = value
	if BucketGroundInteractionMode.is_passthrough(value):
		_last_clear_reason = "bucket_ground_interaction_bypassed"
		clear_for_generation(_generation)
	return true


func clear_for_generation(generation: int) -> void:
	if generation < _generation:
		return
	_generation = generation
	if _flow_particles != null:
		_flow_particles.emitting = false
		_flow_particles.restart()
	if _dust_particles != null:
		_dust_particles.emitting = false
		_dust_particles.restart()
	if _fill_mesh != null:
		_fill_mesh.visible = false
	_last_fill_ratio = -1.0
	_last_cavity_size = Vector3.ZERO
	for clod in _clods:
		_deactivate_clod(clod)


func get_effect_snapshot() -> Dictionary:
	return {
		"enabled": emission_enabled,
		"budget": _budget,
		"generation": _generation,
		"particle_node": _flow_particles != null,
		"particles_emitting": _flow_particles != null and _flow_particles.emitting,
		"dust_node": _dust_particles != null,
		"dust_emitting": _dust_particles != null and _dust_particles.emitting,
		"fill_visible": _fill_mesh != null and _fill_mesh.visible,
		"active_clods": _active_clod_count(),
		"clod_cap": _active_clod_cap,
		"bucket_ground_mode": _bucket_ground_mode,
		"update_executed": _update_executed_count,
		"update_bypassed": _update_bypassed_count,
		"last_clear_reason": _last_clear_reason,
	}


func _build_fill_mesh() -> void:
	_fill_mesh = MeshInstance3D.new()
	_fill_mesh.name = "BucketSoilFill"
	_fill_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_fill_mesh.visible = false
	_fill_material = StandardMaterial3D.new()
	_fill_material.albedo_color = Color("#62442e")
	_fill_material.roughness = 0.94
	_fill_material.metallic = 0.0
	_fill_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_fill_material.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	add_child(_fill_mesh)


func _build_particles() -> void:
	_flow_particles = GPUParticles3D.new()
	_flow_particles.name = "ContinuousSoilFlow"
	_flow_particles.amount = _budget
	_flow_particles.lifetime = 0.95
	_flow_particles.one_shot = false
	_flow_particles.explosiveness = 0.0
	_flow_particles.randomness = 0.45
	_flow_particles.fixed_fps = 30
	_flow_particles.interpolate = true
	_flow_particles.emitting = false
	_flow_material = ParticleProcessMaterial.new()
	_flow_material.direction = Vector3.DOWN
	_flow_material.spread = 24.0
	_flow_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_flow_material.emission_box_extents = Vector3(0.12, 0.035, 0.09)
	_flow_material.initial_velocity_min = 0.5
	_flow_material.initial_velocity_max = 1.8
	_flow_material.gravity = Vector3(0.0, -5.5, 0.0)
	_flow_material.scale_min = 0.45
	_flow_material.scale_max = 1.25
	_flow_particles.process_material = _flow_material
	var grain := BoxMesh.new()
	grain.size = Vector3(0.046, 0.028, 0.061)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("#875a34")
	material.roughness = 1.0
	grain.material = material
	_flow_particles.draw_pass_1 = grain
	_flow_particles.visibility_aabb = AABB(Vector3(-4.0, -4.0, -4.0), Vector3(8.0, 8.0, 8.0))
	add_child(_flow_particles)


func _build_dust_particles() -> void:
	_dust_particles = GPUParticles3D.new()
	_dust_particles.name = "ContactDust"
	_dust_particles.amount = mini(720, _budget / 4)
	_dust_particles.lifetime = 1.35
	_dust_particles.randomness = 0.72
	_dust_particles.fixed_fps = 24
	_dust_particles.emitting = false
	_dust_material = ParticleProcessMaterial.new()
	_dust_material.direction = Vector3.UP
	_dust_material.spread = 48.0
	_dust_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_dust_material.emission_box_extents = Vector3(0.22, 0.035, 0.16)
	_dust_material.initial_velocity_min = 0.18
	_dust_material.initial_velocity_max = 0.72
	_dust_material.gravity = Vector3(0.0, -0.35, 0.0)
	_dust_material.scale_min = 0.35
	_dust_material.scale_max = 1.4
	_dust_particles.process_material = _dust_material
	var mote := QuadMesh.new()
	mote.size = Vector2(0.18, 0.18)
	var dust_color := StandardMaterial3D.new()
	dust_color.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dust_color.albedo_color = Color(0.55, 0.39, 0.24, 0.26)
	dust_color.roughness = 1.0
	dust_color.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	dust_color.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mote.material = dust_color
	_dust_particles.draw_pass_1 = mote
	_dust_particles.visibility_aabb = AABB(Vector3(-5.0, -2.0, -5.0), Vector3(10.0, 7.0, 10.0))
	add_child(_dust_particles)


func _build_clod_pool() -> void:
	for index in max_clods:
		var body := RigidBody3D.new()
		body.name = "SoilClod%02d" % index
		body.mass = 0.12
		body.collision_layer = 1 << 5
		body.collision_mask = 1
		body.freeze = true
		body.visible = false
		body.can_sleep = true
		var mesh_instance := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.09, 0.065, 0.11)
		var material := StandardMaterial3D.new()
		material.albedo_color = Color("#59402e")
		material.roughness = 1.0
		mesh.material = material
		mesh_instance.mesh = mesh
		body.add_child(mesh_instance)
		var collision := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(0.085, 0.06, 0.105)
		collision.shape = shape
		body.add_child(collision)
		add_child(body)
		_clods.append(body)


func _connect_excavation() -> void:
	_excavation = get_node_or_null(excavation_world_path) as ExcavationWorld
	if _excavation == null or _excavation.soil_state == null:
		call_deferred("_connect_excavation")
		return
	if not _excavation.excavation_changed.is_connected(_on_excavation_changed):
		_excavation.excavation_changed.connect(_on_excavation_changed)
	var status := _excavation.get_soil_visual_snapshot()
	_generation = int(status.get("material_generation", -1))
	_apply_visual_snapshot(status)


func _on_excavation_changed(status: Dictionary) -> void:
	if BucketGroundInteractionMode.is_passthrough(_bucket_ground_mode):
		return
	if _excavation != null:
		_apply_visual_snapshot(_excavation.get_soil_visual_snapshot())
	else:
		_apply_visual_snapshot(status)


func _apply_visual_snapshot(status: Dictionary) -> void:
	if BucketGroundInteractionMode.is_passthrough(_bucket_ground_mode):
		return
	var generation := int(status.get("material_generation", -1))
	if generation < _generation:
		return
	if generation > _generation:
		clear_for_generation(generation)
	var pose: Dictionary = status.get("bucket_pose", {})
	var current: Dictionary = pose.get("current", {})
	var contract: Dictionary = pose.get("contract", {})
	_update_fill(status, current, contract)
	_update_flow(status, current, pose)
	_update_dust(status, current)


func _update_fill(status: Dictionary, current: Dictionary, contract: Dictionary) -> void:
	var fill_ratio := clampf(float(status.get("fill_ratio", 0.0)), 0.0, 1.0)
	if fill_ratio <= 0.001 or not current.has("cavity"):
		_fill_mesh.visible = false
		return
	var cavity_contract: Dictionary = (contract.get("proxies", {}) as Dictionary).get("cavity", {})
	var raw_size: Variant = cavity_contract.get("size_m", [])
	if not raw_size is Array or (raw_size as Array).size() != 3:
		_fill_mesh.visible = false
		return
	var cavity_size := Vector3(float(raw_size[0]), float(raw_size[1]), float(raw_size[2]))
	var fill_height := cavity_size.y * clampf(pow(fill_ratio, 0.72), 0.08, 1.0)
	if absf(fill_ratio - _last_fill_ratio) > 0.01 or not cavity_size.is_equal_approx(_last_cavity_size):
		_rebuild_fill_surface(
			cavity_size,
			fill_height,
			fill_ratio,
			status.get("fill_profile", PackedFloat32Array()),
			status.get("cell_grid", [1, 1, 1])
		)
		_last_fill_ratio = fill_ratio
		_last_cavity_size = cavity_size
	var cavity_transform: Transform3D = current["cavity"]
	_fill_mesh.global_transform = cavity_transform
	_fill_mesh.visible = true


func _update_flow(status: Dictionary, current: Dictionary, pose: Dictionary) -> void:
	if not emission_enabled or _budget <= 0:
		_flow_particles.emitting = false
		return
	var interaction := String(status.get("interaction_state", "idle"))
	var active := interaction == "cut" or interaction == "spill" or interaction == "dump"
	if not active or float(status.get("flow_volume_m3", 0.0)) <= BucketSoilState.EPSILON_M3:
		_flow_particles.emitting = false
		return
	var proxy_name := "cutting_edge" if interaction == "cut" else "opening"
	if not current.has(proxy_name):
		_flow_particles.emitting = false
		return
	var source: Transform3D = current[proxy_name]
	var direction := pose.get("cutting_direction_world", Vector3.DOWN) as Vector3
	if interaction == "dump" or interaction == "spill":
		var opening_normal := pose.get("opening_normal_world", Vector3.DOWN) as Vector3
		if not opening_normal.is_zero_approx():
			source.origin += opening_normal.normalized() * 0.24
			direction = (opening_normal.normalized() * 0.65 + Vector3.DOWN * 0.85).normalized()
		else:
			direction = Vector3.DOWN
	_flow_particles.global_transform = Transform3D(Basis.IDENTITY, source.origin)
	_flow_material.direction = direction.normalized()
	_flow_material.initial_velocity_min = 0.45 if interaction == "cut" else (0.55 if interaction == "spill" else 0.7)
	_flow_material.initial_velocity_max = 1.35 if interaction == "cut" else (1.45 if interaction == "spill" else 2.1)
	_flow_particles.emitting = true


func _update_dust(status: Dictionary, current: Dictionary) -> void:
	if not emission_enabled or _budget < 400 or _dust_particles == null:
		if _dust_particles != null:
			_dust_particles.emitting = false
		return
	var response := status.get("digging_response", {}) as Dictionary
	var phase := String(response.get("phase", response.get("raw_phase", "free")))
	var intensity := clampf(float(response.get("intensity", 0.0)), 0.0, 1.0)
	if phase not in ["contact", "scrape", "cut", "load", "blocked"] or intensity < 0.12 or not current.has("cutting_edge"):
		_dust_particles.emitting = false
		return
	var source := current["cutting_edge"] as Transform3D
	_dust_particles.global_position = source.origin
	_dust_material.initial_velocity_max = lerpf(0.42, 1.05, intensity)
	_dust_material.scale_max = lerpf(0.75, 1.8, intensity)
	_dust_particles.emitting = true


func _update_clods(delta: float, status: Dictionary) -> void:
	for clod in _clods:
		if clod.freeze:
			continue
		var age := float(_clod_ages.get(clod.get_instance_id(), 0.0)) + delta
		_clod_ages[clod.get_instance_id()] = age
		if age > 2.5 or clod.global_position.y < -2.0 or clod.sleeping:
			_deactivate_clod(clod)
	if _active_clod_cap <= 0 or not bool(status.get("hero_clods_enabled", true)):
		return
	var interaction := String(status.get("interaction_state", "idle"))
	if (
		(interaction != "cut" and interaction != "spill" and interaction != "dump")
		or float(status.get("flow_volume_m3", 0.0)) <= BucketSoilState.EPSILON_M3
	):
		_clod_spawn_accumulator = 0.0
		return
	_clod_spawn_accumulator += delta * (7.0 if interaction == "cut" else (5.0 if interaction == "spill" else 11.0))
	while _clod_spawn_accumulator >= 1.0 and _active_clod_count() < _active_clod_cap:
		_clod_spawn_accumulator -= 1.0
		if not _spawn_clod(status, interaction):
			break


func _spawn_clod(status: Dictionary, interaction: String) -> bool:
	var pose: Dictionary = status.get("bucket_pose", {})
	var current: Dictionary = pose.get("current", {})
	var proxy_name := "cutting_edge" if interaction == "cut" else "opening"
	if not current.has(proxy_name):
		return false
	var available: RigidBody3D
	for clod in _clods:
		if clod.freeze:
			available = clod
			break
	if available == null:
		return false
	var source: Transform3D = current[proxy_name]
	var source_origin := source.origin
	if interaction == "dump" or interaction == "spill":
		var opening_normal := pose.get("opening_normal_world", Vector3.DOWN) as Vector3
		if not opening_normal.is_zero_approx():
			source_origin += opening_normal.normalized() * 0.2
	_spawn_sequence += 1
	var noise_x := _spawn_noise(_spawn_sequence, 17)
	var noise_y := _spawn_noise(_spawn_sequence, 29)
	var noise_z := _spawn_noise(_spawn_sequence, 43)
	available.global_position = source_origin + Vector3(noise_x * 0.08, 0.04, noise_z * 0.08)
	available.scale = Vector3(0.72 + absf(noise_x) * 0.48, 0.62 + absf(noise_y) * 0.5, 0.78 + absf(noise_z) * 0.45)
	available.freeze = false
	available.sleeping = false
	available.visible = true
	var lateral := Vector3(noise_x * 0.35, lerpf(0.1, 0.45, (noise_y + 1.0) * 0.5), noise_z * 0.35)
	available.linear_velocity = lateral if interaction == "cut" else lateral + Vector3.DOWN * 0.8
	available.angular_velocity = Vector3(noise_z, noise_x, noise_y) * 4.0
	_clod_ages[available.get_instance_id()] = 0.0
	return true


func _deactivate_clod(clod: RigidBody3D) -> void:
	clod.freeze = true
	clod.sleeping = true
	clod.visible = false
	clod.linear_velocity = Vector3.ZERO
	clod.angular_velocity = Vector3.ZERO
	_clod_ages.erase(clod.get_instance_id())


func _active_clod_count() -> int:
	var count := 0
	for clod in _clods:
		if not clod.freeze:
			count += 1
	return count


func _spawn_noise(sequence: int, salt: int) -> float:
	var value := sequence * 374761393 + salt * 668265263
	value = (value ^ (value >> 13)) * 1274126177
	value = value ^ (value >> 16)
	return float(value & 0xffff) / 32767.5 - 1.0


func _rebuild_fill_surface(
	cavity_size: Vector3,
	fill_height: float,
	fill_ratio: float,
	profile_value: Variant,
	grid_value: Variant
) -> void:
	var columns := 7
	var rows := 5
	if grid_value is Array and (grid_value as Array).size() == 3:
		columns = maxi(2, int(grid_value[0]))
		rows = maxi(2, int(grid_value[2]))
	var profile := profile_value as PackedFloat32Array if profile_value is PackedFloat32Array else PackedFloat32Array()
	var vertices := PackedVector3Array()
	for row in rows:
		var z_unit := float(row) / float(rows - 1)
		var z := lerpf(-0.43 * cavity_size.z, 0.43 * cavity_size.z, z_unit)
		for column in columns:
			var x_unit := float(column) / float(columns - 1)
			var x := lerpf(-0.45 * cavity_size.x, 0.45 * cavity_size.x, x_unit)
			var normalized_x := absf(x) / maxf(0.001, 0.45 * cavity_size.x)
			var normalized_z := absf(z) / maxf(0.001, 0.43 * cavity_size.z)
			var mound := maxf(0.0, 1.0 - 0.55 * normalized_x * normalized_x - 0.38 * normalized_z * normalized_z)
			var heaping := lerpf(0.04, 0.22, clampf((fill_ratio - 0.55) / 0.45, 0.0, 1.0))
			var local_fill := fill_ratio
			var profile_index := row * columns + column
			if profile_index < profile.size():
				local_fill = clampf(profile[profile_index], 0.0, 1.0)
			var local_height := cavity_size.y * clampf(pow(local_fill, 0.72), 0.02, 1.0)
			var y := -0.5 * cavity_size.y + maxf(local_height, 0.15 * fill_height) * (0.82 + heaping * mound)
			vertices.append(Vector3(x, y, z))
	var indices := PackedInt32Array()
	for row in rows - 1:
		for column in columns - 1:
			var top_left := row * columns + column
			var top_right := top_left + 1
			var bottom_left := (row + 1) * columns + column
			var bottom_right := bottom_left + 1
			indices.append_array([top_left, bottom_left, top_right, top_right, bottom_left, bottom_right])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var normals := PackedVector3Array()
	normals.resize(vertices.size())
	for index in normals.size():
		normals[index] = Vector3.UP
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _fill_material)
	_fill_mesh.mesh = mesh
