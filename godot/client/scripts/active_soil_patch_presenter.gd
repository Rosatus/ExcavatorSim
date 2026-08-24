class_name ActiveSoilPatchPresenter
extends MultiMeshInstance3D

## Disposable visual derivative of ActiveSoilPatch. It owns no volume and can
## be rebuilt or hidden without changing simulation state.

var _material_preset := "loose"


func _ready() -> void:
	top_level = true
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	visibility_range_end = 35.0


func apply_snapshot(snapshot: Dictionary) -> void:
	var positions: PackedVector3Array = snapshot.get("positions", PackedVector3Array())
	var radii: PackedFloat32Array = snapshot.get("radii", PackedFloat32Array())
	if positions.size() != radii.size():
		visible = false
		return
	var requested_material := String(snapshot.get("material_preset", "loose"))
	if multimesh == null or requested_material != _material_preset:
		_material_preset = requested_material
		_build_multimesh()
	multimesh.instance_count = positions.size()
	for index in positions.size():
		var radius := radii[index]
		multimesh.set_instance_transform(index, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * radius), positions[index]))
	visible = not positions.is_empty()


func clear() -> void:
	if multimesh != null:
		multimesh.instance_count = 0
	visible = false


func _build_multimesh() -> void:
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 8
	sphere.rings = 5
	var material := StandardMaterial3D.new()
	material.albedo_color = _preset_color(_material_preset)
	material.roughness = 0.96
	material.metallic = 0.0
	sphere.material = material
	var next_multimesh := MultiMesh.new()
	next_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	next_multimesh.mesh = sphere
	multimesh = next_multimesh


func _preset_color(preset: String) -> Color:
	match preset:
		"compact":
			return Color("60452f")
		"sand":
			return Color("a98b5c")
		"damp":
			return Color("4b382a")
	return Color("765537")
