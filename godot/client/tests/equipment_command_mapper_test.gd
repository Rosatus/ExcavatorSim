extends SceneTree

const EXPECTED_SIGNS := {
	"sy205": Vector4(-1.0, 1.0, 1.0, -1.0),
	"sy135": Vector4(-1.0, 1.0, 1.0, -1.0),
}
const EXPECTED_OPERATOR_AXES := {
	"operator_swing_right": Vector4(1.0, 0.0, 0.0, 0.0),
	"operator_swing_left": Vector4(-1.0, 0.0, 0.0, 0.0),
	"operator_boom_raise": Vector4(0.0, 1.0, 0.0, 0.0),
	"operator_boom_lower": Vector4(0.0, -1.0, 0.0, 0.0),
	"operator_arm_extend": Vector4(0.0, 0.0, 1.0, 0.0),
	"operator_arm_retract": Vector4(0.0, 0.0, -1.0, 0.0),
	"operator_bucket_curl": Vector4(0.0, 0.0, 0.0, 1.0),
	"operator_bucket_dump": Vector4(0.0, 0.0, 0.0, -1.0),
}

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var client := MotionClient.new()
	if not client.configure_equipment_model("sy205"):
		_fail("SY205 command profile did not configure")
	_check_fixed_bindings()
	var first_bindings := _binding_signature()
	if not client.configure_equipment_model("sy135"):
		_fail("SY135 command profile did not configure")
	if _binding_signature() != first_bindings:
		_fail("model switching mutated operator device bindings")
	_check_model_mapping()
	_check_sy205_physical_directions()
	var invalid := EquipmentCommandMapper.new("res://resources/protocol/missing.json")
	if invalid.configure_model("sy205") or invalid.get_last_error().is_empty():
		_fail("missing profile did not fail closed")
	var mismatch_path := "user://equipment-command-profile-hash-mismatch.json"
	var mismatch_file := FileAccess.open(mismatch_path, FileAccess.WRITE)
	if mismatch_file == null:
		_fail("could not create hash-mismatch fixture")
	else:
		mismatch_file.store_string("{}")
		mismatch_file.close()
	var hash_mismatch := EquipmentCommandMapper.new(mismatch_path)
	if hash_mismatch.configure_model("sy205") or not hash_mismatch.get_last_error().contains("SHA-256 mismatch"):
		_fail("profile SHA-256 mismatch did not fail closed: %s" % hash_mismatch.get_last_error())
	DirAccess.remove_absolute(ProjectSettings.globalize_path(mismatch_path))
	client.free()
	if failures.is_empty():
		print("Equipment command mapper contract passed.")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _check_fixed_bindings() -> void:
	for action in EquipmentCommandMapper.INPUT_ACTIONS:
		var definition := EquipmentCommandMapper.INPUT_ACTIONS[action] as Dictionary
		var keys: Array[InputEventKey] = []
		var joys: Array[InputEventJoypadMotion] = []
		for event in InputMap.action_get_events(action):
			if event is InputEventKey:
				keys.append(event)
			elif event is InputEventJoypadMotion:
				joys.append(event)
		if keys.size() != 1 or keys[0].physical_keycode != int((definition["keys"] as Array)[0]):
			_fail("wrong fixed keyboard binding for %s" % action)
		if (
			joys.size() != 1
			or joys[0].axis != int(definition["joy_axis"])
			or not is_equal_approx(joys[0].axis_value, float(definition["joy_sign"]))
		):
			_fail("wrong fixed gamepad binding for %s" % action)


func _check_model_mapping() -> void:
	for model_id in EXPECTED_SIGNS:
		var mapper := EquipmentCommandMapper.new()
		if not mapper.configure_model(model_id):
			_fail("mapper rejected %s" % model_id)
			continue
		var signs: Vector4 = EXPECTED_SIGNS[model_id]
		if not mapper.to_joint_axes(Vector4.ONE).is_equal_approx(signs):
			_fail("%s positive operator signs are wrong" % model_id)
		if not mapper.to_joint_axes(-Vector4.ONE).is_equal_approx(-signs):
			_fail("%s negative operator signs are wrong" % model_id)
		if not mapper.to_joint_axes(Vector4.ZERO).is_zero_approx():
			_fail("%s neutral operator vector is not neutral" % model_id)
		var client := MotionClient.new()
		client.configure_equipment_model(model_id)
		client.set_input_axes(Vector4.ONE)
		if not client.get_authoritative_input_axes().is_equal_approx(signs):
			_fail("%s local MotionClient boundary did not map operator axes once" % model_id)
		client.free()
	for action in EXPECTED_OPERATOR_AXES:
		for owned_action in EXPECTED_OPERATOR_AXES:
			Input.action_release(owned_action)
		Input.action_press(action)
		var mapper := EquipmentCommandMapper.new()
		mapper.configure_model("sy205")
		if not mapper.read_operator_axes().is_equal_approx(EXPECTED_OPERATOR_AXES[action]):
			_fail("operator action did not produce canonical axis: %s" % action)
		Input.action_release(action)


