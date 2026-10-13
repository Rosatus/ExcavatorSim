class_name OffzoneSoilLayer
extends Node3D

## Sparse SDF storage. The calling VoxelExcavationAuthority is the only writer
## and supplies its material ledger; this node never owns a second bucket.
## Static ground is a support query, never generated as accountable soil.
const REGION := "offzone"
const SCALE := 0.125
const BLOCK := 16
const CHANNEL := VoxelBuffer.CHANNEL_SDF
const MAX_BLOCKS := 1024
const MAX_WINDOW_SAMPLES := 65536
const MAX_DIRTY_BLOCKS := 64
const MAX_SUPPORT_COLUMNS := 131072
const MAX_HEIGHT_M := 8.0
const Surface = preload("res://scripts/soil_deposit_surface.gd")
const Preparation = preload("res://scripts/voxel_cut_preparation.gd")
const Cutter = preload("res://scripts/voxel_bucket_cutter.gd")
const Visuals = preload("res://scripts/soil_visual_resources.gd")

var layout := preload("res://scripts/voxel_zone_layout.gd").new()
var cutter := Cutter.new()
var ground_root: Node
var native_layout: RefCounted
var revision := 0
var mesh_revision := 0
var last_reason := ""
var last_commit_usec := 0
var max_commit_usec := 0
var _blocks: Dictionary = {}
var _block_mass: Dictionary = {}
var _nodes: Dictionary = {}
var _dirty: Dictionary = {}
var _supports: Dictionary = {}
var _column_spans: Dictionary = {}
var _mesher := VoxelMesherTransvoxel.new()
var _material: Material
var _engaged := false


func configure(ground: Node, original_layout: RefCounted, contract: Dictionary) -> bool:
	ground_root = ground
	native_layout = original_layout
	# One world-aligned namespace across all chunks: neighboring piles fuse.
	layout.ORIGIN_WORLD = Vector3.ZERO
	layout.MIN_WORLD = Vector3(-4096, -512, -4096)
	layout.MAX_WORLD = Vector3(4096, 512, 4096)
	layout.SIZE_WORLD_M = layout.MAX_WORLD - layout.MIN_WORLD
	layout.INITIAL_SURFACE_Y = -512.0
	layout.perimeter_inset_m = 0.0
	_mesher.texturing_mode = VoxelMesherTransvoxel.TEXTURES_NONE
	_mesher.transitions_enabled = false
	_material = Visuals.surface_material(true)
	cutter.deposited_only = true
	return cutter.configure(contract, SCALE, layout)


func _process(_delta: float) -> void:
	# Derived resources publish outside the physics flush. Limit both chunk
	# count and elapsed time; a new deposit waits when the backlog is full.
	var started := Time.get_ticks_usec()
	for key in _dirty.keys().slice(0, 2):
		_rebuild_chunk(key)
		_dirty.erase(key)
		if Time.get_ticks_usec() - started > 3000:
			break
	if _dirty.is_empty():
		mesh_revision = revision


func get_status_snapshot() -> Dictionary:
	return {"revision": revision, "mesh_revision": mesh_revision,
		"chunks": _blocks.size(), "pending_chunks": _dirty.size(),
		"last_reason": last_reason, "last_commit_usec": last_commit_usec,
		"max_commit_usec": max_commit_usec}


func _block_key(p: Vector3i) -> Vector3i:
	return Vector3i(floori(float(p.x) / BLOCK), floori(float(p.y) / BLOCK), floori(float(p.z) / BLOCK))


func _empty_buffer(size: Vector3i) -> VoxelBuffer:
	var buffer := VoxelBuffer.new()
	buffer.set_channel_depth(CHANNEL, VoxelBuffer.DEPTH_16_BIT)
	buffer.create(size.x, size.y, size.z)
	buffer.fill_f(1.0, CHANNEL)
	return buffer


func sdf(p: Vector3i) -> float:
	var key := _block_key(p)
	var buffer := _blocks.get(key) as VoxelBuffer
	if buffer == null:
		return 1.0
	var local := p - key * BLOCK
	return buffer.get_voxel_f(local.x, local.y, local.z, CHANNEL)


