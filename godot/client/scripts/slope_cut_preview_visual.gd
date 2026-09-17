class_name SlopeCutPreviewVisual
extends Node3D

## Renders the pending slope cut as a translucent soil wedge: a top skin
## following the sampled terrain, a floor on the target profile, and side
## walls where the cut region ends — literally the chunk of soil this pass
## would remove. The wedge pulses while the operator adjusts parameters so
## it reads as a preview, not committed terrain.

const WALL_EPS := 0.04
const PULSE_HZ := 2.2
const PULSE_MIN_ALPHA := 0.22
const PULSE_MAX_ALPHA := 0.55

var _mesh_instance: MeshInstance3D
var _material: StandardMaterial3D
var _readout: Label3D
var _phase := 0.0


func _ready() -> void:
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.albedo_color = Color(1.0, 0.45, 0.1, PULSE_MIN_ALPHA)
	_material.no_depth_test = true
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.material_override = _material
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh_instance)
	_readout = Label3D.new()
	_readout.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_readout.no_depth_test = true
	_readout.font_size = 72
	_readout.outline_size = 12
	_readout.modulate = Color(1.0, 0.85, 0.4)
	_readout.outline_modulate = Color(0.0, 0.0, 0.0, 0.85)
	add_child(_readout)
	visible = false


func _process(delta: float) -> void:
	if not visible:
		return
	_phase = fposmod(_phase + delta * PULSE_HZ, 1.0)
	var pulse := 0.5 - 0.5 * cos(_phase * TAU)
	var color := _material.albedo_color
	color.a = lerpf(PULSE_MIN_ALPHA, PULSE_MAX_ALPHA, pulse)
	_material.albedo_color = color


## Rebuild the wedge from a SlopeCutPreview.compute() result: cells whose
## sampled terrain rises above the target profile get a terrain cap, a
## target floor, and walls along every edge facing a non-cut cell.
func show_preview(result: Dictionary, profile: RefCounted) -> void:
	if profile == null:
		hide_preview()
		return
	var s_values := result.get("s_values", PackedFloat32Array()) as PackedFloat32Array
	var t_values := result.get("t_values", PackedFloat32Array()) as PackedFloat32Array
	var terrain_rows := result.get("terrain", []) as Array
	var target_rows := result.get("target", []) as Array
	if s_values.size() < 2 or t_values.size() < 2 or terrain_rows.size() != s_values.size():
		hide_preview()
		return
	var axis: Vector2 = profile.axis
	var perp := Vector2(-axis.y, axis.x)
	var origin: Vector2 = profile.origin_xz
	var rows := s_values.size()
	var cols := t_values.size()
	var depth := []
	for r in rows:
		var row := PackedFloat32Array()
		row.resize(cols)
		for c in cols:
			row[c] = float((terrain_rows[r] as PackedFloat32Array)[c]) - float((target_rows[r] as PackedFloat32Array)[c])
		depth.append(row)
	var verts := PackedVector3Array()
	var world := func(s: float, t: float, h: float) -> Vector3:
		var xz: Vector2 = origin + axis * s + perp * t
		return Vector3(xz.x, h, xz.y)
	for r in range(rows - 1):
		for c in range(cols - 1):
			var d00 := float((depth[r] as PackedFloat32Array)[c])
			var d10 := float((depth[r + 1] as PackedFloat32Array)[c])
			var d01 := float((depth[r] as PackedFloat32Array)[c + 1])
			var d11 := float((depth[r + 1] as PackedFloat32Array)[c + 1])
			if minf(minf(d00, d10), minf(d01, d11)) <= 0.0:
				continue
			var s0 := float(s_values[r])
			var s1 := float(s_values[r + 1])
			var t0 := float(t_values[c])
			var t1 := float(t_values[c + 1])
			var th00 := float((terrain_rows[r] as PackedFloat32Array)[c]) + WALL_EPS
			var th10 := float((terrain_rows[r + 1] as PackedFloat32Array)[c]) + WALL_EPS
			var th01 := float((terrain_rows[r] as PackedFloat32Array)[c + 1]) + WALL_EPS
			var th11 := float((terrain_rows[r + 1] as PackedFloat32Array)[c + 1]) + WALL_EPS
			var ta00 := float((target_rows[r] as PackedFloat32Array)[c])
			var ta10 := float((target_rows[r + 1] as PackedFloat32Array)[c])
			var ta01 := float((target_rows[r] as PackedFloat32Array)[c + 1])
			var ta11 := float((target_rows[r + 1] as PackedFloat32Array)[c + 1])
			# Terrain cap (the soil skin that disappears).
			_quad(verts, world.call(s0, t0, th00), world.call(s1, t0, th10), world.call(s1, t1, th11), world.call(s0, t1, th01))
			# Target floor (the finished surface left behind).
			_quad(verts, world.call(s0, t0, ta00), world.call(s0, t1, ta01), world.call(s1, t1, ta11), world.call(s1, t0, ta10))
			# Walls along grid edges that face a non-cut neighbour.
			if r == 0 or float((depth[r - 1] as PackedFloat32Array)[c]) <= 0.0:
				_quad(verts, world.call(s0, t0, ta00), world.call(s0, t1, ta01), world.call(s0, t1, th01), world.call(s0, t0, th00))
			if r == rows - 2 or float((depth[r + 2] as PackedFloat32Array)[c]) <= 0.0:
				_quad(verts, world.call(s1, t0, ta10), world.call(s1, t0, th10), world.call(s1, t1, th11), world.call(s1, t1, ta11))
			if c == 0 or float((depth[r] as PackedFloat32Array)[c - 1]) <= 0.0:
				_quad(verts, world.call(s0, t0, ta00), world.call(s0, t0, th00), world.call(s1, t0, th10), world.call(s1, t0, ta10))
			if c == cols - 2 or float((depth[r] as PackedFloat32Array)[c + 1]) <= 0.0:
				_quad(verts, world.call(s0, t1, ta01), world.call(s1, t1, ta11), world.call(s1, t1, th11), world.call(s0, t1, th01))
	if verts.is_empty():
		hide_preview()
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh_instance.mesh = mesh
	_readout.position = profile.toe_world() + Vector3(0.0, 1.2, 0.0)
	visible = true


## Live parameter line rendered above the slope toe while adjusting —
## distance / angle / estimated removal volume in world space so it stays
## readable with the menu collapsed.
func set_readout(text: String) -> void:
	_readout.text = text


func hide_preview() -> void:
	visible = false


func _quad(verts: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	verts.append_array([a, b, c, a, c, d])
