extends SceneTree

const MAIN_SCENE := "res://scenes/main.tscn"
const INDICATOR_PATH := "OperatorUI/StatusPanel/Margin/VBox/Tools/ICTHandshakeStatus"

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load(MAIN_SCENE) as PackedScene
	if packed == null:
		_fail("main scene did not load")
		_finish()
		return
	var scene := packed.instantiate()
	root.add_child(scene)
	current_scene = scene
	await process_frame
	await process_frame
	var ui := scene.get_node_or_null("OperatorUI") as MotionOperatorUI
	var indicator := scene.get_node_or_null(INDICATOR_PATH) as HBoxContainer
	var lamp := scene.get_node_or_null(INDICATOR_PATH + "/Lamp") as Panel
	var label := scene.get_node_or_null(INDICATOR_PATH + "/Label") as Label
	if ui == null or indicator == null or lamp == null or label == null:
		_fail("ICT handshake indicator nodes are missing beside the operator controls")
	else:
		_check_state(ui, lamp, label, "connected", "已握手", Color("67dfa0"))
		_check_state(ui, lamp, label, "waiting", "待握手", Color("ef5350"))
		_check_state(ui, lamp, label, "offline", "未连接", Color("ef5350"))
		_check_state(ui, lamp, label, "not_applicable", "直连", Color("b8c0c8"))
		if indicator.mouse_filter != Control.MOUSE_FILTER_IGNORE:
			_fail("ICT handshake indicator intercepts pointer input")
		if lamp.custom_minimum_size.x < 12.0 or lamp.custom_minimum_size.y < 12.0:
			_fail("ICT handshake lamp is smaller than the 12 px visual contract")
	scene.queue_free()
	await process_frame
	_finish()


func _check_state(
	ui: MotionOperatorUI,
	lamp: Panel,
	label: Label,
	state: String,
	expected_text: String,
	expected_color: Color,
) -> void:
	ui.call("_set_ict_handshake_indicator", state)
	if label.text != expected_text:
		_fail("ICT indicator state %s used text %s" % [state, label.text])
	if not lamp.self_modulate.is_equal_approx(expected_color):
		_fail("ICT indicator state %s used color %s" % [state, lamp.self_modulate])
	if label.tooltip_text.is_empty() or lamp.tooltip_text != label.tooltip_text:
		_fail("ICT indicator state %s lost its shared tooltip" % state)


func _finish() -> void:
	if failures.is_empty():
		print("ICT status indicator contract passed.")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _fail(message: String) -> void:
	failures.append(message)