func sample_world(world: Vector3) -> Dictionary:
	if not world.is_finite():
		return {"valid": false}
	var p := Vector3i((world / SCALE).round())
	var gradient := Vector3(sdf(p + Vector3i.RIGHT) - sdf(p - Vector3i.RIGHT),
		sdf(p + Vector3i.UP) - sdf(p - Vector3i.UP), sdf(p + Vector3i.BACK) - sdf(p - Vector3i.BACK))
	return {"valid": true, "sdf": sdf(p), "gradient_world": gradient.normalized() if gradient.length_squared() > 0.00001 else Vector3.UP}


func _copy_window(origin: Vector3i, size: Vector3i) -> VoxelBuffer:
	var result := _empty_buffer(size)
	var low := _block_key(origin)
	var high := _block_key(origin + size - Vector3i.ONE)
	for z in range(low.z, high.z + 1):
		for x in range(low.x, high.x + 1):
			for y in range(low.y, high.y + 1):
				var key := Vector3i(x, y, z)
				var buffer := _blocks.get(key) as VoxelBuffer
				if buffer == null:
					continue
				var start := (key * BLOCK).max(origin)
				var end := (key * BLOCK + Vector3i.ONE * BLOCK).min(origin + size)
				result.copy_channel_from_area(buffer, start - key * BLOCK, end - key * BLOCK, start - origin, CHANNEL)
	return result


func _write_window(origin: Vector3i, buffer: VoxelBuffer, allocating: bool = true) -> void:
	var size := buffer.get_size()
	var low := _block_key(origin)
	var high := _block_key(origin + size - Vector3i.ONE)
	for z in range(low.z, high.z + 1):
		for x in range(low.x, high.x + 1):
			for y in range(low.y, high.y + 1):
				var key := Vector3i(x, y, z)
				if not _blocks.has(key):
					if not allocating:
						continue
					_blocks[key] = _empty_buffer(Vector3i.ONE * BLOCK)
				var start := (key * BLOCK).max(origin)
				var end := (key * BLOCK + Vector3i.ONE * BLOCK).min(origin + size)
				(_blocks[key] as VoxelBuffer).copy_channel_from_area(buffer, start - origin, end - origin, start - key * BLOCK, CHANNEL)
	# Halo neighbors must rebuild too, including chunks with only air samples.
	var dirty_low := _block_key(origin - Vector3i.ONE * 2)
	var dirty_high := _block_key(origin + size + Vector3i.ONE * 2)
	for z in range(dirty_low.z, dirty_high.z + 1):
		for x in range(dirty_low.x, dirty_high.x + 1):
			for y in range(dirty_low.y, dirty_high.y + 1):
				_dirty[Vector3i(x, y, z)] = true
	revision += 1


func _window_allowed(origin: Vector3i, size: Vector3i, allocating: bool = true) -> bool:
	if size.x <= 0 or size.y <= 0 or size.z <= 0 or size.x * size.y * size.z > MAX_WINDOW_SAMPLES:
		return false
	var low := _block_key(origin)
	var high := _block_key(origin + size - Vector3i.ONE)
	var count := 0
	for z in range(low.z, high.z + 1):
		for x in range(low.x, high.x + 1):
			for y in range(low.y, high.y + 1):
				if not _blocks.has(Vector3i(x, y, z)):
					count += 1
	return (not allocating or _blocks.size() + count <= MAX_BLOCKS) and _dirty.size() < MAX_DIRTY_BLOCKS


func _rebuild_chunk(key: Vector3i) -> void:
	var minimum_padding := _mesher.get_minimum_padding()
	var maximum_padding := _mesher.get_maximum_padding()
	var origin := key * BLOCK - Vector3i.ONE * minimum_padding
	var size := Vector3i.ONE * (BLOCK + minimum_padding + maximum_padding)
	var buffer := _copy_window(origin, size)
	var mesh := _mesher.build_mesh(buffer, [_material])
	var node := _nodes.get(key) as MeshInstance3D
	if mesh == null or mesh.get_surface_count() == 0:
		if node != null:
			node.free()
			_nodes.erase(key)
		return
	if node == null:
		node = MeshInstance3D.new()
		node.name = "Soil_%d_%d_%d" % [key.x, key.y, key.z]
		node.position = Vector3(key * BLOCK) * SCALE
		node.scale = Vector3.ONE * SCALE
		add_child(node)
		var body := StaticBody3D.new()
		body.name = "Support"
		body.collision_layer = 1
		body.collision_mask = 1
		node.add_child(body)
		var shape := CollisionShape3D.new()
		shape.name = "Shape"
		body.add_child(shape)
		_nodes[key] = node
	node.mesh = mesh
	(node.get_node("Support/Shape") as CollisionShape3D).shape = mesh.create_trimesh_shape()


