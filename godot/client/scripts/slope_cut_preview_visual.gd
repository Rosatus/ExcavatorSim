class_name SlopeCutPreviewVisual
extends Node3D

## Renders the slope profile's finished surface as a translucent ghost ribbon
## — the "after" picture of the pass. The target surface is analytic (flat
## bench then straight grade) so the ribbon is built from breakpoints, not
## terrain samples. Depth-tested so it surfaces only inside the blink-open
## hole or where the target already floats above ground; a no-depth edge line
## keeps the design line readable in every blink phase. Static while the
## assist cuts — the voxel soil shader owns the blinking.

const EDGE_LIFT_M := 0.03
const SURFACE_COLOR := Color(0.62, 0.5, 0.32, 0.4)
const EDGE_COLOR := Color(1.0, 0.75, 0.25, 0.85)

var _mesh_instance: MeshInstance3D
var _line_instance: MeshInstance3D


func _ready() -> void:
	var surface_material := StandardMaterial3D.new()
	surface_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	surface_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	surface_material.albedo_color = SURFACE_COLOR
	surface_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.material_override = surface_material
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh_instance)
	var line_material := StandardMaterial3D.new()
	line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_material.no_depth_test = true
	line_material.albedo_color = EDGE_COLOR
	_line_instance = MeshInstance3D.new()
	_line_instance.material_override = line_material
	_line_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_line_instance)
	visible = false


## Rebuild the finished-surface ribbon from the preview band: quads over
## s∈[s_min,s_max] split at the slope toe, spanning ±half_width, plus edge
## lines along both swath borders and the toe cross-line.
func show_preview(result: Dictionary, profile: RefCounted) -> void:
	if profile == null:
		hide_preview()
		return
	var s_min := float(result.get("s_min", 0.0))
	var s_max := float(result.get("s_max", 0.0))
	var half_w := float(result.get("half_width_m", 0.6))
	if s_max <= s_min or half_w <= 0.0:
		hide_preview()
		return
	var s_breaks := PackedFloat32Array([s_min])
	if profile.toe_s > s_min and profile.toe_s < s_max:
		s_breaks.append(profile.toe_s)
	s_breaks.append(s_max)
	var axis: Vector2 = profile.axis
	var perp := Vector2(-axis.y, axis.x)
	var origin: Vector2 = profile.origin_xz
	var world := func(s: float, t: float) -> Vector3:
		var xz: Vector2 = origin + axis * s + perp * t
		return Vector3(xz.x, profile.height_at(s) + EDGE_LIFT_M, xz.y)
	var verts := PackedVector3Array()
	for i in range(s_breaks.size() - 1):
		var s0 := s_breaks[i]
		var s1 := s_breaks[i + 1]
		_quad(verts, world.call(s0, -half_w), world.call(s1, -half_w), world.call(s1, half_w), world.call(s0, half_w))
	_mesh_instance.mesh = _tri_mesh(verts)
	var lines := PackedVector3Array()
	for t in [-half_w, half_w]:
		lines.append(world.call(s_min, t))
		lines.append(world.call(s_max, t))
	if profile.toe_s > s_min and profile.toe_s < s_max:
		lines.append(world.call(profile.toe_s, -half_w))
		lines.append(world.call(profile.toe_s, half_w))
	_line_instance.mesh = _line_mesh(lines)
	visible = true


func hide_preview() -> void:
	visible = false


func _tri_mesh(verts: PackedVector3Array) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _line_mesh(verts: PackedVector3Array) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return mesh


func _quad(verts: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	verts.append_array([a, b, c, a, c, d])
