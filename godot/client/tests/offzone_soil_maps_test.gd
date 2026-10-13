extends "res://tests/voxel_excavation_authority_test.gd"
func _run() -> void:
	var failures: Array[String] = []
	var catalog = root.get_node("MapCatalog")
	for map_id in ["urban", "construction"]:
		catalog.active_map_id = map_id
		catalog.retained_model_id = "sy135"
		var scene = load("res://scenes/main.tscn").instantiate()
		root.add_child(scene)
		current_scene = scene
		var zone: VoxelWorkZone = scene.get_node("TerrainRoot/VoxelWorkZone")
		_expect(await _wait_initial_ready(zone), map_id + " initial ready", failures)
		var excavation = scene.get_node("TerrainRoot/ExcavationWorld")
		excavation.automatic_soil_enabled = false
		var session = scene.get_node("ProductSession")
		session.request_simple_digging(false)
		session.request_offzone_soil(true)
		var authority: VoxelExcavationAuthority = excavation._voxel_authority
		_expect(authority != null and authority.offzone_enabled, map_id + " session routes mode", failures)
		if authority == null:
			scene.queue_free()
			await process_frame
			continue
		var contract := SoilContractDescriptor.load_for_model("sy135").to_dictionary()
		var ground = scene.get_node("StaticMap/Ground")
		var landing := Vector3.ZERO
		var found := false
		var space = scene.get_world_3d().direct_space_state
		# Find actual exposed static terrain outside the work rectangle.
		for offset in [Vector3(0,0,-5), Vector3(0,0,5), Vector3(5,0,0), Vector3(-5,0,0), Vector3(0,0,-10), Vector3(0,0,-22), Vector3(22,0,0),Vector3(-22,0,0),Vector3(0,0,22)]:
			var probe: Vector3 = zone.layout.ORIGIN_WORLD + offset
			if zone.layout.owns_world_xz(Vector2(probe.x,probe.z)):
				continue
			var hit: Dictionary = space.intersect_ray(PhysicsRayQueryParameters3D.create(probe + Vector3.UP*10,probe - Vector3.UP*10,1))
			var collider = hit.get("collider")
			if (collider != null and (collider == ground or ground.is_ancestor_of(collider))) or (ground is Terrain3D and hit.get("rid", RID()) == ground.collision.get_rid()):
				landing = hit.position
				found = true
				break
		_expect(found, map_id + " exposed ground found", failures)
		print("MAP ",map_id," LANDING ",landing)
		var initial := authority.material_field.mass_q_for_volume(0.15)
		authority.material_field.credit_bucket_mass_for_test(initial)
		var tick := maxi(authority._last_submitted_tick,authority._last_submitted_motion_sequence)+100
		var dumped := 0
		for i in 100:
			var result := authority.submit_pose(_dump_pose(contract,landing+Vector3.UP*3,"pile"), _identity(authority.generation,tick+i,tick+i),0.05)
			if result.get("reason", "") == "pile_deposited":
				dumped += 1
			authority.step_fixed(0.05)
			await process_frame
			await physics_frame
			if authority.material_field.bucket_mass_q == 0:
				break
		print("DUMPED ", dumped, " REMAIN ",authority.material_field.bucket_mass_q, " SOIL ",authority.get_status_snapshot().get("offzone_soil"))
		_expect(dumped > 0 and authority.material_field.bucket_mass_q == 0, map_id+" actual dump route drains bucket",failures)
		_expect(authority.material_field.exported_dump_mass_q == 0 and authority.material_field.conservation_error_q == 0,map_id+" conserved pile not export",failures)
		var layer := authority.offzone_layer
		if is_instance_valid(layer):
			for i in 160:
				await process_frame
				await physics_frame
				if layer._dirty.is_empty():
					break
			await physics_frame
			var hit: Dictionary = space.intersect_ray(PhysicsRayQueryParameters3D.create(landing+Vector3.UP*3,landing-Vector3.UP,1))
			print("PILE HIT ",hit)
			_expect(not hit.is_empty() and hit.position.y > landing.y + 0.1, map_id+" pile physics above original ground",failures)
			var chassis = scene.get_node("ChassisMotionRoot")
			chassis.set_test_input_focus_bypass_for_test(true)
			chassis.set_commands_for_test(0,0)
			var runtime = chassis._jolt_runtime
			var accepted_hit: Dictionary = runtime._accept_track_support_hit(hit.duplicate())
			_expect(not accepted_hit.is_empty() and accepted_hit.get("support_source") == "voxel_terrain",map_id+" chassis accepts pile support",failures)
			# Put one track over the small pile, leaving the other on the road.
			runtime._body.global_transform = Transform3D(Basis.IDENTITY,landing+Vector3(1.0,1.3,0))
			runtime._body.linear_velocity = Vector3.ZERO
			runtime._body.angular_velocity = Vector3.ZERO
			var pile_support_frames := 0
			for frame in 120:
				await physics_frame
				var snap: Dictionary = runtime.get_post_step_snapshot()
				if int(snap.get("track_support_source_counts",{}).get("voxel_terrain",0)) > 0:
					pile_support_frames += 1
			_expect(pile_support_frames > 10,map_id+" SY135 tracks load pile",failures)
			var drive_start: Vector3 = chassis.global_position
			chassis.set_commands_for_test(1,1)
			for frame in 90:
				await physics_frame
			chassis.set_commands_for_test(0,0)
			print("PILE DRIVE ",map_id," support_frames=",pile_support_frames," travel=",chassis.global_position.distance_to(drive_start))
			_expect(chassis.global_position.distance_to(drive_start)>0.3 and chassis.global_position.y>landing.y-0.5,map_id+" SY135 drives off pile",failures)
			# Continuous actual bucket-tool pose strokes, same route as runtime.
			var bucket_tool := BucketSoilTool.new()
			bucket_tool.configure(contract)
			var sample := bucket_tool.compose_snapshot(Transform3D.IDENTITY,Transform3D.IDENTITY,true,"sample")
			var edge: Dictionary = layer.cutter._find_region(sample,"teeth_main_edge")
			var local_center: Vector3 = edge.get("current_center_world",Vector3.ZERO)
			for i in 15:
				var tooth := landing + Vector3(0,0.65-i*0.055,0)
				var pose := _pose(contract,tooth-local_center,Vector3(0,-0.06,0),"recut:%d"%i)
				authority.submit_pose(pose,_identity(authority.generation,tick+200+i,tick+200+i),0.05)
				authority.step_fixed(0.05)
				await process_frame
			_expect(authority.material_field.bucket_mass_q > initial/10,map_id+" actual bucket pose recuts pile",failures)
			print("RECUT ",map_id," ",layer.get_status_snapshot()," captured=",authority.material_field.bucket_mass_q)
			var rev := layer.revision
			session.request_offzone_soil(false)
			_expect(is_instance_valid(layer) and layer.revision == rev,map_id+" toggle retains pile",failures)
			session.request_offzone_soil(true)
			session.request_simple_digging(true)
			var stock := authority.material_field.bucket_mass_q
			for i in 10:
				authority.submit_pose(_dump_pose(contract,landing+Vector3.UP*3,"blocked"),_identity(authority.generation,tick+300+i,tick+300+i),0.05)
			_expect(stock == authority.material_field.bucket_mass_q,map_id+" simple digging keeps stock",failures)
			# Adjacent dumping must stop at mutable native soil ownership.
			if map_id == "urban":
				session.request_simple_digging(false)
				var seam := Vector3(zone.layout.ORIGIN_WORLD.x, zone.layout.INITIAL_SURFACE_Y+3, zone.layout.MIN_WORLD.z-0.2)
				var seam_mass := authority.material_field.mass_q_for_volume(0.2)
				authority.material_field.export_bucket_mass(authority.material_field.bucket_mass_q)
				authority.material_field.credit_bucket_mass_for_test(seam_mass)
				var seam_result := layer.deposit(seam,seam_mass,authority.material_field)
				_expect(bool(seam_result.get("accepted",false)),"seam deposit accepted",failures)
				var inner_column := Vector2i(roundi(seam.x/layer.SCALE),ceili((zone.layout.MIN_WORLD.z+0.2)/layer.SCALE))
				_expect(not layer._column_spans.has(inner_column),"pile does not use mutable original soil as a foundation",failures)
				_expect(authority.material_field.conservation_error_q == 0,"seam shared ledger conserved",failures)
				print("SEAM ",seam_result)
				for frame in 120:
					await process_frame
					await physics_frame
					if layer._dirty.is_empty():
						break
			authority.clear()
			await process_frame
			_expect(not is_instance_valid(layer),map_id+" generation teardown clears pile",failures)
		scene.queue_free()
		await process_frame
		await process_frame
	if failures.is_empty():
		print("offzone_soil_maps_test: PASS")
	else:
		for failure in failures:
			push_error(failure)
	quit(0 if failures.is_empty() else 1)
