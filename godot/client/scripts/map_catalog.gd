extends Node

const CONSTRUCTION_SCENE := "res://maps/construction/Construction-Site.tscn"
const URBAN_SCENE := "res://maps/urban/Urban-City.tscn"
const MAP_SCENES := {
	"construction": CONSTRUCTION_SCENE,
	"urban": URBAN_SCENE,
}
const MAP_LOAD_ERRORS := {
	"construction": "土方工地包加载失败",
	"urban": "市政施工地图包加载失败",
}
const MAP_MISSING_ERRORS := {
	"construction": "未安装土方工地包",
	"urban": "未安装市政施工地图包",
}
var active_map_id := "training"
var retained_model_id := ""
var last_error := ""

func _ready() -> void:
	if "--without-map-packs" in OS.get_cmdline_user_args():
		return
	var base := OS.get_executable_path().get_base_dir()
	if OS.has_feature("editor"):
		base = ProjectSettings.globalize_path("res://../dist")
	for map_id in MAP_SCENES:
		var pack := base.path_join("maps/%s.pck" % map_id)
		if FileAccess.file_exists(pack) and not ProjectSettings.load_resource_pack(pack, false):
			last_error = MAP_LOAD_ERRORS[map_id]
		var uid_file := "res://maps/%s/uid_map.json" % map_id
		if FileAccess.file_exists(uid_file):
			var paths: Variant = JSON.parse_string(FileAccess.get_file_as_string(uid_file))
			if paths is Dictionary:
				for uid in paths:
					var path := String(paths[uid])
					var id := ResourceUID.text_to_id(uid)
					if id != ResourceUID.INVALID_ID and path.begins_with("res://maps/%s/" % map_id) and not ResourceUID.has_id(id):
						ResourceUID.add_id(id, path)

func map_available(map_id: String) -> bool:
	var scene: String = MAP_SCENES.get(map_id, "")
	return not scene.is_empty() and ResourceLoader.exists(scene)

func construction_available() -> bool:
	return map_available("construction")

func urban_available() -> bool:
	return map_available("urban")

func select_map(map_id: String, model_id: String) -> bool:
	if map_id != "training" and map_id not in MAP_SCENES:
		return false
	if map_id != "training" and not map_available(map_id):
		last_error = MAP_MISSING_ERRORS.get(map_id, "未安装地图包")
		return false
	var previous := active_map_id
	active_map_id = map_id
	retained_model_id = model_id
	var was_paused := get_tree().paused
	get_tree().paused = false
	var error := get_tree().reload_current_scene()
	if error != OK:
		active_map_id = previous
		get_tree().paused = was_paused
		last_error = "地图切换失败：%s" % error
		return false
	last_error = ""
	return true
