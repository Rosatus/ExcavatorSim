class_name SoilEffects
extends Node3D

const VisualResources = preload("res://scripts/soil_visual_resources.gd")
const BucketFillSurface = preload("res://scripts/bucket_fill_surface.gd")
const SoilFlight = preload("res://scripts/soil_flight.gd")

const VISUAL_SNAPSHOT_PERIOD_S := 1.0 / 30.0
const FILL_UPDATE_PERIOD_S := 0.1
const FILL_RATIO_QUANTUM := 0.05
const RELEASE_EVENT_MIN_TTL_S := 0.1
const RELEASE_EVENT_MAX_TTL_S := 0.14

@export var excavation_world_path := NodePath("../TerrainRoot/ExcavationWorld")
@export var motion_presentation_path := NodePath("../MotionPresentation")
@export var max_particles := 5000
@export var emission_enabled := true
@export var max_clods := 48
@export var max_visual_mounds := 24

var _flow_particles: GPUParticles3D
var _flow_material: ParticleProcessMaterial
var _dust_particles: GPUParticles3D
var _dust_material: ParticleProcessMaterial
var _fill_mesh: MeshInstance3D
var _fill_array_mesh: ArrayMesh
var _fill_material: StandardMaterial3D
var _last_fill_ratio := -1.0
var _last_cavity_size := Vector3.ZERO
var _last_fill_model_id := ""
var _fill_surface := BucketFillSurface.new()
var _generation := -1
var _budget := 1800
var _excavation: ExcavationWorld
var _presentation: MotionPresentation
var _requires_live_fill_frame := false
var _clods: Array[RigidBody3D] = []
var _active_clods: Array[RigidBody3D] = []
var _free_clods: Array[RigidBody3D] = []
var _clod_ages: Dictionary = {}
var _clod_landing_heights: Dictionary = {}
var _release_clod_budget := 0.0
var _active_clod_cap := 32
var _clod_spawn_accumulator := 0.0
var _last_visual_snapshot: Dictionary = {}
var _spawn_sequence := 0
var _bucket_ground_mode := BucketGroundInteractionMode.NORMAL
var _update_executed_count := 0
var _update_bypassed_count := 0
var _last_clear_reason := ""
var _visual_mounds: Array[MeshInstance3D] = []
var _visual_mound_cursor := 0
var _last_visual_mound_event_id := ""
var _last_rejected_dump_event_id := ""
var _rejected_dump_effect_count := 0
var _snapshot_poll_accumulator_s := 0.0
var _fill_update_accumulator_s := FILL_UPDATE_PERIOD_S
var _snapshot_pull_count := 0
var _fill_rebuild_count := 0
var _active_release_event: Dictionary = {}
var _last_release_event_id := ""
var _release_event_elapsed_s := 0.0
var _release_event_ttl_s := 0.0


func _ready() -> void:
	_build_fill_mesh()
	_build_particles()
	_build_dust_particles()
	_build_clod_pool()
	_build_visual_mound_pool()
	_presentation = get_node_or_null(motion_presentation_path) as MotionPresentation
	_requires_live_fill_frame = _presentation != null
	if _presentation != null:
		_presentation.model_replacing.connect(_on_fill_model_replacing)
	_connect_excavation()


func _exit_tree() -> void:
	# The mesh may currently belong to the imported bucket rather than this node.
	if is_instance_valid(_fill_mesh) and _fill_mesh.get_parent() != self:
		_fill_mesh.queue_free()


func _park_fill_mesh() -> void:
	if not is_instance_valid(_fill_mesh):
		_build_fill_mesh()
	_fill_mesh.visible = false
	if _fill_mesh.get_parent() != self:
		_fill_mesh.reparent(self, false)
	_fill_mesh.transform = Transform3D.IDENTITY


func _on_fill_model_replacing() -> void:
	# Reclaim before replacement, including candidates whose contract fails.
	_park_fill_mesh()
	_last_fill_ratio = -1.0


func _bind_fill_pose(model_id: String, cavity_contract: Dictionary, current: Dictionary) -> bool:
	if not is_instance_valid(_presentation):
		if _requires_live_fill_frame:
			return false
		# Isolated compatibility/test consumers can supply explicit world poses.
		_fill_mesh.global_transform = current["cavity"]
		return true
	if model_id != _presentation.get_active_model_id():
		return false
	var frame := _presentation.get_frame_node(String(cavity_contract.get("frame", "")))
	if not is_instance_valid(frame):
		return false
	if _fill_mesh.get_parent() != frame:
		_fill_mesh.reparent(frame, false)
	_fill_mesh.transform = _presentation.get_soil_proxy_local_transform("cavity")
	return true


