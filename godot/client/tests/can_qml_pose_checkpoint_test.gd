extends SceneTree

const MAIN_SCENE := "res://scenes/main.tscn"
const CAPTURE_HELPER := preload("res://tests/visual_evidence_capture.gd")
const FRAME_NAMES := [
	"base_link", "upper_structure_link", "boom_link", "arm_link", "bucket_link",
]
const JOINT_NAMES := ["swing_joint", "boom_joint", "arm_joint", "bucket_joint"]
const TARGET_RAD := deg_to_rad(10.0)
const TRANSFORM_EPSILON := 2.0e-4
const QML_PROFILE_NEUTRAL_RELATION_DEG := [35.0, -90.0, -50.0]

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _capture_case("neutral", -1)
	for joint_index in JOINT_NAMES.size():
		await _capture_case("%s_positive" % JOINT_NAMES[joint_index], joint_index)
	_finish()


func _capture_case(label: String, joint_index: int) -> void:
	var scene := load(MAIN_SCENE).instantiate() as Node3D
	if scene == null:
		_fail("%s: main scene did not instantiate" % label)
		return
	root.add_child(scene)
	current_scene = scene
	await process_frame
	await physics_frame
	var helper = CAPTURE_HELPER.new()
	var configured: Dictionary = await helper.configure_product_for_capture(scene, "sy135", "low")
	if not bool(configured.get("ok", false)):
		_fail("%s: product configuration failed: %s" % [label, configured])
		await _free_scene(scene)
		return
	var session := scene.get_node("ProductSession") as ProductSession
	var chassis := scene.get_node("ChassisMotionRoot") as TrackedChassisController
	if not session.request_start():
		_fail("%s: product session did not start" % label)
		await _free_scene(scene)
		return
	session.set_focused(true)
	chassis.set_equipment_commands_for_test(Vector4.ZERO)
	for _frame in 4:
		await physics_frame
	var runtime := scene.get_node_or_null("JoltChassisTrackRuntime") as JoltChassisTrackRuntime
	if runtime == null:
		_fail("%s: authoritative runtime missing" % label)
		await _free_scene(scene)
		return
	if joint_index >= 0:
		await _drive_joint(chassis, runtime, joint_index)
	var snapshot := runtime.get_post_step_snapshot()
	var bridge := root.get_node_or_null("CanTelemetryBridge")
	if bridge == null:
		_fail("%s: CanTelemetryBridge autoload missing" % label)
		await _free_scene(scene)
		return
	# The product owns one main scene. This test intentionally rebuilds it for
	# isolated joint cases, so invalidate the autoload's one-shot node cache.
	bridge.set("_resolved", false)
	bridge.set("_presentation", null)
	bridge.set("_chassis", null)
	bridge.call("_resolve_once")
	var packet: PackedByteArray = bridge.call("_build_packet", Time.get_ticks_msec())
	_assert_checkpoint(label, scene, snapshot, packet)
	helper.release_product_after_capture(scene)
	await _free_scene(scene)


func _drive_joint(
	chassis: TrackedChassisController,
	runtime: JoltChassisTrackRuntime,
	joint_index: int,
) -> void:
	var command := Vector4.ZERO
	match joint_index:
		0: command.x = 1.0
		1: command.y = 1.0
		2: command.z = 1.0
		3: command.w = 1.0
	for _frame in 360:
		chassis.set_equipment_commands_for_test(command)
		await physics_frame
		var joints := runtime.get_post_step_snapshot().get("joints", []) as Array
		if joints.size() == JOINT_NAMES.size():
			var position_rad := float((joints[joint_index] as Dictionary).get("position_rad", 0.0))
			if position_rad >= TARGET_RAD:
				break
	chassis.set_equipment_commands_for_test(Vector4.ZERO)
	for _frame in 8:
		await physics_frame
	var final_joints := runtime.get_post_step_snapshot().get("joints", []) as Array
	if final_joints.size() != JOINT_NAMES.size():
		_fail("%s: joint snapshot missing" % JOINT_NAMES[joint_index])
		return
	var final_position := float((final_joints[joint_index] as Dictionary).get("position_rad", 0.0))
	if final_position < TARGET_RAD * 0.95:
		_fail("%s did not reach +10 degrees: %.4f rad" % [JOINT_NAMES[joint_index], final_position])


