extends SceneTree

const Generator = preload("res://scripts/voxel_pit_generator.gd")

var _failures: Array[String] = []


func _initialize() -> void:
	var gen = Generator.new()
	gen.half_size = Vector2(9, 14)
	gen.depth_m = 1.5
	_check_flat_zero_depth()
	_check_rims_and_outside(gen)
	_check_north_half_flat(gen)
	_check_pit_floor(gen)
	_check_ramp_profile(gen)
	_check_dig_face(gen)
	_check_side_walls(gen)
	_check_x_symmetry(gen)
	_check_x_half_variant()
	print("voxel_starter_pit_profile_test: ", "PASS" if _failures.is_empty() else "FAIL")
	for failure in _failures:
		push_error(failure)
	quit(0 if _failures.is_empty() else 1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _check_flat_zero_depth() -> void:
	var gen = Generator.new()
	gen.half_size = Vector2(9, 14)
	gen.depth_m = 0.0
	for z in range(-15, 16):
		for x in range(-10, 11):
			_expect(is_zero_approx(gen.surface_height_m(x, z)), "depth 0 stays level at %s,%s" % [x, z])


func _check_rims_and_outside(gen) -> void:
	for x in range(-8, 9):
		_expect(is_zero_approx(gen.surface_height_m(x, -14)), "south rim level")
		_expect(is_zero_approx(gen.surface_height_m(x, -13)), "south rim band level")
		_expect(is_zero_approx(gen.surface_height_m(x, 14)), "north rim level")
		_expect(is_zero_approx(gen.surface_height_m(x, -15)), "south apron at grade")
		_expect(is_zero_approx(gen.surface_height_m(x, 15)), "north apron at grade")
	for z in range(-14, 15):
		_expect(is_zero_approx(gen.surface_height_m(-9, z)), "west rim level")
		_expect(is_zero_approx(gen.surface_height_m(9, z)), "east rim level")
		_expect(is_zero_approx(gen.surface_height_m(-8.8, z)), "west rim band level")
		_expect(is_zero_approx(gen.surface_height_m(8.8, z)), "east rim band level")


func _check_north_half_flat(gen) -> void:
	for z in range(0, 14):
		for x in range(-8, 9):
			_expect(is_zero_approx(gen.surface_height_m(x, z)), "far half at grade")


func _check_pit_floor(gen) -> void:
	# An 8 m flat floor — long enough to park a whole machine in the pit.
	for z in range(-8, 0):
		for x in range(-3, 4):
			_expect(is_equal_approx(gen.surface_height_m(x, z), -1.5), "pit floor at -1.5 m")


func _check_ramp_profile(gen) -> void:
	# Full-width ramp descends monotonically from the south rim to the floor at
	# a steeper constant grade (1.5 m over 4 m ~ 20.6 deg) — still drivable.
	var previous := 0.0
	var steepest := 0.0
	var steps := 80
	for i in range(steps + 1):
		var z := lerpf(-12.5, -8.5, float(i) / steps)
		var h: float = gen.surface_height_m(0.0, z)
		_expect(h <= previous + 0.001, "ramp descends monotonically")
		steepest = maxf(steepest, (previous - h) * (float(steps) / 4.0))
		previous = h
	_expect(is_equal_approx(previous, -1.5), "ramp reaches pit floor")
	_expect(steepest <= 0.5, "ramp grade stays machinery-friendly (<27 deg)")
	_expect(steepest >= 0.25, "ramp actually descends")


func _check_dig_face(gen) -> void:
	# The midline transition is a cut face, as steep as the pit walls.
	var h_top: float = gen.surface_height_m(0.0, 0.0)
	var h_bottom: float = gen.surface_height_m(0.0, -0.5)
	_expect(is_zero_approx(h_top), "unexcavated edge at grade")
	_expect(is_equal_approx(h_bottom, -1.5), "dig face reaches floor")
	var steepest := 0.0
	var steps := 20
	var previous := h_top
	for i in range(1, steps + 1):
		var z := lerpf(0.0, -0.5, float(i) / steps)
		var h: float = gen.surface_height_m(0.0, z)
		steepest = maxf(steepest, (previous - h) * (float(steps) / 0.5))
		previous = h
	_expect(steepest >= 1.5, "dig face is a real cut, not a ramp")


func _check_side_walls(gen) -> void:
	# Side walls are cut-steep (0.5 m run), unlike the gentle access ramp.
	var h_rim: float = gen.surface_height_m(-7.5, -1.5)
	var h_toe: float = gen.surface_height_m(-7.0, -1.5)
	_expect(is_zero_approx(h_rim), "wall top at grade")
	_expect(is_equal_approx(h_toe, -1.5), "wall toe at floor depth")
	var h_mid: float = gen.surface_height_m(-7.25, -1.5)
	_expect(is_equal_approx(h_mid, -0.75), "side wall drops the full depth over 0.5 m")


func _check_x_symmetry(gen) -> void:
	for z in range(-14, 15):
		for x in range(0, 10):
			_expect(
				is_equal_approx(gen.surface_height_m(x, z), gen.surface_height_m(-x, z)),
				"profile symmetric about the centre axis"
			)


func _check_x_half_variant() -> void:
	# Street-edge strips split along their length: the dug half is local -X,
	# the midline work front faces +X, and the z rims stay level.
	var gen = Generator.new()
	gen.half_size = Vector2(9, 14)
	gen.depth_m = 1.5
	gen.pit_on_x_half = true
	_expect(is_equal_approx(gen.surface_height_m(-5.0, 0.0), -1.5), "x-half pit floor at -1.5 m")
	_expect(is_zero_approx(gen.surface_height_m(5.0, 0.0)), "east half stays at grade")
	_expect(is_zero_approx(gen.surface_height_m(-9.0, 0.0)), "west rim stays at grade")
	_expect(is_zero_approx(gen.surface_height_m(0.0, 0.0)), "unexcavated midline edge at grade")
	_expect(is_equal_approx(gen.surface_height_m(-0.5, 0.0), -1.5), "x dig face reaches floor")
	# Default keeps the original -Z approach pit untouched.
	var gen_z = Generator.new()
	gen_z.half_size = Vector2(9, 14)
	gen_z.depth_m = 1.5
	_expect(is_equal_approx(gen_z.surface_height_m(0.0, -5.0), -1.5), "default still digs the -Z half")
	_expect(is_zero_approx(gen_z.surface_height_m(0.0, 5.0)), "default +Z half stays at grade")