func _ground_height(column: Vector2i, release_y: float) -> float:
	var world := Vector3(column.x * SCALE, release_y, column.y * SCALE)
	# Mutable native soil cannot be treated as permanent support. Keep the
	# overlay on static ground; native in-zone deposits keep their own solver.
	if native_layout != null and native_layout.owns_world_xz(Vector2(world.x, world.z)):
		return INF
	if _supports.has(column):
		return float(_supports[column])
	if not is_instance_valid(ground_root) or not is_inside_tree() or _supports.size() >= MAX_SUPPORT_COLUMNS:
		return INF
	var query := PhysicsRayQueryParameters3D.create(world, world - Vector3.UP * 64.0, 1)
	query.collide_with_areas = false
	var excluded: Array[RID] = []
	for _index in 32:
		query.exclude = excluded
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty():
			return INF
		var collider := hit.get("collider") as Node
		if collider != null and (is_ancestor_of(collider) or collider is VoxelTerrain):
			excluded.append(hit["rid"])
			continue
		var ground_hit := collider != null and (collider == ground_root or ground_root.is_ancestor_of(collider))
		# Terrain3D owns its PhysicsServer body directly (no collider Node).
		if ground_root is Terrain3D and ground_root.collision != null:
			ground_hit = ground_hit or hit.get("rid", RID()) == ground_root.collision.get_rid()
		if not ground_hit:
			return INF
		if (hit["normal"] as Vector3).dot(Vector3.UP) < 0.65:
			return INF
		var height := (hit["position"] as Vector3).y / SCALE
		_supports[column] = height
		return height
	return INF


func _surface_height(column: Vector2i, base: float) -> float:
	if not _column_spans.has(column):
		return base
	var span: Vector2i = _column_spans[column]
	var above := 1.0
	for y in range(span.y + 1, span.x - 2, -1):
		var value := sdf(Vector3i(column.x, y, column.y))
		if value <= 0.0 and above > 0.0:
			return maxf(base, float(y) - value / maxf(0.00001, above - value))
		above = value
	return base