func _assert_checkpoint(
	label: String,
	scene: Node3D,
	snapshot: Dictionary,
	packet: PackedByteArray,
) -> void:
	if packet.size() != 176:
		_fail("%s: packet size %d != 176" % [label, packet.size()])
		return
	var authoritative := {"base_link": snapshot.get("body_transform", Transform3D.IDENTITY)}
	for value in snapshot.get("kinematic_frames", []):
		var row := value as Dictionary
		authoritative[String(row.get("name", ""))] = row.get("transform", Transform3D.IDENTITY)
	var presentation := scene.get_node("MotionPresentation") as MotionPresentation
	var buffer := StreamPeerBuffer.new()
	var packet_quats: Dictionary = {}
	buffer.big_endian = false
	buffer.data_array = packet
	buffer.seek(16)
	for frame_name in FRAME_NAMES:
		var packet_quat := Quaternion(
			buffer.get_float(), buffer.get_float(), buffer.get_float(), buffer.get_float()
		).normalized()
		var packet_origin := Vector3(buffer.get_float(), buffer.get_float(), buffer.get_float())
		packet_quats[frame_name] = packet_quat
		var node := presentation.get_frame_node(frame_name) as Node3D
		if node == null or not authoritative.has(frame_name):
			_fail("%s: frame %s missing" % [label, frame_name])
			continue
		var visual_transform := node.global_transform
		var truth_transform := authoritative[frame_name] as Transform3D
		_assert_transform_close(label, frame_name, visual_transform, truth_transform)
		if packet_origin.distance_to(visual_transform.origin) > TRANSFORM_EPSILON:
			_fail("%s: %s packet origin differs from presentation" % [label, frame_name])
		var visual_quat := visual_transform.basis.orthonormalized().get_rotation_quaternion().normalized()
		if absf(packet_quat.dot(visual_quat)) < 1.0 - TRANSFORM_EPSILON:
			_fail("%s: %s packet quaternion differs from presentation" % [label, frame_name])
	if label == "neutral":
		_assert_qml_profile_neutral_relations(packet_quats)
	var joint_values: Array[String] = []
	for value in snapshot.get("joints", []):
		var joint := value as Dictionary
		joint_values.append("%s=%.6f" % [joint.get("name", ""), joint.get("position_rad", 0.0)])
	print("CAN_QML_CHECKPOINT %s %s" % [label, ",".join(joint_values)])


func _assert_qml_profile_neutral_relations(packet_quats: Dictionary) -> void:
	var pairs := [
		["upper_structure_link", "boom_link"],
		["boom_link", "arm_link"],
		["arm_link", "bucket_link"],
	]
	for index in pairs.size():
		var parent := packet_quats[pairs[index][0]] as Quaternion
		var child := packet_quats[pairs[index][1]] as Quaternion
		var relation := (parent.inverse() * child).normalized()
		if relation.w < 0.0:
			relation = Quaternion(-relation.x, -relation.y, -relation.z, -relation.w)
		if absf(relation.y) > TRANSFORM_EPSILON or absf(relation.z) > TRANSFORM_EPSILON:
			_fail("neutral relation %s->%s is not local-X" % pairs[index])
			continue
		var actual_deg := rad_to_deg(2.0 * atan2(relation.x, relation.w))
		var expected_deg := float(QML_PROFILE_NEUTRAL_RELATION_DEG[index])
		if absf(actual_deg - expected_deg) > 0.02:
			_fail(
				"neutral relation %s->%s %.4f != profile %.4f deg"
				% [pairs[index][0], pairs[index][1], actual_deg, expected_deg]
			)


func _assert_transform_close(
	label: String,
	frame_name: String,
	actual: Transform3D,
	expected: Transform3D,
) -> void:
	if actual.origin.distance_to(expected.origin) > TRANSFORM_EPSILON:
		_fail("%s: %s authoritative origin mismatch" % [label, frame_name])
	var actual_quat := actual.basis.orthonormalized().get_rotation_quaternion().normalized()
	var expected_quat := expected.basis.orthonormalized().get_rotation_quaternion().normalized()
	if absf(actual_quat.dot(expected_quat)) < 1.0 - TRANSFORM_EPSILON:
		_fail("%s: %s authoritative rotation mismatch" % [label, frame_name])


func _free_scene(scene: Node3D) -> void:
	scene.queue_free()
	await process_frame
	# Allow the fixed machine-feedback AudioStreamGenerator pool to release its
	# playback reference before the next isolated product scene is created.
	await create_timer(0.05).timeout
	if current_scene == scene:
		current_scene = null


func _fail(message: String) -> void:
	failures.append(message)
	push_error(message)


func _finish() -> void:
	if failures.is_empty():
		print("CAN QML pose checkpoint test passed")
		quit(0)
		return
	for failure in failures:
		print("FAIL: %s" % failure)
	quit(1)
