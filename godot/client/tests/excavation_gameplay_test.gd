extends SceneTree

const MAIN_SCENE := "res://scenes/main.tscn"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var result := _test_repeatability_and_conservation()
	if result == 0:
		result = _test_rejections_and_capacity()
	if result == 0:
		result = _test_reset_generation_and_no_collider()
	if result == 0:
		result = _test_scene_nodes()
	if result == 0:
		print("Excavation gameplay contracts passed.")
	quit(result)


func _test_repeatability_and_conservation() -> int:
	var first_terrain := TerrainState.new(77)
	var second_terrain := TerrainState.new(77)
	var first := BucketSoilState.new(first_terrain)
	var second := BucketSoilState.new(second_terrain)
	var first_height := first_terrain.sample_surface_at(Vector2.ZERO)
	var second_height := second_terrain.sample_surface_at(Vector2.ZERO)
	if not first.queue_cut(1, Vector3(0.0, first_height, 0.0), Vector3(0.0, first_height - 0.2, 0.0)):
		return _fail("first cut queues")
	if not second.queue_cut(1, Vector3(0.0, second_height, 0.0), Vector3(0.0, second_height - 0.2, 0.0)):
		return _fail("second cut queues")
	var first_cut := first.step_fixed()
	var second_cut := second.step_fixed()
	if not first_cut.get("changed", false) or not second_cut.get("changed", false):
		return _fail("same contact accepts cut")
	var cut_volume := float(first_cut["cut_volume_m3"])
	if cut_volume <= 0.0 or not is_equal_approx(first.bucket_volume_m3, cut_volume):
		return _fail("cut volume enters bucket")
	var first_surface := first_terrain.sample_surface_at(Vector2.ZERO)
	var second_surface := second_terrain.sample_surface_at(Vector2.ZERO)
	if not first.queue_deposit(2, Vector3(0.0, first_surface + 0.2, 0.0)):
		return _fail("first deposit queues")
	if not second.queue_deposit(2, Vector3(0.0, second_surface + 0.2, 0.0)):
		return _fail("second deposit queues")
	first.step_fixed()
	second.step_fixed()
	var first_snapshot := first_terrain.surface_snapshot()
	var second_snapshot := second_terrain.surface_snapshot()
	if first_snapshot["surface_bytes"] != second_snapshot["surface_bytes"] or first_snapshot["snapshot_sha256"] != second_snapshot["snapshot_sha256"]:
		return _fail("same commands reproduce terrain bytes and digest")
	if not is_equal_approx(first.bucket_volume_m3, second.bucket_volume_m3):
		return _fail("same commands reproduce bucket volume")
	if first.bucket_volume_m3 < -BucketSoilState.EPSILON_M3 or first.bucket_volume_m3 > BucketSoilState.BUCKET_CAPACITY_M3 + BucketSoilState.EPSILON_M3:
		return _fail("bucket volume remains within capacity")
	return 0


func _test_rejections_and_capacity() -> int:
	var terrain := TerrainState.new(99)
	var soil := BucketSoilState.new(terrain)
	var surface := terrain.sample_surface_at(Vector2.ZERO)
	if not soil.queue_cut(1, Vector3(0.0, surface + 1.0, 0.0), Vector3(0.0, surface + 1.0, 0.0)):
		return _fail("non-contact command can be queued for fixed-step rejection")
	var before: PackedByteArray = terrain.surface_snapshot()["surface_bytes"]
	var rejected: Dictionary = soil.step_fixed()
	if rejected.get("changed", false) or terrain.surface_snapshot()["surface_bytes"] != before or soil.bucket_volume_m3 != 0.0:
		return _fail("non-contact command is mutation-free")
	if soil.queue_cut(1, Vector3.ZERO, Vector3.ZERO):
		return _fail("duplicate sequence is rejected")
	if not soil.queue_deposit(2, Vector3(0.0, surface + 1.0, 0.0)):
		return _fail("empty deposit command queues for deterministic rejection")
	if soil.step_fixed().get("changed", false):
		return _fail("empty deposit is rejected without mutation")
	return 0


func _test_reset_generation_and_no_collider() -> int:
	var terrain := TerrainState.new(123)
	var soil := BucketSoilState.new(terrain)
	var collider := TerrainCollider.new()
	var snapshot := terrain.surface_snapshot()
	if not collider.queue_snapshot(snapshot):
		return _fail("disabled collider accepts a derived snapshot")
	if collider.apply_pending() or collider.available:
		return _fail("disabled collider fails open")
	collider.enabled = true
	if not collider.apply_pending() or not collider.available:
		return _fail("optional collider builds the latest retained generation when enabled")
	var height := terrain.sample_surface_at(Vector2.ZERO)
	if not soil.queue_cut(1, Vector3(0.0, height, 0.0), Vector3(0.0, height - 0.2, 0.0)):
		return _fail("reset test cut queues")
	soil.step_fixed()
	var old_generation := terrain.world_generation
	if not soil.queue_deposit(2, Vector3(0.0, terrain.sample_surface_at(Vector2.ZERO) + 0.2, 0.0)):
		return _fail("pending command queues before reset")
	terrain.reset()
	var generation_result := soil.step_fixed()
	if generation_result.get("reason", "") != "generation_changed" or soil.bucket_volume_m3 != 0.0 or terrain.world_generation != old_generation + 1:
		return _fail("generation change clears pending inventory safely")
	return 0


func _test_scene_nodes() -> int:
	var packed := load(MAIN_SCENE) as PackedScene
	if packed == null:
		return _fail("main scene loads")
	var scene := packed.instantiate()
	if scene.get_node_or_null("TerrainRoot/TerrainWorld") == null or scene.get_node_or_null("TerrainRoot/ExcavationWorld") == null or scene.get_node_or_null("TerrainRoot/TerrainCollider") == null:
		return _fail("terrain, excavation and optional collider nodes exist")
	scene.queue_free()
	return 0


func _fail(message: String) -> int:
	push_error("M5 check failed: %s" % message)
	return 1
