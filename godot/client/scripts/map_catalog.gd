extends Node

const CONSTRUCTION_SCENE := "res://maps/construction/Construction-Site.tscn"
var active_map_id := "training"
var retained_model_id := ""
var last_error := ""

func _ready() -> void:
	if "--without-map-packs" in OS.get_cmdline_user_args():
		return
	var base := OS.get_executable_path().get_base_dir()
	if OS.has_feature("editor"):
		base = ProjectSettings.globalize_path("res://../dist")
	var pack := base.path_join("maps/construction.pck")
	if FileAccess.file_exists(pack) and not ProjectSettings.load_resource_pack(pack, false):
		last_error = "施工大地图包加载失败"
	var uid_file := "res://maps/construction/uid_map.json"
	if FileAccess.file_exists(uid_file):
		var paths: Variant = JSON.parse_string(FileAccess.get_file_as_string(uid_file))
		if paths is Dictionary:
			for uid in paths:
				var path := String(paths[uid])
				var id := ResourceUID.text_to_id(uid)
				if id != ResourceUID.INVALID_ID and path.begins_with("res://maps/construction/") and not ResourceUID.has_id(id):
					ResourceUID.add_id(id, path)

func construction_available() -> bool:
	return ResourceLoader.exists(CONSTRUCTION_SCENE)

func select_map(map_id: String, model_id: String) -> bool:
	if map_id not in ["training", "construction"]:
		return false
	if map_id == "construction" and not construction_available():
		last_error = "未安装施工大地图包"
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