func _physics_process(delta: float) -> void:
	if BucketGroundInteractionMode.is_passthrough(_bucket_ground_mode):
		_update_bypassed_count += 1
		return
	_update_executed_count += 1
	_snapshot_poll_accumulator_s += delta
	_fill_update_accumulator_s += delta
	if _excavation != null and _snapshot_poll_accumulator_s + 0.000001 >= VISUAL_SNAPSHOT_PERIOD_S:
		_snapshot_poll_accumulator_s = fmod(_snapshot_poll_accumulator_s, VISUAL_SNAPSHOT_PERIOD_S)
		_last_visual_snapshot = _excavation.get_soil_visual_snapshot()
		_snapshot_pull_count += 1
		_apply_visual_snapshot(_last_visual_snapshot)
	_advance_release_event(delta)
	_update_release_source(_last_visual_snapshot)
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
	_active_release_event.clear()
	_release_clod_budget = 0.0
	if _flow_particles != null:
		_flow_particles.emitting = false
		_flow_particles.restart()
		_flow_particles.emitting = false
	if _dust_particles != null:
		_dust_particles.emitting = false
		_dust_particles.restart()
		_dust_particles.emitting = false
	_clod_spawn_accumulator = 0.0
	_reset_clod_pool()


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
	_park_fill_mesh()
	_last_fill_ratio = -1.0
	_last_cavity_size = Vector3.ZERO
	_last_fill_model_id = ""
	_fill_update_accumulator_s = FILL_UPDATE_PERIOD_S
	_snapshot_poll_accumulator_s = 0.0
	_reset_clod_pool()
	_clear_visual_mounds()
	_last_rejected_dump_event_id = ""
	_active_release_event.clear()
	_last_release_event_id = ""
	_release_event_elapsed_s = 0.0
	_release_event_ttl_s = 0.0
	_release_clod_budget = 0.0


func get_effect_snapshot() -> Dictionary:
	return {
		"enabled": emission_enabled,
		"budget": _budget,
		"generation": _generation,
		"particle_node": _flow_particles != null,
		"particles_emitting": _flow_particles != null and _flow_particles.emitting,
		"dust_node": _dust_particles != null,
		"dust_emitting": _dust_particles != null and _dust_particles.emitting,
		"fill_visible": is_instance_valid(_fill_mesh) and _fill_mesh.visible,
		"active_clods": _active_clod_count(),
		"clod_cap": _active_clod_cap,
		"active_visual_mounds": _active_visual_mound_count(),
		"visual_mound_cap": _visual_mounds.size(),
		"rejected_dump_effect_count": _rejected_dump_effect_count,
		"last_visual_mound_event_id": _last_visual_mound_event_id,
		"bucket_ground_mode": _bucket_ground_mode,
		"update_executed": _update_executed_count,
		"update_bypassed": _update_bypassed_count,
		"last_clear_reason": _last_clear_reason,
		"snapshot_pull_count": _snapshot_pull_count,
		"fill_rebuild_count": _fill_rebuild_count,
		"snapshot_poll_hz": 1.0 / VISUAL_SNAPSHOT_PERIOD_S,
		"fill_update_hz": 1.0 / FILL_UPDATE_PERIOD_S,
		"fill_ratio_quantum": FILL_RATIO_QUANTUM,
		"active_release_event_id": String(_active_release_event.get("event_id", "")),
		"last_release_event_id": _last_release_event_id,
		"release_event_age_s": _release_event_elapsed_s,
		"release_event_ttl_s": _release_event_ttl_s,
	}


