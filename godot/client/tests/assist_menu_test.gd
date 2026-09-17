extends SceneTree


## Assist-menu state machine contract: the single T hotkey opens a picker that
## freezes machine input, W/S edge-detection navigates entries, Enter/T/Esc
## activate or close, and each row dispatches to its assist's own semantics.
## Runs on a bare TrackedChassisController — no Jolt fixture needed since the
## menu mechanics (open guards, wraparound nav, dispatch, snapshot) never touch
## physics.


func _initialize() -> void:
	var failures := 0
	var chassis := TrackedChassisController.new()
	root.add_child(chassis)

	# Closed by default; snapshot mirrors entries with per-row state.
	var menu := chassis.assist_menu_snapshot() as Dictionary
	if not _expect(not bool(menu.get("open", true)), "menu closed by default"):
		failures += 1
	var entries := menu.get("entries", []) as Array
	if not _expect(entries.size() == 2, "two menu entries"):
		failures += 1
	if not _expect(String((entries[0] as Dictionary).get("id", "")) == "level", "entry 0 = level"):
		failures += 1
	if not _expect(String((entries[1] as Dictionary).get("id", "")) == "slope", "entry 1 = slope"):
		failures += 1

	# Open + nav wraparound: W (positive arm axis) moves selection up/previous,
	# S moves down/next; edges only, holding does not repeat.
	chassis.set_assist_menu_open(true)
	if not _expect(chassis.is_assist_menu_open(), "menu opens"):
		failures += 1
	chassis._navigate_assist_menu(-1.0)
	if not _expect(int(chassis.assist_menu_snapshot().get("index", -1)) == 1, "S nav down to 1"):
		failures += 1
	chassis._navigate_assist_menu(-1.0)
	if not _expect(int(chassis.assist_menu_snapshot().get("index", -1)) == 1, "held axis does not repeat"):
		failures += 1
	chassis._navigate_assist_menu(0.0)
	chassis._navigate_assist_menu(-1.0)
	if not _expect(int(chassis.assist_menu_snapshot().get("index", -1)) == 0, "re-press wraps to 0"):
		failures += 1
	chassis._navigate_assist_menu(0.0)
	chassis._navigate_assist_menu(1.0)
	if not _expect(int(chassis.assist_menu_snapshot().get("index", -1)) == 1, "W nav up wraps to last"):
		failures += 1

	# Level activation toggles the flag and closes the menu.
	var result := chassis.activate_assist_entry(0)
	if not _expect(result == "level", "level entry activates"):
		failures += 1
	if not _expect(chassis.level_assist_enabled, "level assist toggled on"):
		failures += 1
	if not _expect(not chassis.is_assist_menu_open(), "menu closes after activation"):
		failures += 1
	menu = chassis.assist_menu_snapshot()
	if not _expect(String(((menu.get("entries", []) as Array)[0] as Dictionary).get("state", "")) == "on", "level row shows on"):
		failures += 1

	# Slope activation dispatches to advance_slope_mode; without a configured
	# runtime it reports off, but the dispatch itself must run and close.
	chassis.set_assist_menu_open(true)
	result = chassis.activate_assist_entry(1)
	if not _expect(result.begins_with("slope:"), "slope entry dispatches"):
		failures += 1
	if not _expect(not chassis.is_assist_menu_open(), "menu closes after slope dispatch"):
		failures += 1

	# Out-of-range activation is a no-op.
	chassis.set_assist_menu_open(true)
	if not _expect(chassis.activate_assist_entry(9) == "", "out-of-range entry no-op"):
		failures += 1
	if not _expect(chassis.activate_assist_entry(-1) == "", "negative entry no-op"):
		failures += 1

	# Menu cannot open during slope preview (preview owns the T/Enter/Esc keys).
	chassis.set_assist_menu_open(false)
	chassis._slope_mode = TrackedChassisController.SLOPE_MODE_PREVIEW
	chassis.set_assist_menu_open(true)
	if not _expect(not chassis.is_assist_menu_open(), "menu blocked during preview"):
		failures += 1
	chassis._slope_mode = TrackedChassisController.SLOPE_MODE_OFF

	# Reset closes the menu.
	chassis.set_assist_menu_open(true)
	chassis._reset_motion()
	if not _expect(not chassis.is_assist_menu_open(), "reset closes menu"):
		failures += 1

	chassis.queue_free()
	if failures == 0:
		print("assist_menu_test: PASS")
		quit(0)
	else:
		push_error("assist_menu_test: %d failure(s)" % failures)
		quit(1)


func _expect(condition: bool, label: String) -> bool:
	if not condition:
		push_error("assist_menu_test FAIL: %s" % label)
	return condition
