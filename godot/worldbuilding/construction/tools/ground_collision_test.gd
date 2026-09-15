extends SceneTree

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.current = true
	var sky := load("res://maps/construction/WorldEnvironment.tscn").instantiate() as Sky3D
	root.add_child(sky)
	assert(sky.environment.background_mode == Environment.BG_SKY)
	assert(sky.environment.sky.sky_material is ShaderMaterial)
	assert(is_equal_approx(sky.current_time, 10.5))
	var ground := load("res://maps/construction/Ground.tscn").instantiate() as Terrain3D
	root.add_child(ground)
	for frame in 5:
		await physics_frame
	assert(ground.collision.mode == 3)
	for point in [Vector3.ZERO, Vector3(200, 0, 200), Vector3(-200, 0, -300)]:
		var query := PhysicsRayQueryParameters3D.create(point + Vector3.UP, point - Vector3.UP, 1)
		var hit := ground.get_world_3d().direct_space_state.intersect_ray(query)
		assert(not hit.is_empty(), str(point))
		assert(absf(hit.position.y + 0.02) < 0.01)
		assert(hit.rid == ground.collision.get_rid(), "Unrecognized native ground RID")
		print("GROUND_HIT ", point, " ", hit.collider)
	ground.queue_free()
	sky.queue_free()
	await process_frame
	print("ground_collision_test: PASS")
	quit()