func _build_fill_mesh() -> void:
	_fill_mesh = MeshInstance3D.new()
	_fill_mesh.name = "BucketSoilFill"
	_fill_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_fill_mesh.visible = false
	_fill_material = VisualResources.surface_material()
	_fill_material.vertex_color_use_as_albedo = true
	_fill_material.metallic = 0.0
	_fill_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_fill_material.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	if _fill_array_mesh == null:
		_fill_array_mesh = ArrayMesh.new()
	_fill_mesh.mesh = _fill_array_mesh
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
	_flow_particles.local_coords = false
	_flow_particles.emitting = false
	_flow_material = ParticleProcessMaterial.new()
	_flow_material.direction = Vector3.DOWN
	_flow_material.spread = 12.0
	_flow_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_flow_material.emission_box_extents = Vector3(0.12, 0.035, 0.09)
	_flow_material.initial_velocity_min = 0.5
	_flow_material.initial_velocity_max = 1.8
	_flow_material.gravity = Vector3.DOWN * SoilFlight.GRAVITY
	_flow_material.scale_min = 0.35
	_flow_material.scale_max = 1.35
	_flow_material.angle_min = -180.0
	_flow_material.angle_max = 180.0
	_flow_material.angular_velocity_min = -120.0
	_flow_material.angular_velocity_max = 120.0
	_flow_particles.process_material = _flow_material
	var grain := VisualResources.clod_mesh(Vector3(0.042, 0.036, 0.05))
	_flow_particles.draw_pass_1 = grain
	_flow_particles.visibility_aabb = AABB(Vector3(-6.0, -48.0, -6.0), Vector3(12.0, 52.0, 12.0))
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
	dust_color.albedo_texture = VisualResources.dust_texture()
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
		body.gravity_scale = SoilFlight.GRAVITY / maxf(0.001, float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)))
		body.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
		body.linear_damp = 0.0
		body.collision_layer = 1 << 5
		body.collision_mask = 1
		body.freeze = true
		body.visible = false
		body.can_sleep = true
		var mesh_instance := MeshInstance3D.new()
		var mesh := VisualResources.clod_mesh(Vector3(0.09, 0.075, 0.105), index % 4)
		mesh_instance.mesh = mesh
		body.add_child(mesh_instance)
		var collision := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(0.085, 0.06, 0.105)
		collision.shape = shape
		body.add_child(collision)
		add_child(body)
		_clods.append(body)
		_free_clods.append(body)


func _build_visual_mound_pool() -> void:
	var mound_mesh := SphereMesh.new()
	mound_mesh.radius = 0.5
	mound_mesh.height = 1.0
	mound_mesh.radial_segments = 12
	mound_mesh.rings = 6
	var mound_material := StandardMaterial3D.new()
	mound_material.albedo_color = Color("#765537")
	mound_material.roughness = 1.0
	mound_material.metallic = 0.0
	mound_mesh.material = mound_material
	for index in maxi(max_visual_mounds, 0):
		var mound := MeshInstance3D.new()
		mound.name = "VisualSoilMound%02d" % index
		mound.mesh = mound_mesh
		mound.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		mound.visible = false
		add_child(mound)
		_visual_mounds.append(mound)


func _connect_excavation() -> void:
	if excavation_world_path.is_empty():
		return
	_excavation = get_node_or_null(excavation_world_path) as ExcavationWorld
	if _excavation == null or not _excavation.is_soil_runtime_ready():
		call_deferred("_connect_excavation")
		return
	if not _excavation.excavation_changed.is_connected(_on_excavation_changed):
		_excavation.excavation_changed.connect(_on_excavation_changed)
	var status := _excavation.get_soil_visual_snapshot()
	_snapshot_pull_count += 1
	_generation = int(status.get("material_generation", -1))
	_apply_visual_snapshot(status)


func _on_excavation_changed(status: Dictionary) -> void:
	if BucketGroundInteractionMode.is_passthrough(_bucket_ground_mode):
		return
	if _excavation != null:
		_last_visual_snapshot = _excavation.get_soil_visual_snapshot()
		_snapshot_pull_count += 1
		_snapshot_poll_accumulator_s = 0.0
		_apply_visual_snapshot(_last_visual_snapshot)
	else:
		_last_visual_snapshot = status.duplicate(true)
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
	_consume_release_event(status, pose)
	_update_release_source(status)
	_update_fill(status, current, contract)
	_update_flow(status, current, pose)
	_update_dust(status, current)
	_update_visual_mound(status)
	_update_rejected_dump_feedback(status)


func apply_visual_snapshot_for_test(status: Dictionary) -> void:
	_last_visual_snapshot = status.duplicate(true)
	_apply_visual_snapshot(status)


func advance_release_visual_for_test(delta: float) -> void:
	_advance_release_event(delta)
	_update_flow(_last_visual_snapshot, {}, {})


