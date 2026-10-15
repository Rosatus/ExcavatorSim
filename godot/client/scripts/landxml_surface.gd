class_name LandXmlSurface
extends RefCounted

## LandXML TIN subset. Source coordinates are northing, easting, elevation.
## Godot mapping: (easting, elevation, northing), with explicit local translation.
const MAX_BYTES := 8 * 1024 * 1024
const MAX_POINTS := 20000
const MAX_FACES := 40000
const BIN_COUNT := 32
const MAX_BIN_REFERENCES := 1000000
const MAX_BIN_FACES := 512

var title := ""
var vertices := PackedVector3Array()
var faces: Array[Vector3i] = []
var bounds := AABB()
var translation := Vector3.ZERO
var source_origin: Dictionary = {}
var _bins: Dictionary = {}

static func load_file(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"error": "无法打开 LandXML 文件"}
	if file.get_length() > MAX_BYTES:
		return {"error": "文件超过 8 MB，请导出简化的 TIN 曲面"}
	return parse(file.get_as_text())


static func parse(text: String) -> Dictionary:
	if text.to_utf8_buffer().size() > MAX_BYTES:
		return {"error": "文件超过 8 MB"}
	if text.contains("<!DOCTYPE") or text.contains("<!ENTITY"):
		return {"error": "不支持 DTD 或外部实体"}
	var xml := XMLParser.new()
	if xml.open_buffer(text.to_utf8_buffer()) != OK:
		return {"error": "无法解析 XML"}
	var result: Array = []
	var stack: Array[String] = []
	var current: LandXmlSurface
	var ids: Dictionary = {}
	var pending: Array = []
	var capture := ""
	var content := ""
	var point_id := ""
	var skip_face := false
	var metric := false
	var root_seen := false
	var definition_seen := false
	while true:
		var status := xml.read()
		if status == ERR_FILE_EOF:
			break
		if status != OK:
			return {"error": "XML 格式损坏"}
		if xml.get_node_type() == XMLParser.NODE_ELEMENT:
			var tag := xml.get_node_name().get_slice(":", xml.get_node_name().get_slice_count(":") - 1)
			if stack.is_empty():
				if tag != "LandXML" or root_seen:
					return {"error": "需要 LandXML 根元素"}
				root_seen = true
			if tag == "Metric":
				if stack != ["LandXML", "Units"]:
					return {"error": "米制单位必须声明于 LandXML/Units"}
				if xml.get_named_attribute_value_safe("linearUnit") != "meter":
					return {"error": "当前仅支持以 meter 为长度单位的 LandXML"}
				metric = true
			if tag == "Imperial":
				return {"error": "当前不支持英制单位，请导出米制 TIN"}
			if tag == "Boundaries":
				return {"error": "当前不支持独立 Boundary 裁剪，请先将施工边界裁剪到 TIN 三角面"}
			if tag == "Surface":
				if stack != ["LandXML", "Surfaces"] or current != null or result.size() >= 16:
					return {"error": "曲面层级无效或超过 16 个曲面"}
				current = LandXmlSurface.new()
				current.title = xml.get_named_attribute_value_safe("name")
				ids = {}
				pending = []
				definition_seen = false
			if current != null and tag == "Definition":
				if stack.back() != "Surface" or definition_seen or xml.get_named_attribute_value_safe("surfType") != "TIN":
					return {"error": "每个曲面需要一个 Definition surfType=TIN"}
				definition_seen = true
			if current != null and tag in ["Pnts", "Faces"] and (stack.back() != "Definition" or not definition_seen):
				return {"error": "TIN 点和面必须位于 Definition 内"}
			if current != null and tag in ["P", "F"]:
				if stack.is_empty() or stack.back() != ("Pnts" if tag == "P" else "Faces") or not capture.is_empty() or xml.is_empty():
					return {"error": "TIN 点或三角面结构无效"}
				capture = tag
				content = ""
				point_id = xml.get_named_attribute_value_safe("id")
				skip_face = xml.get_named_attribute_value_safe("i") == "1"
			if not xml.is_empty():
				stack.append(tag)
		elif xml.get_node_type() in [XMLParser.NODE_TEXT, XMLParser.NODE_CDATA]:
			if not capture.is_empty():
				content += xml.get_node_data()
		elif xml.get_node_type() == XMLParser.NODE_ELEMENT_END:
			var tag := xml.get_node_name().get_slice(":", xml.get_node_name().get_slice_count(":") - 1)
			if stack.is_empty() or stack.pop_back() != tag:
				return {"error": "XML 元素未正确闭合"}
			if tag == capture:
				var tokens := content.replace("\n", " ").replace("\r", " ").replace("\t", " ").split(" ", false)
				if tokens.size() != 3:
					return {"error": "每个点需要三个坐标，每个面需要三个点 ID"}
				if tag == "P":
					if point_id.is_empty() or ids.has(point_id) or current.vertices.size() >= MAX_POINTS:
						return {"error": "点 ID 重复、缺失或点数过多"}
					for token in tokens:
						if not token.is_valid_float() or not is_finite(float(token)) or absf(float(token)) > 1e8:
							return {"error": "点坐标无效或超出支持范围"}
					if current.source_origin.is_empty():
						current.source_origin = {"e": float(tokens[1]), "n": float(tokens[0]), "h": float(tokens[2])}
						current.translation = Vector3(float(tokens[1]), float(tokens[2]), float(tokens[0]))
					ids[point_id] = current.vertices.size()
					# Subtract in double precision before storing float32 vectors.
					current.vertices.append(Vector3(float(tokens[1]) - float(current.source_origin.e), float(tokens[2]) - float(current.source_origin.h), float(tokens[0]) - float(current.source_origin.n)))
				elif not skip_face:
					if pending.size() >= MAX_FACES:
						return {"error": "三角面数量过多"}
					pending.append(tokens)
				capture = ""
			if tag == "Surface":
				if current == null or not definition_seen or current.vertices.is_empty() or pending.is_empty():
					return {"error": "曲面缺少 TIN 点或可见三角面"}
				for face in pending:
					for id in face:
						if not ids.has(id):
							return {"error": "三角面引用不存在的点：" + id}
					var f := Vector3i(ids[face[0]], ids[face[1]], ids[face[2]])
					var a := current.vertices[f.x]
					var b := current.vertices[f.y]
					var c := current.vertices[f.z]
					if absf(Vector2(b.x - a.x, b.z - a.z).cross(Vector2(c.x - a.x, c.z - a.z))) < 0.000001:
						return {"error": "存在竖直或退化三角面；DTM 需要单值高程曲面"}
					current.faces.append(f)
				if not current.rebuild_index():
					return {"error": "TIN 空间重叠过密，请分区或简化曲面"}
				result.append(current)
				current = null
	if not root_seen or not stack.is_empty() or current != null:
		return {"error": "XML 不完整"}
	if not metric:
		return {"error": "缺少明确的米制单位 Units/Metric linearUnit=meter"}
	if result.is_empty():
		return {"error": "文件中没有可用的 TIN 曲面"}
	return {"surfaces": result, "error": ""}