func _check_sy205_physical_directions() -> void:
	# Exercise commands through FK, not just the profile's scalar signs. SY205
	# has baked geometry facing +Z: common positive boom/arm coordinates must
	# rotate its imported hinges around -X; curl uses the opposite direction.
	var descriptor := PhysicsRigDescriptor.load_for_model("sy205")
	if descriptor == null or not descriptor.is_valid_for("sy205", descriptor.model_version()):
		_fail("SY205 direction fixture rejected its rig/catalog hash")
		return
	var mapper := EquipmentCommandMapper.new()
	mapper.configure_model("sy205")
	var frames := ["upper_structure_link", "boom_link", "arm_link", "bucket_link"]
	var parents := ["base_link", "upper_structure_link", "boom_link", "arm_link"]
	var expected_asset_signs := [-1.0, -1.0, -1.0, 1.0]
	for index in 4:
		for direction in [-1.0, 1.0]:
			var state := KinematicArticulationState.new()
			state.configure(descriptor.to_dictionary(), Transform3D.IDENTITY)
			var rest := state.accepted_frames()
			state.set_commands(Vector4.ZERO)
			state.accept_step(state.propose_step(1.0 / 60.0, Transform3D.IDENTITY, true), 1.0)
			var operator := Vector4.ZERO
			operator[index] = direction
			state.set_commands(mapper.to_joint_axes(operator))
			for _tick in 30:
				state.accept_step(state.propose_step(1.0 / 60.0, Transform3D.IDENTITY, true), 1.0)
			var moved := state.accepted_frames()
			var before: Transform3D = (rest[parents[index]] as Transform3D).affine_inverse() * (rest[frames[index]] as Transform3D)
			var after: Transform3D = (moved[parents[index]] as Transform3D).affine_inverse() * (moved[frames[index]] as Transform3D)
			var delta := before.basis.inverse() * after.basis
			var angle := atan2(delta.z.x, delta.x.x) if index == 0 else atan2(delta.y.z, delta.y.y)
			if angle * direction * float(expected_asset_signs[index]) <= 0.001:
				_fail("SY205 %s operator direction %s reversed physical FK: %s" % [frames[index], direction, angle])
			if index == 1 and direction > 0.0 and (moved["arm_link"] as Transform3D).origin.y <= (rest["arm_link"] as Transform3D).origin.y:
				_fail("SY205 K did not physically raise the boom endpoint")
			if index == 2 and direction > 0.0 and (moved["bucket_link"] as Transform3D).origin.z <= (rest["bucket_link"] as Transform3D).origin.z:
				_fail("SY205 W did not extend the bucket endpoint forward")
			if index > 0:
				var limits := descriptor.joints()[index]["limit_rad"] as Array
				for _tick in 700:
					state.accept_step(state.propose_step(1.0 / 60.0, Transform3D.IDENTITY, true), 1.0)
					var position := float(state.joint_states()[index]["position_rad"])
					if position < float(limits[0]) or position > float(limits[1]):
						_fail("SY205 %s escaped its common-coordinate limits" % frames[index])
				var end := float(state.joint_states()[index]["position_rad"])
				var expected_end := float(limits[1] if mapper.to_joint_axes(operator)[index] > 0.0 else limits[0])
				if absf(end - expected_end) > 0.001:
					_fail("SY205 %s did not reach the intended end of its shared travel" % frames[index])


func _binding_signature() -> Dictionary:
	var signature := {}
	for action in EquipmentCommandMapper.INPUT_ACTIONS:
		var events: Array[String] = []
		for event in InputMap.action_get_events(action):
			if event is InputEventKey:
				events.append("key:%d" % (event as InputEventKey).physical_keycode)
			elif event is InputEventJoypadMotion:
				var joy := event as InputEventJoypadMotion
				events.append("joy:%d:%s" % [joy.axis, joy.axis_value])
		signature[action] = events
	return signature


func _fail(message: String) -> void:
	failures.append(message)