func _consume_release_event(status: Dictionary, pose: Dictionary) -> void:
	var event := status.get("accepted_dump_event", {}) as Dictionary
	var event_id := String(event.get("event_id", status.get("accepted_dump_event_id", "")))
	if event_id.is_empty() or event_id == _last_release_event_id:
		return
	if event.is_empty():
		event = _release_event_from_live_pose(status, pose)
	if event.is_empty():
		return
	event["event_id"] = event_id
	var release_transform := event.get("release_transform_world", Transform3D.IDENTITY) as Transform3D
	var direction := event.get("direction_world", Vector3.DOWN) as Vector3
	if not release_transform.origin.is_finite() or not direction.is_finite() or direction.is_zero_approx():
		return
	_last_release_event_id = event_id
	if event.has("published_usec"):
		var age_s := maxf(0.0, float(Time.get_ticks_usec() - int(event["published_usec"])) / 1000000.0)
		if age_s > float(event.get("release_duration_s", RELEASE_EVENT_MAX_TTL_S)) + 0.02:
			# The stable terrain is already committed. Never replay stale decoration.
			return
	if not emission_enabled or _budget <= 0:
		return
	_active_release_event = event.duplicate(true)
	if bool(event.get("release_committed", false)):
		var contract := pose.get("contract", {}) as Dictionary
		var proxy := (contract.get("proxies", {}) as Dictionary).get("opening", {}) as Dictionary
		var size := proxy.get("size_m", [0.6, 0.3]) as Array
		var across := release_transform.basis.x.normalized().abs() * float(size[0]) * 0.32
		_flow_material.emission_box_extents = Vector3(maxf(0.04, across.x), 0.025, maxf(0.04, across.z))
	_last_release_event_id = event_id
	_release_event_elapsed_s = 0.0
	var released_volume := maxf(0.0, float(event.get("accepted_volume_m3", 0.0)))
	_release_event_ttl_s = clampf(
		float(event.get("release_duration_s", RELEASE_EVENT_MIN_TTL_S)) + 0.02,
		RELEASE_EVENT_MIN_TTL_S,
		RELEASE_EVENT_MAX_TTL_S,
	)
	_release_clod_budget = minf(float(max_clods), _release_clod_budget + released_volume * 55.0)
	# Continuous batches must not restart particles already falling in world space.
	if _flow_particles != null:
		_flow_particles.amount_ratio = clampf(released_volume / _release_event_ttl_s / 0.65, 0.0, 1.0)


func _advance_release_event(delta: float) -> void:
	if _active_release_event.is_empty():
		return
	_release_event_elapsed_s += maxf(0.0, delta)
	if _release_event_elapsed_s + 0.000001 < _release_event_ttl_s:
		return
	_active_release_event.clear()
	_clod_spawn_accumulator = 0.0
	_release_clod_budget = 0.0
	if _flow_particles != null:
		_flow_particles.emitting = false


func _update_release_source(status: Dictionary) -> void:
	if String(status.get("soil_material_lifecycle_mode", "")) != "voxel" or _active_release_event.is_empty():
		return
	if bool(_active_release_event.get("release_committed", false)):
		# A committed release is already outside the bucket. Its short emission
		# segment uses the frozen source and survives a later gate closure.
		return
	if not bool(status.get("dump_gate_active", false)):
		_active_release_event.clear()
		_release_clod_budget = 0.0
		_clod_spawn_accumulator = 0.0
		_flow_particles.emitting = false
		return
	var pose := status.get("bucket_pose", {}) as Dictionary
	var current := pose.get("current", {}) as Dictionary
	if current.has("opening"):
		# Only the emitter follows the current outlet. Already born particles
		# remain in world space; the immutable transaction is never modified.
		_active_release_event["release_transform_world"] = current["opening"]
		_active_release_event["opening_normal_world"] = pose.get("opening_normal_world", Vector3.DOWN)
		_active_release_event["direction_world"] = Vector3.DOWN
		var contract := pose.get("contract", {}) as Dictionary
		var opening_proxy := (contract.get("proxies", {}) as Dictionary).get("opening", {}) as Dictionary
		var opening_size := opening_proxy.get("size_m", [1.0, 0.5]) as Array
		var source := current["opening"] as Transform3D
		var across := source.basis.x.normalized().abs() * float(opening_size[0]) * 0.32
		_flow_material.emission_box_extents = Vector3(maxf(0.04, across.x), 0.025, maxf(0.04, across.z))


