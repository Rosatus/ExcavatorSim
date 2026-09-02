extends SceneTree

const MAIN_SCENE := "res://scenes/main.tscn"

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene := (load(MAIN_SCENE) as PackedScene).instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame
	var ui := scene.get_node_or_null("OperatorUI") as MotionOperatorUI
	var bridge := root.get_node_or_null("CanTelemetryBridge")
	if ui == null or bridge == null:
		_fail("Gateway restart UI integration nodes are missing")
	else:
		var button := ui.get_node(
			"StatusPanel/Margin/VBox/Tools/GatewayRestartButton"
		) as Button
		if button.toggle_mode or button.disabled or button.text != "启动 Gateway":
			_fail("offline Gateway control is not an enabled momentary start action")
		var before_endpoint := bridge.get_desired_tcp_endpoint_for_test() as Dictionary
		var before_pid := int(bridge.get_gateway_pid_for_test())
		var port := ui.get_node(
			"StatusPanel/Margin/VBox/AdvancedPanel/GatewayPort"
		) as LineEdit
		port.text = "70000"
		ui._on_gateway_restart_pressed()
		if bridge.get_desired_tcp_endpoint_for_test() != before_endpoint:
			_fail("invalid Gateway endpoint mutated desired endpoint")
		if int(bridge.get_gateway_pid_for_test()) != before_pid:
			_fail("invalid Gateway endpoint changed the owned process")
		var completion := ui.get_node(
			"StatusPanel/Margin/VBox/Completion"
		) as Label
		if "Gateway endpoint invalid" not in completion.text:
			_fail("invalid Gateway endpoint did not produce stable UI feedback")

		bridge.set("_gateway_lifecycle", 1)
		ui._refresh_can_status()
		if not button.disabled or button.text != "Gateway 启动中…":
			_fail("STARTING lifecycle did not disable the Gateway action")
		bridge.set("_gateway_lifecycle", 2)
		bridge.set("_restart_after_stop", true)
		ui._refresh_can_status()
		if not button.disabled or button.text != "Gateway 重启中…":
			_fail("STOPPING restart lifecycle did not disable the Gateway action")
		bridge.set("_gateway_lifecycle", 3)
		bridge.set("_restart_after_stop", false)
		ui._refresh_can_status()
		if button.disabled or button.text != "重试启动 Gateway":
			_fail("FAILED lifecycle did not expose the retry action")
		bridge.set("_gateway_lifecycle", 0)

	scene.queue_free()
	await process_frame
	if failures.is_empty():
		print("Gateway restart UI contract passed.")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _fail(message: String) -> void:
	failures.append(message)