func deposit(release: Vector3, requested: int, field: VoxelSoilMaterialField) -> Dictionary:
	var started := Time.get_ticks_usec()
	if not release.is_finite() or requested <= 0 or requested > field.bucket_mass_q:
		return _reject("invalid_pile_deposit")
	var landing := release / SCALE
	var center := Vector2i(roundi(landing.x), roundi(landing.z))
	_supports.erase(center)
	var ground := _ground_height(center, release.y)
	if not is_finite(ground) or _surface_height(center, ground) >= landing.y - 0.5:
		return _reject("pile_support_unavailable_or_buried")
	var radius := Surface.INITIAL_RADIUS
	var planned: Dictionary = {}
	var heights := PackedFloat64Array()
	var bases := PackedFloat64Array()
	var side := 0
	var first := Vector2i.ZERO
	# Hard computational bound (8 m radius) retains remaining bucket material.
	while radius <= 64:
		side = radius * 2 + 1
		first = center - Vector2i.ONE * radius
		heights.resize(side * side)
		bases.resize(side * side)
		for z in side:
			for x in side:
				var c := first + Vector2i(x, z)
				var base := _ground_height(c, release.y)
				bases[z * side + x] = base
				heights[z * side + x] = _surface_height(c, base) if is_finite(base) else INF
		planned = Surface.plan(heights, side, Vector2(landing.x - first.x, landing.z - first.y),
			field.volume_for_mass_q(requested) / pow(SCALE, 3), tan(deg_to_rad(35.0)))
		if planned.is_empty():
			return _reject("pile_support_unavailable")
		if not bool(planned.get("boundary_active", false)):
			break
		radius *= 2
	if radius > 64:
		return _reject("pile_surface_domain_budget")
	var additions: PackedFloat64Array = planned["additions"]
	var columns: Array[Dictionary] = []
	var origin := Vector3i(2147483647, 2147483647, 2147483647)
	var end := -origin
	var volume := 0.0
	for z in side:
		for x in side:
			var i := z * side + x
			if additions[i] <= 0.000001:
				continue
			var base := heights[i]
			var top := base + additions[i]
			if top - bases[i] > MAX_HEIGHT_M / SCALE:
				return _reject("pile_height_budget")
			var c := first + Vector2i(x, z)
			columns.append({"c": c, "base": base, "top": top, "ground": bases[i]})
			origin = origin.min(Vector3i(c.x - 1, floori(base) - 2, c.y - 1))
			end = end.max(Vector3i(c.x + 2, ceili(top) + 2, c.y + 2))
			volume += additions[i] * pow(SCALE, 3)
	if columns.is_empty() or not _window_allowed(origin, end - origin):
		return _reject("pile_resource_budget")
	var accepted := mini(requested, field.mass_q_for_volume(volume))
	if accepted <= 0:
		return _reject("pile_sub_quantum")
	var scale_volume := field.volume_for_mass_q(accepted) / volume
	var buffer := _copy_window(origin, end - origin)
	var changes: Array[Dictionary] = []
	var remaining := accepted
	var spans := {}
	for column in columns:
		var c: Vector2i = column["c"]
		var base: float = column["base"]
		var top: float = base + (float(column["top"]) - base) * scale_volume
		# Contact skirt extends under the immutable surface by one sample to
		# close the mesh. It has zero material and cannot credit a cut.
		for y in range(floori(base) - 1, ceili(top) + 2):
			var p := Vector3i(c.x, y, c.y) - origin
			var old := buffer.get_voxel_f(p.x, p.y, p.z, CHANNEL)
			var slab := clampf(maxf(y - top, base - 1.0 - y), -1.0, 1.0)
			buffer.set_voxel_f(minf(old, slab), p.x, p.y, p.z, CHANNEL)
		for y in range(floori(base), ceili(top)):
			var cell_volume := maxf(0.0, minf(top, y + 1.0) - maxf(base, y)) * pow(SCALE, 3)
			var mass := mini(remaining, field.mass_q_for_volume(cell_volume))
			if mass > 0:
				changes.append({"coordinate": Vector3i(c.x, y, c.y), "region_id": REGION, "added_mass_q": mass})
				remaining -= mass
		var span: Vector2i = _column_spans.get(c, Vector2i(floori(base) - 1, ceili(top)))
		spans[c] = Vector2i(mini(span.x, floori(base) - 1), maxi(span.y, ceili(top)))
	if changes.is_empty():
		return _reject("pile_sub_quantum")
	changes[-1]["added_mass_q"] = int(changes[-1]["added_mass_q"]) + remaining
	var staged := field.stage_deposit(changes, accepted)
	if not field.can_commit_deposit(staged):
		return _reject("pile_material_invariant")
	_write_window(origin, buffer)
	_column_spans.merge(spans, true)
	field.commit_deposit(staged)
	_track_mass(changes, "added_mass_q", 1)
	_record_time(started)
	return {"accepted": true, "changed": true, "operation": "deposit", "accepted_mass_q": accepted,
		"accepted_volume_m3": field.volume_for_mass_q(accepted),
		"landing_world": Vector3(release.x, _surface_height(center, ground) * SCALE, release.z), "reason": "pile_deposited"}


func cut_pose(pose: Dictionary, identity: Dictionary, field: VoxelSoilMaterialField) -> Dictionary:
	if _blocks.is_empty():
		return {"accepted": false, "reason": "no_piles"}
	var result := cutter.build_proposal(pose, field.generation, int(identity.get("physics_tick", -1)),
		int(identity.get("motion_sequence", -1)), String(identity.get("authority_epoch", "")),
		_engaged, sample_world)
	_engaged = bool(result.get("engaged", false))
	if not bool(result.get("accepted", false)):
		return result
	return cut_proposal(result["proposal"], field)