func _release_event_from_live_pose(status: Dictionary, pose: Dictionary) -> Dictionary:
	var interaction := String(status.get("interaction_state", "idle"))
	var event_id := String(status.get("accepted_dump_event_id", ""))
	if interaction not in ["spill", "dump"] and event_id.is_empty():
		return {}
	var current := pose.get("current", {}) as Dictionary
	if not current.has("opening"):
		return {}
	var opening := current["opening"] as Transform3D
	var release_world := status.get("dump_release_world", opening.origin) as Vector3
	opening.origin = release_world
	var opening_normal := pose.get("opening_normal_world", Vector3.DOWN) as Vector3
	if not opening_normal.is_finite() or opening_normal.is_zero_approx():
		opening_normal = Vector3.DOWN
	else:
		opening_normal = opening_normal.normalized()
	return {
		"event_id": event_id,
		"accepted_volume_m3": maxf(0.0, float(status.get("flow_volume_m3", 0.0))),
		"release_transform_world": opening,
		"release_world": release_world,
		"opening_normal_world": opening_normal,
		"direction_world": (opening_normal * 0.65 + Vector3.DOWN * 0.85).normalized(),
		"fill_ratio": float(status.get("dump_released_fill_ratio", status.get("fill_ratio", 0.0))),
	}


func _update_fill(status: Dictionary, current: Dictionary, contract: Dictionary) -> void:
	if not is_instance_valid(_fill_mesh):
		_build_fill_mesh()
		_last_fill_ratio = -1.0
	var fill_ratio := clampf(float(status.get("fill_ratio", 0.0)), 0.0, 1.0)
	if fill_ratio <= 0.001 or not current.has("cavity"):
		_fill_mesh.visible = false
		_last_fill_ratio = -1.0
		return
	var cavity_contract: Dictionary = (contract.get("proxies", {}) as Dictionary).get("cavity", {})
	var raw_size: Variant = cavity_contract.get("size_m", [])
	if not raw_size is Array or (raw_size as Array).size() != 3:
		_fill_mesh.visible = false
		_last_fill_ratio = -1.0
		return
	var cavity_size := Vector3(float(raw_size[0]), float(raw_size[1]), float(raw_size[2]))
	var quantized_fill_ratio := clampf(
		roundf(fill_ratio / FILL_RATIO_QUANTUM) * FILL_RATIO_QUANTUM,
		0.0,
		1.0,
	)
	if quantized_fill_ratio <= 0.0:
		quantized_fill_ratio = fill_ratio
	var model_id := String(contract.get("model_id", ""))
	var cavity_changed := not cavity_size.is_equal_approx(_last_cavity_size)
	var model_changed := model_id != _last_fill_model_id
	var first_fill := _last_fill_ratio < 0.0
	var quantized_changed := absf(quantized_fill_ratio - _last_fill_ratio) + 0.000001 >= FILL_RATIO_QUANTUM
	if cavity_changed or model_changed or first_fill or (
		quantized_changed and _fill_update_accumulator_s + 0.000001 >= FILL_UPDATE_PERIOD_S
	):
		if cavity_changed or model_changed or first_fill:
			if not _fill_surface.configure(model_id, cavity_size):
				_fill_mesh.visible = false
				_last_fill_ratio = -1.0
				return
		_rebuild_fill_surface(quantized_fill_ratio)
		_last_fill_ratio = quantized_fill_ratio
		_last_cavity_size = cavity_size
		_last_fill_model_id = model_id
		_fill_update_accumulator_s = 0.0
	_fill_mesh.visible = _bind_fill_pose(model_id, cavity_contract, current) and _fill_array_mesh.get_surface_count() > 0


func _update_flow(status: Dictionary, current: Dictionary, pose: Dictionary) -> void:
	if not emission_enabled or _budget <= 0:
		_flow_particles.emitting = false
		return
	if not _active_release_event.is_empty():
		_apply_flow_release_event(_active_release_event)
		return
	if String(status.get("soil_material_lifecycle_mode", "")) == "voxel":
		_flow_particles.emitting = false
		return
	var interaction := String(status.get("interaction_state", "idle"))
	var active := interaction == "spill" or interaction == "dump"
	if not active or float(status.get("flow_volume_m3", 0.0)) <= BucketSoilState.EPSILON_M3:
		_flow_particles.emitting = false
		return
	if not current.has("opening"):
		_flow_particles.emitting = false
		return
	var fallback_event := _release_event_from_live_pose(status, pose)
	if fallback_event.is_empty():
		_flow_particles.emitting = false
		return
	_apply_flow_release_event(fallback_event)