func rebuild_index() -> bool:
	bounds = AABB(vertices[faces[0].x], Vector3.ZERO)
	for face in faces:
		for index in [face.x, face.y, face.z]:
			bounds = bounds.expand(vertices[index])
	_bins.clear()
	var references := 0
	for i in faces.size():
		var f := faces[i]
		var a := vertices[f.x]
		var b := vertices[f.y]
		var c := vertices[f.z]
		var lo := _bin(Vector2(minf(a.x, minf(b.x, c.x)), minf(a.z, minf(b.z, c.z))))
		var hi := _bin(Vector2(maxf(a.x, maxf(b.x, c.x)), maxf(a.z, maxf(b.z, c.z))))
		references += (hi.x - lo.x + 1) * (hi.y - lo.y + 1)
		if references > MAX_BIN_REFERENCES:
			return false
		for x in range(lo.x, hi.x + 1):
			for z in range(lo.y, hi.y + 1):
				var key := Vector2i(x, z)
				if not _bins.has(key):
					_bins[key] = []
				if _bins[key].size() >= MAX_BIN_FACES:
					return false
				_bins[key].append(i)
	return true


func _bin(p: Vector2) -> Vector2i:
	return Vector2i(clampi(int((p.x - bounds.position.x) / maxf(bounds.size.x, 0.001) * BIN_COUNT), 0, BIN_COUNT - 1), clampi(int((p.y - bounds.position.z) / maxf(bounds.size.z, 0.001) * BIN_COUNT), 0, BIN_COUNT - 1))


func height_at(world_xz: Vector2) -> float:
	var p := world_xz - Vector2(translation.x, translation.z)
	if p.x < bounds.position.x - 0.00001 or p.y < bounds.position.z - 0.00001 or p.x > bounds.end.x + 0.00001 or p.y > bounds.end.z + 0.00001:
		return NAN
	var height := NAN
	for i in _bins.get(_bin(p), []):
		var f := faces[int(i)]
		var a := vertices[f.x]
		var b := vertices[f.y]
		var c := vertices[f.z]
		var ab := Vector2(b.x - a.x, b.z - a.z)
		var ac := Vector2(c.x - a.x, c.z - a.z)
		var ap := p - Vector2(a.x, a.z)
		var determinant := ab.cross(ac)
		var u := ap.cross(ac) / determinant
		var v := ab.cross(ap) / determinant
		if u >= -0.00001 and v >= -0.00001 and u + v <= 1.00001:
			var candidate := a.y + u * (b.y - a.y) + v * (c.y - a.y) + translation.y
			if is_finite(height) and absf(candidate - height) > 0.001:
				return NAN # Overlapping surfaces at different heights are not a DTM.
			height = candidate
	return height


func world_bounds() -> AABB:
	return AABB(bounds.position + translation, bounds.size)
