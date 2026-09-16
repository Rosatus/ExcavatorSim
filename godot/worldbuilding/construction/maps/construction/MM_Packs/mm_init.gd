@tool
extends MultiMeshInstance3D
# 引擎不序列化 MultiMesh 实例变换，故由导出数组在就绪时重建。
# pack 场景由工具生成：xforms = 每实例 12 个浮点（行主序，同 tscn Transform3D）。

@export var xforms: PackedFloat32Array = PackedFloat32Array()
@export var mm_mesh: Mesh

func _ready() -> void:
	if multimesh != null:
		return
	if mm_mesh == null or xforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mm_mesh
	var n: int = int(xforms.size() / 12.0)
	if n <= 0:
		return
	mm.instance_count = n
	for i in n:
		var o := i * 12
		var xform_basis := Basis(
			Vector3(xforms[o], xforms[o + 3], xforms[o + 6]),
			Vector3(xforms[o + 1], xforms[o + 4], xforms[o + 7]),
			Vector3(xforms[o + 2], xforms[o + 5], xforms[o + 8]))
		mm.set_instance_transform(i, Transform3D(xform_basis, Vector3(xforms[o + 9], xforms[o + 10], xforms[o + 11])))
	multimesh = mm
