extends "../bake_bucket_soil.gd"
## Executes the real generic baker in memory; never writes recipe outputs.


func _run() -> void:
	for path in ["res://resources/attachments/gb12_s50_soil_bake.json", "res://resources/models/sy80u_soil_bake.json"]:
		_check_recipe(path)
	print("bucket_soil_bake_test: PASS")
	quit(0)


func _check_recipe(recipe_path: String) -> void:
	var recipe: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(recipe_path))
	var before := {}
	for path in [recipe.profile_path, recipe.contract_path, recipe.catalog_path]:
		before[path] = FileAccess.get_sha256(path)
	var first := bake(recipe)
	assert(not first.has("error"), str(first.get("error")))
	var second := bake(recipe)
	assert(first.outputs == second.outputs, "bake must be deterministic")
	for path in first.outputs:
		assert(FileAccess.get_file_as_string(path) == first.outputs[path], "generated resource drift: " + path)
	for kind in ["source_hash", "missing_mesh", "moved_anchor", "crossed_mouth", "overwritten_input"]:
		var bad := recipe.duplicate(true)
		match kind:
			"source_hash": bad.asset_sha256 = "0".repeat(64)
			"missing_mesh": bad.lining_nodes.append("absent_lining")
			"moved_anchor": bad.mouth_anchors[0].near_tool_local = [100, 100, 100]
			"crossed_mouth":
				var swap: Variant = bad.mouth_anchors[1]
				bad.mouth_anchors[1] = bad.mouth_anchors[2]
				bad.mouth_anchors[2] = swap
			"overwritten_input": bad.profile_path = bad.contract_path
		var result := bake(bad)
		assert(result.has("error") and not result.has("outputs"), kind + " must fail before writes")
	for path in before:
		assert(FileAccess.get_sha256(path) == before[path], "bake validation must not mutate resources")
