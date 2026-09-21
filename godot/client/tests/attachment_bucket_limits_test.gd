extends SceneTree


func _initialize() -> void:
	var descriptor := PhysicsRigDescriptor.load_for_model("sy135").to_dictionary()
	var articulation := KinematicArticulationState.new()
	assert(articulation.configure(descriptor, Transform3D.IDENTITY))
	var runtime := JoltChassisTrackRuntime.new()
	runtime._articulation = articulation
	var native := articulation.effective_joint_limits("bucket_joint")
	var pipeline := EquipmentAssistPipeline.new()
	var soil: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://resources/models/sy135_soil_contract.json"))
	assert(pipeline.configure(descriptor, soil, "sy135"))
	for attachment in ["xtr13+gb12", "xtr13+no_tool"]:
		runtime.set_attachment_bucket_limits(attachment)
		var limits := articulation.effective_joint_limits("bucket_joint")
		assert(is_equal_approx(rad_to_deg(limits[0]), 40.0))
		assert(is_equal_approx(rad_to_deg(limits[1]), 175.0))
		var ctx := pipeline.build_context(articulation, Transform3D.IDENTITY, 0.016, {})
		assert(ctx.joint_limits.bucket_joint.is_equal_approx(Vector2(limits[0], limits[1])))
		for direction in [1.0, -1.0]:
			articulation.set_commands(Vector4.ZERO)
			articulation.accept_step(articulation.propose_step(0.016, Transform3D.IDENTITY, true), 1.0)
			articulation.set_commands(Vector4(0, 0, 0, direction))
			for tick in 1200:
				var proposal := articulation.propose_step(0.016, Transform3D.IDENTITY, true)
				var angle := float(proposal.positions.bucket_joint)
				assert(angle >= float(limits[0]) - 0.00001 and angle <= float(limits[1]) + 0.00001)
				articulation.accept_step(proposal, 1.0)
			var expected := float(limits[1] if direction > 0 else limits[0])
			assert(absf(float(articulation._positions.bucket_joint) - expected) < 0.001)
	runtime.set_attachment_bucket_limits("")
	assert(articulation.effective_joint_limits("bucket_joint") == native)
	runtime.free()
	print("attachment_bucket_limits_test: PASS")
	quit(0)
