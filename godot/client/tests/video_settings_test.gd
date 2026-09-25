extends SceneTree

## Video settings page contract: the menu gains a "视频设置" tab with window
## mode and fps-cap selectors; selections apply live (DisplayServer /
## Engine.max_fps) and persist into operator_ui.cfg for the next launch.

const CONFIG_PATH := "user://operator_ui.cfg"

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene := load("res://scenes/main.tscn").instantiate() as Node3D
	root.add_child(scene)
	await process_frame
	await physics_frame
	var ui := scene.get_node("OperatorUI") as MotionOperatorUI
	var tabs := ui._menu["tabs"] as TabContainer

	check(tabs.get_tab_count() == 4, "menu should have 4 tabs incl. video settings: %d" % tabs.get_tab_count())
	check(tabs.get_tab_title(3) == "视频设置", "tab 3 should be 视频设置: %s" % tabs.get_tab_title(3))
	check(ui.get_control_for_test("video_page") == tabs.get_tab_control(3), "video_page hook does not resolve")

	var window_selector := ui.get_control_for_test("window_mode_selector") as OptionButton
	var fps_selector := ui.get_control_for_test("fps_limit_selector") as OptionButton
	check(window_selector != null and fps_selector != null, "video selectors missing")
	if window_selector == null or fps_selector == null:
		return _finish(scene, 1)
	check(window_selector.item_count == 3 and fps_selector.item_count == 3, "video selectors not populated")
	check(String(window_selector.get_item_metadata(0)) == "windowed"
			and String(window_selector.get_item_metadata(1)) == "borderless"
			and String(window_selector.get_item_metadata(2)) == "fullscreen",
			"window mode options unordered: %s/%s/%s" % [window_selector.get_item_metadata(0),
					window_selector.get_item_metadata(1), window_selector.get_item_metadata(2)])

	# Focus collection reaches the page's controls for stick/D-pad nav once
	# the menu is open and the tab is current (inactive tabs are hidden and
	# skipped by design).
	ui._set_panel_collapsed(false)
	tabs.current_tab = 3
	await process_frame
	var focusables: Array[Control] = []
	ui._collect_menu_focus(tabs.get_current_tab_control(), focusables)
	check(focusables.has(window_selector) and focusables.has(fps_selector), "video selectors unreachable by menu focus")
	tabs.current_tab = 0
	ui._set_panel_collapsed(true)

	# FPS cap applies live and persists the requested value.
	var config := ConfigFile.new()
	config.load(CONFIG_PATH)
	fps_selector.select(1)
	fps_selector.item_selected.emit(1)
	check(Engine.max_fps == 120, "fps cap did not apply live: %d" % Engine.max_fps)
	config = ConfigFile.new()
	config.load(CONFIG_PATH)
	check(int(config.get_value("video", "fps_limit", -1)) == 120, "fps cap was not persisted")
	fps_selector.select(0)
	fps_selector.item_selected.emit(0)
	check(Engine.max_fps == 60, "fps cap did not return to 60")
	fps_selector.select(2)
	fps_selector.item_selected.emit(2)
	check(Engine.max_fps == 0, "uncapped option did not clear Engine.max_fps")

	# Window mode persists the requested id and round-trips through the
	# startup apply path. Headless DisplayServer cannot change real window
	# modes, so verify mapping + persistence rather than the live mode.
	window_selector.select(0)
	window_selector.item_selected.emit(0)
	config = ConfigFile.new()
	config.load(CONFIG_PATH)
	check(String(config.get_value("video", "window_mode", "")) == "windowed", "windowed choice not persisted")
	window_selector.select(1)
	window_selector.item_selected.emit(1)
	config = ConfigFile.new()
	config.load(CONFIG_PATH)
	check(String(config.get_value("video", "window_mode", "")) == "borderless", "borderless choice not persisted")
	window_selector.select(2)
	window_selector.item_selected.emit(2)
	config = ConfigFile.new()
	config.load(CONFIG_PATH)
	check(String(config.get_value("video", "window_mode", "")) == "fullscreen", "fullscreen choice not persisted")

	# Startup path honors the saved pair; selectors reflect it after configure.
	window_selector.select(0)
	window_selector.item_selected.emit(0)
	fps_selector.select(0)
	fps_selector.item_selected.emit(0)
	ui._apply_saved_video_settings()
	check(Engine.max_fps == 60, "startup apply did not honor the saved fps cap")
	ui._refresh_video_selectors()
	check(window_selector.selected == 0 and fps_selector.selected == 0, "selectors did not refresh to the applied state")

	_finish(scene, 0)


func check(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
	push_error(message)


func _finish(scene: Node, code: int) -> void:
	scene.queue_free()
	if failures.is_empty() and code == 0:
		print("video_settings_test: PASS")
	else:
		print("video_settings_test: FAIL (%d)" % failures.size())
	quit(0 if failures.is_empty() and code == 0 else 1)
