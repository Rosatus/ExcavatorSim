extends "res://tests/voxel_excavation_authority_test.gd"

func _run() -> void:
	var failures: Array[String] = []
	var zone := WorkZone.new()
	root.add_child(zone)
	_expect(await _wait_initial_ready(zone), "live replay zone ready", failures)
	var contract := SoilContractDescriptor.load_for_model("sy135").to_dictionary()
	var authority := Authority.new()
	authority.configure(zone,contract,zone.readiness.generation)
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/sy135_live_residual_trajectory.json"))
	_expect(fixture.frames.size() == 421 and int(fixture.frames[0][0]) == 58300 and int(fixture.frames[-1][0]) == 58720, "complete recorded scoop fixture", failures)
	var previous := Transform3D.IDENTITY
	var counts := {}
	for row in fixture.frames:
		var tr := Transform3D(Basis(Vector3(row[4],row[5],row[6]),Vector3(row[7],row[8],row[9]),Vector3(row[10],row[11],row[12])),Vector3(row[1],row[2],row[3]))
		if previous == Transform3D.IDENTITY:
			previous = tr
		var tick := int(row[0])
		var result := authority.submit_pose(_pose_from_transforms(contract,previous,tr,"live-%d"%tick),_identity(authority.generation,tick,tick))
		var reason: String = result.get("reason","")
		counts[reason]=counts.get(reason,0)+1
		authority.step_fixed(1.0/60.0)
		previous=tr
	for drain in 12:
		authority.flush_for_test()
	# Actual observed underside of the central residual sheet. These samples
	# lie inside the tooth-to-floor working span, not inside the cavity box.
	var targets := [Vector3i(-38,-6,-86),Vector3i(-37,-6,-88),Vector3i(-37,-5,-87),Vector3i(-36,-5,-89),Vector3i(-35,-5,-91),
		Vector3i(-35,0,-86),Vector3i(-34,0,-88),Vector3i(-33,0,-90)]
	var residual := 0
	for coordinate in targets:
		var sdf := zone.get_voxel_tool().get_voxel_f(coordinate)
		print("LIVE_TARGET %s sdf=%f" %[coordinate,sdf])
		if sdf <= 0:
			residual+=1
	_expect(residual==0,"recorded scoop clears observed central residual sheet (%d remain)"%residual,failures)
	_expect(authority.material_field.conservation_error_q==0,"live replay mass balance",failures)
	_expect(int(counts.get("queued",0))>100,"recorded scoop reaches real execution",failures)
	_expect(zone.get_voxel_tool().get_voxel_f(Vector3i(-60,-1,-90))<0,"exterior ground remains intact",failures)
	print("LIVE_REPLAY counts=%s residual=%d revision=%d" %[counts,residual,authority.data_revision])
	authority.clear()
	zone.queue_free()
	await process_frame
	for failure in failures:
		push_error(failure)
	quit(0 if failures.is_empty() else 1)