func _apply_flow_release_event(event: Dictionary) -> void:
	var source := event.get("release_transform_world", Transform3D.IDENTITY) as Transform3D
	var opening_normal := event.get("opening_normal_world", Vector3.DOWN) as Vector3
	var direction := event.get("direction_world", Vector3.DOWN) as Vector3
	if opening_normal.is_finite() and not opening_normal.is_zero_approx():
		source.origin += opening_normal.normalized() * 0.05
	if not direction.is_finite() or direction.is_zero_approx():
		direction = Vector3.DOWN
	_flow_particles.global_transform = Transform3D(Basis.IDENTITY, source.origin)
	_flow_material.direction = Vector3.DOWN
	_flow_material.initial_velocity_min = SoilFlight.INITIAL_SPEED
	_flow_material.initial_velocity_max = SoilFlight.INITIAL_SPEED
	if event.has("landing_world"):
		var landing := event["landing_world"] as Vector3
		_flow_particles.lifetime = clampf(SoilFlight.duration(source.origin, landing), 0.12, SoilFlight.MAX_FLIGHT_S)
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
	for index in range(_active_clods.size() - 1, -1, -1):
		var clod := _active_clods[index]
		var age := float(_clod_ages.get(clod.get_instance_id(), 0.0)) + delta
		_clod_ages[clod.get_instance_id()] = age
		var landing_y := float(_clod_landing_heights.get(clod.get_instance_id(), -INF))
		if age > SoilFlight.MAX_FLIGHT_S + 0.2 or clod.global_position.y < -6.0 or clod.sleeping \
				or (age > 0.08 and clod.global_position.y <= landing_y + 0.04):
			_deactivate_active_clod(index)
	if not emission_enabled or _budget <= 0 or _active_clod_cap <= 0 or not bool(status.get("hero_clods_enabled", true)):
		return
	var release_event := _active_release_event
	if release_event.is_empty() and String(status.get("soil_material_lifecycle_mode", "")) != "voxel":
		var interaction := String(status.get("interaction_state", "idle"))
		if interaction in ["spill", "dump"] \
				and float(status.get("flow_volume_m3", 0.0)) > BucketSoilState.EPSILON_M3:
			release_event = _release_event_from_live_pose(status, status.get("bucket_pose", {}) as Dictionary)
	if release_event.is_empty():
		_clod_spawn_accumulator = 0.0
		return
	_clod_spawn_accumulator += delta * 11.0
	while _clod_spawn_accumulator >= 1.0 and _active_clods.size() < _active_clod_cap:
		_clod_spawn_accumulator -= 1.0
		if _release_clod_budget < 1.0:
			break
		if not _spawn_clod_from_event(release_event):
			break
		_release_clod_budget -= 1.0


func _spawn_clod(status: Dictionary, interaction: String) -> bool:
	if interaction == "cut":
		return false
	return _spawn_clod_from_event(_release_event_from_live_pose(status, status.get("bucket_pose", {}) as Dictionary))


func _spawn_clod_from_event(event: Dictionary) -> bool:
	if event.is_empty():
		return false
	if _free_clods.is_empty():
		return false
	var available := _free_clods.pop_back() as RigidBody3D
	_active_clods.append(available)
	var source := event.get("release_transform_world", Transform3D.IDENTITY) as Transform3D
	var source_origin := source.origin
	var opening_normal := event.get("opening_normal_world", Vector3.DOWN) as Vector3
	if opening_normal.is_finite() and not opening_normal.is_zero_approx():
		source_origin += opening_normal.normalized() * 0.05
	_spawn_sequence += 1
	var noise_x := _spawn_noise(_spawn_sequence, 17)
	var noise_y := _spawn_noise(_spawn_sequence, 29)
	var noise_z := _spawn_noise(_spawn_sequence, 43)
	available.global_position = source_origin + Vector3(noise_x * 0.08, 0.04, noise_z * 0.08)
	available.scale = Vector3(0.72 + absf(noise_x) * 0.48, 0.62 + absf(noise_y) * 0.5, 0.78 + absf(noise_z) * 0.45)
	available.freeze = false
	available.sleeping = false
	available.visible = true
	var lateral := Vector3(noise_x * 0.35, 0.0, noise_z * 0.35)
	var direction := event.get("direction_world", Vector3.DOWN) as Vector3
	if not direction.is_finite() or direction.is_zero_approx():
		direction = Vector3.DOWN
	available.linear_velocity = lateral + direction.normalized() * SoilFlight.INITIAL_SPEED
	available.angular_velocity = Vector3(noise_z, noise_x, noise_y) * 4.0
	_clod_ages[available.get_instance_id()] = 0.0
	if event.has("landing_world"):
		_clod_landing_heights[available.get_instance_id()] = (event["landing_world"] as Vector3).y
	return true


