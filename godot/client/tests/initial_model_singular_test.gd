extends SceneTree
## Regression: with a pre-placed SY205Excavator under PresentationRoot (the
## main.tscn layout), initial activation of sy135 must leave exactly ONE
## visible model.


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var host := Node3D.new()
	root.add_child(host)
	var presentation_root := Node3D.new()
	presentation_root.name = "PresentationRoot"
	host.add_child(presentation_root)
	# Simulate main.tscn: SY205 instance pre-placed in the scene.
	var sy205 := (load("res://assets/visual/SY205_excavator_godot.glb") as PackedScene).instantiate() as Node3D
	sy205.name = "SY205Excavator"
	presentation_root.add_child(sy205)

	var client := MotionClient.new()
	client.name = "MotionClient"
	client.auto_connect = false
	client.auto_reconnect = false
	client.desired_model_id = "sy135"
	host.add_child(client)
	var presentation := MotionPresentation.new()
	presentation.name = "MotionPresentation"
	host.add_child(presentation)
	for i in 3:
		await process_frame

	print("contract_error: [", presentation.get_contract_error(), "]")
	var visible_count := 0
	var names := []
	for child in presentation_root.get_children():
		if child is Node3D and (child as Node3D).visible:
			visible_count += 1
			names.append(child.name)
	if visible_count == 1 and presentation.get_active_model_id() == "sy135":
		print("initial_model_singular_test: PASS")
		quit(0)
	else:
		print("initial_model_singular_test: FAIL visible=%d active=%s %s" % [visible_count, presentation.get_active_model_id(), names])
		quit(1)