func cut_proposal(proposal: VoxelCutProposal, field: VoxelSoilMaterialField) -> Dictionary:
	var started := Time.get_ticks_usec()
	var area := proposal.area_voxels.grow(2.0)
	var origin := Vector3i(area.position.floor())
	var size := Vector3i(area.end.ceil()) - origin
	if not _window_allowed(origin, size, false):
		return _reject("pile_cut_budget")
	var before := _copy_window(origin, size)
	var after := _copy_window(origin, size)
	var paths: Array[Dictionary] = proposal.native_paths.duplicate(true)
	if paths.is_empty():
		for capsule in proposal.capsules + proposal.clearance_capsules:
			paths.append({"points_voxels": PackedVector3Array([capsule["a_voxels"], capsule["b_voxels"]]),
				"radii_voxels": PackedFloat32Array([capsule["radius_voxels"], capsule["radius_voxels"]])})
	var job := Preparation.new()
	job.paths = paths
	job.begin_edit(after, origin, 1.0, 1.0)
	while not job.edit_done:
		job.advance_edit(Time.get_ticks_usec() + 1000000)
	var changes: Array[Dictionary] = []
	var total := 0
	var changed := false
	for z in size.z:
		for x in size.x:
			for y in size.y:
				var old := before.get_voxel_f(x, y, z, CHANNEL)
				var value := after.get_voxel_f(x, y, z, CHANNEL)
				if value <= old + 0.00001:
					continue
				changed = true
				var p := origin + Vector3i(x, y, z)
				var mass := field.stable_mass_q_at(p, REGION)
				if mass <= 0:
					continue
				var fraction := clampf((value - old) / maxf(0.00001, 0.5 - old), 0.0, 1.0)
				var removed := mini(mass, roundi(mass * fraction))
				if removed > 0:
					changes.append({"coordinate": p, "region_id": REGION, "removed_mass_q": removed})
					total += removed
	if not changed:
		return _reject("pile_no_change")
	var staged := field.stage_cut(changes, total, true) if total > 0 else {}
	if total > 0 and not field.can_commit_cut(staged):
		return _reject("pile_material_invariant")
	_write_window(origin, after, false)
	if total > 0:
		field.commit_cut(staged)
		_track_mass(changes, "removed_mass_q", -1)
	_reclaim_empty_blocks()
	_record_time(started)
	return {"accepted": true, "changed": true, "operation": "cut", "accepted_mass_q": total,
		"accepted_volume_m3": field.volume_for_mass_q(total), "reason": "pile_cut"}


func _reject(reason: String) -> Dictionary:
	last_reason = reason
	return {"accepted": false, "changed": false, "reason": reason}


func _record_time(started: int) -> void:
	last_reason = ""
	last_commit_usec = Time.get_ticks_usec() - started
	max_commit_usec = maxi(max_commit_usec, last_commit_usec)


func _track_mass(changes: Array[Dictionary], mass_key: String, direction: int) -> void:
	for change in changes:
		var key := _block_key(change["coordinate"])
		var mass := int(_block_mass.get(key, 0)) + direction * int(change[mass_key])
		if mass > 0:
			_block_mass[key] = mass
		else:
			_block_mass.erase(key)


func _reclaim_empty_blocks() -> void:
	# Keep one block halo for the SDF transition, never keep abandoned piles.
	var retained := {}
	for key: Vector3i in _block_mass:
		for z in range(-1, 2):
			for x in range(-1, 2):
				for y in range(-1, 2):
					retained[key + Vector3i(x,y,z)] = true
	for key in _blocks.keys():
		if not retained.has(key):
			_blocks.erase(key)
			_dirty[key] = true
	_supports.clear()
	if _block_mass.is_empty():
		_column_spans.clear()
	else:
		for column: Vector2i in _column_spans.keys():
			var span: Vector2i = _column_spans[column]
			var found := false
			for y in range(floori(float(span.x)/BLOCK), floori(float(span.y)/BLOCK)+1):
				if _blocks.has(Vector3i(floori(float(column.x)/BLOCK),y,floori(float(column.y)/BLOCK))):
					found = true
					break
			if not found:
				_column_spans.erase(column)


func is_support_ready_at(world: Vector3) -> bool:
	var key := _block_key(Vector3i((world / SCALE).floor()))
	return _nodes.has(key) and not _dirty.has(key)