func _deactivate_clod_state(clod: RigidBody3D) -> void:
	clod.freeze = true
	clod.sleeping = true
	clod.visible = false
	clod.linear_velocity = Vector3.ZERO
	clod.angular_velocity = Vector3.ZERO
	_clod_ages.erase(clod.get_instance_id())
	_clod_landing_heights.erase(clod.get_instance_id())


func _deactivate_active_clod(index: int) -> void:
	if index < 0 or index >= _active_clods.size():
		return
	var clod := _active_clods[index]
	_deactivate_clod_state(clod)
	_active_clods.remove_at(index)
	_free_clods.append(clod)


func _reset_clod_pool() -> void:
	for clod in _active_clods:
		_deactivate_clod_state(clod)
	_active_clods.clear()
	_free_clods.clear()
	for clod in _clods:
		_deactivate_clod_state(clod)
		_free_clods.append(clod)


func _active_clod_count() -> int:
	return _active_clods.size()


func _update_visual_mound(status: Dictionary) -> void:
	# Voxel soil already owns its visible ground surface. The arcade fallback's
	# decorative spheres belong neither at the voxel outlet nor over its mound.
	if String(status.get("soil_material_lifecycle_mode", "")) == "voxel":
		if not _last_visual_mound_event_id.is_empty():
			_clear_visual_mounds()
		return
	var event_id := String(status.get("accepted_dump_event_id", ""))
	if event_id.is_empty() or event_id == _last_visual_mound_event_id or _visual_mounds.is_empty():
		return
	var release_world := status.get("dump_release_world", Vector3.ZERO) as Vector3
	var released_ratio := clampf(float(status.get("dump_released_fill_ratio", 0.0)), 0.0, 1.0)
	if not release_world.is_finite() or released_ratio <= 0.001:
		return
	var mound := _visual_mounds[_visual_mound_cursor]
	_visual_mound_cursor = (_visual_mound_cursor + 1) % _visual_mounds.size()
	var footprint := lerpf(0.65, 1.65, sqrt(released_ratio))
	var height := lerpf(0.18, 0.62, pow(released_ratio, 0.72))
	mound.global_position = release_world + Vector3(0.0, height * 0.42, 0.0)
	mound.scale = Vector3(footprint, height, footprint * 0.86)
	mound.rotation.y = float(_visual_mound_cursor) * 0.731
	mound.visible = true
	_last_visual_mound_event_id = event_id


func _clear_visual_mounds() -> void:
	for mound in _visual_mounds:
		mound.visible = false
	_visual_mound_cursor = 0
	_last_visual_mound_event_id = ""


func _update_rejected_dump_feedback(status: Dictionary) -> void:
	var event_id := String(status.get("rejected_dump_event_id", ""))
	if event_id.is_empty() or event_id == _last_rejected_dump_event_id:
		return
	var position := status.get("rejected_dump_world", Vector3.ZERO) as Vector3
	if not position.is_finite():
		return
	_last_rejected_dump_event_id = event_id
	_rejected_dump_effect_count += 1
	if emission_enabled and _budget >= 400 and _dust_particles != null:
		_dust_particles.global_position = position
		_dust_particles.restart()


func _active_visual_mound_count() -> int:
	var count := 0
	for mound in _visual_mounds:
		if mound.visible:
			count += 1
	return count


func _spawn_noise(sequence: int, salt: int) -> float:
	var value := sequence * 374761393 + salt * 668265263
	value = (value ^ (value >> 13)) * 1274126177
	value = value ^ (value >> 16)
	return float(value & 0xffff) / 32767.5 - 1.0


func _rebuild_fill_surface(fill_ratio: float) -> void:
	var arrays := _fill_surface.build_arrays(fill_ratio)
	_fill_array_mesh.clear_surfaces()
	if not arrays.is_empty():
		_fill_array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		_fill_array_mesh.surface_set_material(0, _fill_material)
	_fill_rebuild_count += 1
