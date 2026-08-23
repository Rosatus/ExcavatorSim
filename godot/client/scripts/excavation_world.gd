class_name ExcavationWorld
extends Node3D

signal excavation_changed(status: Dictionary)

const SOIL_PROXY_ORDER := ["cutting_edge", "opening", "cavity", "shell", "rear_support"]

@export var terrain_world_path := NodePath("../TerrainWorld")
@export var terrain_collider_path := NodePath("../TerrainCollider")
@export var motion_presentation_path := NodePath("../../MotionPresentation")
@export var motion_client_path := NodePath("../../MotionClient")
@export var tracked_chassis_controller_path := NodePath("../../ChassisMotionRoot")
@export var automatic_soil_enabled := true
@export var debug_manual_controls := false
@export var hero_clods_enabled := true
@export var backend_feedback_enabled := false
@export_enum("low", "balanced", "high") var feedback_quality := "balanced"
@export var local_tooth_offset := Vector3(0.0, -0.55, 0.0)

var terrain_world: TerrainWorld
var terrain_collider: TerrainCollider
var terrain_scheduler: TerrainCommitScheduler
var soil_state: BucketSoilState
var authority_generation := 0

var _presentation: MotionPresentation
var _motion_client: MotionClient
var _tracked_chassis_controller: TrackedChassisController
var _next_command_sequence := 0
var _last_pose_snapshot: Dictionary = {}
var _last_interaction := "idle"
var _last_support: Dictionary = {"active": false, "penetration_m": 0.0}
var _last_flow_volume_m3 := 0.0
var _last_raw_support_point := Vector3.ZERO
var _has_raw_support_point := false
var _material_generation := 0
var _initialized := false
var _last_interaction_batch: Dictionary = {}
var _consumed_batch_keys: Dictionary = {}
var _consumed_batch_order: Array[String] = []
var _parcel_pool: SoilParcelPool


func _ready() -> void:
	process_physics_priority = 20
	_initialize()


func _initialize() -> void:
	if _initialized:
		return
	terrain_world = get_node_or_null(terrain_world_path) as TerrainWorld
	terrain_collider = get_node_or_null(terrain_collider_path) as TerrainCollider
	_presentation = get_node_or_null(motion_presentation_path) as MotionPresentation
	if terrain_world == null or terrain_world.terrain_state == null or _presentation == null:
		call_deferred("_initialize")
		return
	var contract := _presentation.get_soil_contract()
	if contract.is_empty():
		call_deferred("_initialize")
		return
	_sync_local_tooth_offset(contract)
	terrain_scheduler = TerrainCommitScheduler.new(terrain_world.terrain_state, terrain_world, terrain_collider)
	soil_state = BucketSoilState.new(terrain_world.terrain_state, contract, terrain_scheduler)
	terrain_scheduler.refresh_collider_derivative()
	_create_parcel_pool(contract)
	_motion_client = get_node_or_null(motion_client_path) as MotionClient
	_tracked_chassis_controller = get_node_or_null(tracked_chassis_controller_path) as TrackedChassisController
	if _motion_client != null:
		if not _motion_client.pose_cleared.is_connected(_on_pose_cleared):
			_motion_client.pose_cleared.connect(_on_pose_cleared)
		if not _motion_client.authority_changed.is_connected(_on_authority_changed):
			_motion_client.authority_changed.connect(_on_authority_changed)
	if not _presentation.model_activated.is_connected(_on_model_activated):
		_presentation.model_activated.connect(_on_model_activated)
	if not terrain_world.world_reset.is_connected(_on_world_reset):
		terrain_world.world_reset.connect(_on_world_reset)
	_initialized = true
	excavation_changed.emit(get_status_snapshot())


func _physics_process(delta: float) -> void:
	if soil_state == null or terrain_scheduler == null:
		return
	if automatic_soil_enabled:
		_step_automatic_interaction(delta)
	var soil_result := soil_state.step_fixed()
	_last_flow_volume_m3 = float(soil_result.get("cut_volume_m3", 0.0)) + float(soil_result.get("deposit_volume_m3", 0.0))
	if _parcel_pool != null:
		_parcel_pool.notify_deposit_results(soil_result.get("parcel_deposit_results", []))
	var cells_changed := _settle_bucket_cells(delta)
	_spawn_cut_parcels(soil_result)
	if _parcel_pool != null:
		_step_parcel_pool(delta)
	# Force-flush every fixed tick: the analytic dig loop samples TerrainState
	# as its authority, so cut brushes must land in the same tick they are
	# queued. Latency batching here starved the invariant (surface yields only
	# after up to 150 ms), ramping engagement and stalling downward strokes.
	# Presentation coalescing lives downstream in the dirty-rect patchers.
	var commit_result := terrain_scheduler.step_fixed(delta, true)
	soil_state.reconcile_transfers(
		commit_result.get("committed_transfer_ids", []),
		commit_result.get("rejected_transfer_ids", [])
	)
	if _parcel_pool != null:
		_parcel_pool.notify_deposit_commits(
			commit_result.get("committed_transfer_ids", []),
			commit_result.get("rejected_transfer_ids", [])
		)
	_queue_backend_feedback()
	if bool(soil_result.get("changed", false)) or cells_changed or bool(commit_result.get("changed", false)):
		excavation_changed.emit(get_status_snapshot())


func queue_cut_world(sequence: int, previous_tooth: Vector3, current_tooth: Vector3) -> bool:
	if soil_state == null:
		return false
	_next_command_sequence = maxi(_next_command_sequence, sequence + 1)
	return soil_state.queue_cut(sequence, previous_tooth, current_tooth)


func queue_deposit_world(sequence: int, center: Vector3) -> bool:
	if soil_state == null:
		return false
	_next_command_sequence = maxi(_next_command_sequence, sequence + 1)
	return soil_state.queue_deposit(sequence, center)


func step_fixed_for_test() -> Dictionary:
	if soil_state == null or terrain_scheduler == null:
		return {"changed": false, "reason": "unavailable"}
	var result := soil_state.step_fixed()
	_last_flow_volume_m3 = float(result.get("cut_volume_m3", 0.0)) + float(result.get("deposit_volume_m3", 0.0))
	if _parcel_pool != null:
		_parcel_pool.notify_deposit_results(result.get("parcel_deposit_results", []))
	_spawn_cut_parcels(result)
	var commit := terrain_scheduler.step_fixed(0.0, true)
	soil_state.reconcile_transfers(
		commit.get("committed_transfer_ids", []),
		commit.get("rejected_transfer_ids", [])
	)
	if _parcel_pool != null:
		_parcel_pool.notify_deposit_commits(
			commit.get("committed_transfer_ids", []),
			commit.get("rejected_transfer_ids", [])
		)
	result["bucket_volume_m3"] = soil_state.bucket_volume_m3
	result["terrain_committed"] = bool(commit.get("changed", false))
	result["terrain_commit"] = commit
	if bool(result.get("changed", false)) or bool(commit.get("changed", false)):
		excavation_changed.emit(get_status_snapshot())
	return result


func request_dig() -> bool:
	if not debug_manual_controls:
		return false
	var snapshot := _sample_bucket_pose()
	if not bool(snapshot.get("valid", false)):
		return false
	var previous: Dictionary = snapshot["previous"]
	var current: Dictionary = snapshot["current"]
	var accepted := queue_cut_world(
		_next_command_sequence,
		(previous["cutting_edge"] as Transform3D).origin,
		(current["cutting_edge"] as Transform3D).origin
	)
	if accepted:
		step_fixed_for_test()
	return accepted


func request_deposit() -> bool:
	if not debug_manual_controls:
		return false
	var snapshot := _sample_bucket_pose()
	if snapshot.is_empty():
		return false
	var current: Dictionary = snapshot.get("current", {})
	if not current.has("opening"):
		return false
	var accepted := queue_deposit_world(_next_command_sequence, (current["opening"] as Transform3D).origin)
	if accepted:
		step_fixed_for_test()
	return accepted


func reset_for_test() -> void:
	if terrain_scheduler == null:
		return
	terrain_scheduler.reset_world()
	excavation_changed.emit(get_status_snapshot())


func set_automatic_soil_enabled(value: bool) -> void:
	if automatic_soil_enabled == value:
		return
	automatic_soil_enabled = value
	_clear_local_material("feature_toggle")


func set_backend_feedback_enabled(value: bool) -> void:
	backend_feedback_enabled = value
	if not value and _motion_client != null:
		_motion_client.clear_bucket_load_feedback()


func get_status_snapshot() -> Dictionary:
	var status := soil_state.get_status_snapshot() if soil_state != null else {"bucket_volume_m3": 0.0, "world_generation": -1}
	status["authority_generation"] = authority_generation
	status["automatic_soil_enabled"] = automatic_soil_enabled
	status["debug_manual_controls"] = debug_manual_controls
	status["hero_clods_enabled"] = hero_clods_enabled
	status["backend_feedback_enabled"] = backend_feedback_enabled
	status["interaction_state"] = _last_interaction
	status["material_generation"] = _material_generation
	status["flow_volume_m3"] = _last_flow_volume_m3
	status["bucket_pose"] = _last_pose_snapshot.duplicate(true)
	status["support_contact"] = _last_support.duplicate(true)
	status["soil_interaction_batch"] = _last_interaction_batch.duplicate(true)
	status["terrain_commit"] = terrain_scheduler.get_status_snapshot() if terrain_scheduler != null else {}
	status["collider_available"] = terrain_collider != null and terrain_collider.available
	status["collider_enabled"] = terrain_collider != null and terrain_collider.enabled
	status["terrain3d"] = terrain_world.terrain3d_adapter.get_status_snapshot() if terrain_world != null and terrain_world.terrain3d_adapter != null else {"enabled": false, "available": false}
	status["physics_fail_open"] = true
	return status


func get_bucket_pose_snapshot_for_test() -> Dictionary:
	return _last_pose_snapshot.duplicate(true)


func get_dig_diagnostics() -> Dictionary:
	# Live press-block triage: every gate on the downward-dig path in one read.
	var chassis := _tracked_chassis_controller.get_status_snapshot() if _tracked_chassis_controller != null else {}
	var boom := {}
	for state_value in chassis.get("joints", []):
		var state := state_value as Dictionary
		if String(state.get("name", "")) == "boom_joint":
			boom = state
	var payload := chassis.get("payload", {}) as Dictionary
	var batch := _last_interaction_batch
	return {
		"interaction": _last_interaction,
		"penetration_m": float(batch.get("analytic_penetration_m", 0.0)),
		"engagement": float(payload.get("cut_engagement", 0.0)),
		"boom_velocity": float(boom.get("velocity_rad_s", 0.0)),
		"boom_position": float(boom.get("position_rad", 0.0)),
		"enabled": bool(chassis.get("enabled", false)),
		"focused": bool(chassis.get("focused", false)),
	}


func step_automatic_snapshot_for_test(snapshot: Dictionary, delta: float = 1.0 / 60.0) -> Dictionary:
	if soil_state == null or terrain_scheduler == null:
		return {"changed": false, "reason": "unavailable"}
	_process_bucket_snapshot(snapshot, delta)
	var soil_result := soil_state.step_fixed()
	_last_flow_volume_m3 = float(soil_result.get("cut_volume_m3", 0.0)) + float(soil_result.get("deposit_volume_m3", 0.0))
	if _parcel_pool != null:
		_parcel_pool.notify_deposit_results(soil_result.get("parcel_deposit_results", []))
	_settle_bucket_cells(delta)
	_spawn_cut_parcels(soil_result)
	if _parcel_pool != null:
		_step_parcel_pool(delta)
	var commit_result := terrain_scheduler.step_fixed(delta, true)
	soil_state.reconcile_transfers(
		commit_result.get("committed_transfer_ids", []),
		commit_result.get("rejected_transfer_ids", [])
	)
	if _parcel_pool != null:
		_parcel_pool.notify_deposit_commits(
			commit_result.get("committed_transfer_ids", []),
			commit_result.get("rejected_transfer_ids", [])
		)
	var result := get_status_snapshot()
	result["changed"] = bool(soil_result.get("changed", false)) or bool(commit_result.get("changed", false))
	result["terrain_commit_result"] = commit_result
	excavation_changed.emit(result)
	return result


func _bucket_tooth_world() -> Variant:
	if _presentation == null:
		return null
	var contract := _presentation.get_soil_contract()
	var cutting: Dictionary = (contract.get("proxies", {}) as Dictionary).get("cutting_edge", {})
	var raw_center: Variant = cutting.get("center_godot", [])
	var frame := _presentation.get_frame_node(String(cutting.get("frame", "bucket_link")))
	if frame == null or not raw_center is Array or (raw_center as Array).size() != 3:
		return null
	var center := Vector3(float(raw_center[0]), float(raw_center[1]), float(raw_center[2]))
	return frame.global_transform * center


func get_soil_visual_snapshot() -> Dictionary:
	var status := soil_state.get_status_snapshot() if soil_state != null else {}
	return {
		"world_generation": int(status.get("world_generation", -1)),
		"authority_generation": authority_generation,
		"material_generation": _material_generation,
		"fill_ratio": float(status.get("fill_ratio", 0.0)),
		"fill_profile": status.get("fill_profile", PackedFloat32Array()),
		"cell_grid": status.get("cell_grid", [1, 1, 1]),
		"center_of_mass_local": status.get("center_of_mass_local", Vector3.ZERO),
		"flow_volume_m3": _last_flow_volume_m3,
		"interaction_state": _last_interaction,
		"hero_clods_enabled": hero_clods_enabled,
		"bucket_pose": _last_pose_snapshot.duplicate(true),
	}


func _step_automatic_interaction(delta: float) -> void:
	var snapshot := _sample_bucket_pose()
	_process_bucket_snapshot(snapshot, delta)


func _process_bucket_snapshot(snapshot: Dictionary, delta: float) -> void:
	_last_pose_snapshot = snapshot.duplicate(true)
	if not bool(snapshot.get("valid", false)):
		_last_interaction = "no_pose"
		_last_support = {"active": false, "penetration_m": 0.0}
		_last_raw_support_point = Vector3.ZERO
		_has_raw_support_point = false
		if _tracked_chassis_controller != null:
			_tracked_chassis_controller.clear_bucket_support_contact()
		return
	var previous: Dictionary = snapshot["previous"]
	var current: Dictionary = snapshot["current"]
	var previous_cutting := previous["cutting_edge"] as Transform3D
	var current_cutting := current["cutting_edge"] as Transform3D
	var contract: Dictionary = snapshot["contract"]
	var interaction: Dictionary = contract.get("interaction", {})
	_update_support_contact(snapshot, current, contract)
	var batch := _build_interaction_batch(snapshot)
	if not bool(batch.get("eligible", false)):
		_last_interaction = "blocked"
		return
	var deposit_center: Variant = _settled_deposit_center((current["opening"] as Transform3D).origin)
	var opening_down_dot := (snapshot["opening_normal_world"] as Vector3).dot(Vector3.DOWN)
	var dump_threshold := float(interaction.get("dump_opening_down_dot", 0.3))
	var operation := String(batch.get("operation", "none"))
	if operation == "dump" and deposit_center is Vector3:
		var dump_rate := soil_state.bucket_capacity_m3 * lerpf(0.35, 1.4, clampf((opening_down_dot - dump_threshold) / maxf(0.01, 1.0 - dump_threshold), 0.0, 1.0))
		var requested := minf(soil_state.bucket_volume_m3, dump_rate * delta)
		if _pour_from_bucket(batch, requested, (current["opening"] as Transform3D), "dump"):
			_next_command_sequence += 1
			_last_interaction = "dump"
			return
	var spill_threshold := float(interaction.get("spill_opening_down_dot", dump_threshold - 0.25))
	if operation == "spill" and deposit_center is Vector3:
		var exposure := clampf((opening_down_dot - spill_threshold) / maxf(0.01, dump_threshold - spill_threshold), 0.0, 1.0)
		var spill_rate := soil_state.bucket_capacity_m3 * lerpf(0.04, 0.22, exposure)
		var spill_volume := minf(soil_state.bucket_volume_m3, spill_rate * delta)
		if _pour_from_bucket(batch, spill_volume, (current["opening"] as Transform3D), "spill"):
			_next_command_sequence += 1
			_last_interaction = "spill"
			return
	if operation == "cutting":
		var cut_motion := _cut_motion_from_batch(batch, previous_cutting.origin, current_cutting.origin)
		if _queue_batch_cut(batch, cut_motion["previous"], cut_motion["current"]):
			_next_command_sequence += 1
			_last_interaction = "cut"
			return
	_last_interaction = "carry" if operation == "carry" else ("push" if not (batch.get("classifications", []) as Array).is_empty() else "idle")
	_last_interaction_batch["operation"] = _last_interaction


func _build_interaction_batch(snapshot: Dictionary) -> Dictionary:
	var chassis := _tracked_chassis_controller.get_status_snapshot() if _tracked_chassis_controller != null else {}
	var hybrid := String(chassis.get("authority_profile", "")) == AuthorityProfile.JOLT_AUTHORITATIVE
	var query := chassis.get("bucket_query", {}) as Dictionary
	var physics_tick := int(query.get("physics_tick", chassis.get("physics_tick", Engine.get_physics_frames()))) if hybrid else Engine.get_physics_frames()
	var motion_sequence := int(query.get("motion_sequence", chassis.get("bucket_motion_sequence", _next_command_sequence))) if hybrid else _next_command_sequence
	var epoch := String(query.get("authority_epoch", chassis.get("authority_epoch", ""))) if hybrid else String(snapshot.get("identity", "local"))
	var terrain_generation := int(query.get("terrain_generation", -1)) if hybrid else terrain_world.terrain_state.world_generation
	var terrain_revision := int(query.get("terrain_revision", -1)) if hybrid else terrain_world.terrain_state.terrain_revision
	var key := "%s|%d|%d|%d|%d" % [epoch, physics_tick, terrain_generation, terrain_revision, motion_sequence]
	var identity_valid := not hybrid or (
		bool(query.get("valid", false))
		and epoch == String(chassis.get("authority_epoch", ""))
		and physics_tick == int(chassis.get("physics_tick", -1))
		and motion_sequence == int(chassis.get("bucket_motion_sequence", -1))
		and terrain_generation == terrain_world.terrain_state.world_generation
		and terrain_revision == terrain_world.terrain_state.terrain_revision
	)
	var contacts: Array[Dictionary] = []
	for contact_value in query.get("contacts", []):
		if contact_value is Dictionary:
			contacts.append((contact_value as Dictionary).duplicate(true))
	contacts.sort_custom(_contact_evidence_less)
	var contact_roles: Array[String] = []
	for contact in contacts:
		contact_roles.append(String(contact.get("proxy_role", "")))
	# Analytic soil evidence: penetration sampled straight from the
	# authoritative heightfield under the kinematic tooth pose. Queries never
	# arbitrate cutting; they only add supplementary contact evidence and gate
	# support transactions.
	var analytic := _analytic_cut_evidence(snapshot, chassis)
	var classifications := _classify_interaction_records(snapshot, contacts, hybrid, identity_valid, physics_tick, motion_sequence, analytic)
	var operation := _reduce_soil_operation(classifications)
	var consumed_contact_ids: Array[String] = []
	for record in classifications:
		if String(record.get("classification", "blocked")) != "blocked":
			consumed_contact_ids.append(String(record.get("contact_id", "")))
	var batch := {
		"key": key,
		"authority_epoch": epoch,
		"physics_tick": physics_tick,
		"terrain_generation": terrain_generation,
		"terrain_revision": terrain_revision,
		"bucket_motion_sequence": motion_sequence,
		"eligible": identity_valid or bool(analytic.get("cut_ready", false)),
		"query_required": hybrid,
		"duplicate": _consumed_batch_keys.has(key),
		"consumed_contact_ids": consumed_contact_ids,
		"contact_roles": contact_roles,
		"classifications": classifications,
		"operation": operation,
		"query_identity_valid": identity_valid,
		"analytic_engaged": bool(analytic.get("engaged", false)),
		"analytic_penetration_m": float(analytic.get("penetration_m", 0.0)),
		"transaction_queued": false,
	}
	if bool(batch["duplicate"]):
		batch["eligible"] = false
	_last_interaction_batch = batch.duplicate(true)
	return batch


func _classify_interaction_records(
	snapshot: Dictionary,
	contacts: Array[Dictionary],
	query_required: bool,
	query_identity_valid: bool,
	physics_tick: int,
	motion_sequence: int,
	analytic: Dictionary
) -> Array[Dictionary]:
	var previous := snapshot.get("previous", {}) as Dictionary
	var current := snapshot.get("current", {}) as Dictionary
	var contract := snapshot.get("contract", {}) as Dictionary
	var interaction := contract.get("interaction", {}) as Dictionary
	var classifications: Array[Dictionary] = []
	var maximum_cut_depth := float(interaction.get("maximum_cut_depth_m", BucketSoilState.MAX_CUT_DEPTH_M))
	var previous_cutting := previous.get("cutting_edge", Transform3D.IDENTITY) as Transform3D
	var current_cutting := current.get("cutting_edge", Transform3D.IDENTITY) as Transform3D
	var center_xz := Vector2(current_cutting.origin.x, current_cutting.origin.z)
	var surface := terrain_world.terrain_state.sample_surface_bilinear_at(center_xz)
	var tolerance := float(interaction.get("contact_tolerance_m", BucketSoilState.CONTACT_TOLERANCE_M))
	var in_contact := not is_nan(surface) and current_cutting.origin.y <= surface + tolerance
	# Analytic evidence is the primary cutting trigger; a validated in-band
	# query contact plus intent stays available as a supplementary trigger for
	# genuine mesh contacts the width samples cannot see.
	var analytic_cut := bool(analytic.get("cut_ready", false))
	var intent := bool(analytic.get("intent", false))
	for contact in contacts:
		var record := contact.duplicate(true)
		var role := String(record.get("proxy_role", ""))
		var classification := "blocked"
		if not bool(record.get("initial_overlap", false)):
			if role == "cutting_edge":
				var record_in_contact := in_contact
				if query_required:
					# Working-band evidence anchored on the authoritative
					# surface at the contact point; initial overlap can never
					# disarm analytic cutting, only this supplementary path.
					var point := record.get("point_world", Vector3.ZERO) as Vector3
					var point_surface := terrain_world.terrain_state.sample_surface_bilinear_at(Vector2(point.x, point.z))
					record_in_contact = (
						bool(record.get("point_valid", true)) and point.is_finite()
						and not is_nan(point_surface)
						and point.y <= point_surface + tolerance
						and point.y >= point_surface - maximum_cut_depth
					)
				if analytic_cut or (record_in_contact and intent):
					classification = "cutting"
			elif ["shell", "rear_support"].has(role):
				classification = "support" if (query_identity_valid and _is_support_record(snapshot, record)) else "blocked"
		record["classification"] = classification
		classifications.append(record)
	if analytic_cut or (not query_required and in_contact and intent):
		classifications.append({
			"contact_id": "analytic:%d:%d:cutting" % [physics_tick, motion_sequence],
			"proxy_role": "cutting_edge",
			"travel_fraction": 1.0,
			"classification": "cutting",
			"evidence": "analytic_penetration" if analytic_cut else "legacy_motion",
		})
	var bucket_loaded := soil_state.bucket_volume_m3 > BucketSoilState.EPSILON_M3
	if bucket_loaded and (not query_required or query_identity_valid):
		var opening_down_dot := (snapshot.get("opening_normal_world", Vector3.UP) as Vector3).dot(Vector3.DOWN)
		var dump_threshold := float(interaction.get("dump_opening_down_dot", 0.3))
		var spill_threshold := float(interaction.get("spill_opening_down_dot", dump_threshold - 0.25))
		var fill_ratio := soil_state.bucket_volume_m3 / maxf(soil_state.nominal_capacity_m3, BucketSoilState.EPSILON_M3)
		var retained_classification := "carry"
		if opening_down_dot > dump_threshold:
			retained_classification = "dump"
		elif opening_down_dot > spill_threshold and fill_ratio > 0.45:
			retained_classification = "spill"
		classifications.append({
			"contact_id": "%d:%d:opening_state" % [physics_tick, motion_sequence],
			"proxy_role": "opening",
			"travel_fraction": 1.0,
			"classification": retained_classification,
			"evidence": "accepted_orientation",
		})
	return classifications


func _is_support_record(snapshot: Dictionary, record: Dictionary) -> bool:
	var role := String(record.get("proxy_role", ""))
	var previous := snapshot.get("previous", {}) as Dictionary
	var current := snapshot.get("current", {}) as Dictionary
	if not previous.has(role) or not current.has(role):
		return false
	var normal := record.get("normal_world", Vector3.UP) as Vector3
	if not normal.is_finite() or normal.length_squared() < 0.5 or normal.normalized().dot(Vector3.UP) < 0.2:
		return false
	var movement := (current[role] as Transform3D).origin - (previous[role] as Transform3D).origin
	return -movement.dot(normal.normalized()) >= 0.001


func _analytic_cut_evidence(snapshot: Dictionary, chassis: Dictionary) -> Dictionary:
	var result := {"engaged": false, "penetration_m": 0.0, "intent": false, "cut_ready": false}
	if terrain_world == null or terrain_world.terrain_state == null:
		return result
	var previous := snapshot.get("previous", {}) as Dictionary
	var current := snapshot.get("current", {}) as Dictionary
	if not previous.has("cutting_edge") or not current.has("cutting_edge"):
		return result
	var contract := snapshot.get("contract", {}) as Dictionary
	var interaction := contract.get("interaction", {}) as Dictionary
	var maximum_depth := float(interaction.get("maximum_cut_depth_m", BucketSoilState.MAX_CUT_DEPTH_M))
	var tolerance := float(interaction.get("contact_tolerance_m", BucketSoilState.CONTACT_TOLERANCE_M))
	var state := terrain_world.terrain_state
	# Sample the authoritative surface under the tooth center for the previous
	# and current poses. Width-end samples deliberately do NOT feed this signal:
	# over untouched ground beside the hole they read runaway penetration and
	# would permanently disengage a correctly digging bucket. Off-center mesh
	# contacts remain covered by the supplementary query trigger.
	var max_penetration := -INF
	for edge_value in [previous["cutting_edge"], current["cutting_edge"]]:
		var edge := edge_value as Transform3D
		if not edge.is_finite():
			return result
		var surface := state.sample_surface_bilinear_at(Vector2(edge.origin.x, edge.origin.z))
		if is_nan(surface):
			continue
		max_penetration = maxf(max_penetration, surface - edge.origin.y)
	# Intent is computed unconditionally: the supplementary query trigger needs
	# it even when the width samples sit above grade.
	result["intent"] = _chassis_dig_intent(chassis) or _tooth_movement_intent(snapshot, interaction)
	# Sub-millimeter penetration is resting-contact noise, not a stroke; below
	# this the depth floor would over-remove relative to the press rate and
	# oscillate the loop between cutting and carry.
	if max_penetration < 0.001 or max_penetration > maximum_depth + tolerance:
		return result
	result["engaged"] = true
	result["penetration_m"] = max_penetration
	result["cut_ready"] = result["intent"]
	return result


func _chassis_dig_intent(chassis: Dictionary) -> bool:
	# Any active work-equipment command counts as dig intent, swing included:
	# dragging an engaged edge sideways through soil is a real cutting stroke.
	for state_value in chassis.get("joints", []):
		var state := state_value as Dictionary
		if float(state.get("target_velocity_rad_s", 0.0)) < -0.01:
			return true
	return false


func _tooth_movement_intent(snapshot: Dictionary, interaction: Dictionary) -> bool:
	var previous := snapshot.get("previous", {}) as Dictionary
	var current := snapshot.get("current", {}) as Dictionary
	var movement := (current["cutting_edge"] as Transform3D).origin - (previous["cutting_edge"] as Transform3D).origin
	var minimum_sweep := float(interaction.get("minimum_sweep_m", 0.004))
	if movement.length() >= minimum_sweep and movement.normalized().dot(snapshot.get("cutting_direction_world", Vector3.DOWN) as Vector3) > 0.12:
		return true
	return movement.y < -minimum_sweep * 0.35


func _reduce_soil_operation(classifications: Array[Dictionary]) -> String:
	for operation in ["dump", "spill", "cutting", "carry"]:
		for record in classifications:
			if String(record.get("classification", "")) == operation:
				return operation
	return "none"


func _contact_evidence_less(first: Dictionary, second: Dictionary) -> bool:
	var first_fraction := float(first.get("travel_fraction", 1.0))
	var second_fraction := float(second.get("travel_fraction", 1.0))
	if not is_equal_approx(first_fraction, second_fraction):
		return first_fraction < second_fraction
	var first_role := SOIL_PROXY_ORDER.find(String(first.get("proxy_role", "")))
	var second_role := SOIL_PROXY_ORDER.find(String(second.get("proxy_role", "")))
	if first_role != second_role:
		return first_role < second_role
	return String(first.get("contact_id", "")) < String(second.get("contact_id", ""))


func _queue_batch_cut(batch: Dictionary, previous_tooth: Vector3, current_tooth: Vector3) -> bool:
	if not bool(batch.get("eligible", false)) or _consumed_batch_keys.has(String(batch.get("key", ""))):
		return false
	if not soil_state.queue_cut(_next_command_sequence, previous_tooth, current_tooth):
		return false
	_consume_interaction_batch(batch, "cutting")
	return true


func _cut_motion_from_batch(batch: Dictionary, previous_tooth: Vector3, current_tooth: Vector3) -> Dictionary:
	# Analytic cuts use the real tooth path. The supplementary query trigger
	# may validate a contact the width samples cannot see (cross-slope single
	# edge touch); that cut lands on the validated contact point instead,
	# otherwise the tooth-height gate in _apply_cut would reject it.
	if bool(batch.get("analytic_engaged", false)):
		return {"previous": previous_tooth, "current": current_tooth}
	for record_value in batch.get("classifications", []):
		var record := record_value as Dictionary
		if String(record.get("classification", "")) != "cutting":
			continue
		var contact_point := record.get("point_world", Vector3.ZERO) as Vector3
		if bool(record.get("point_valid", true)) and contact_point.is_finite():
			var movement := current_tooth - previous_tooth
			return {"previous": contact_point - movement, "current": contact_point}
	return {"previous": previous_tooth, "current": current_tooth}


func _queue_batch_deposit(batch: Dictionary, center: Vector3, volume_m3: float, operation: String) -> bool:
	if not bool(batch.get("eligible", false)) or _consumed_batch_keys.has(String(batch.get("key", ""))):
		return false
	if not soil_state.queue_deposit_volume(_next_command_sequence, center, volume_m3):
		return false
	_consume_interaction_batch(batch, operation)
	return true


func _pour_from_bucket(batch: Dictionary, volume_m3: float, opening_transform: Transform3D, operation: String) -> bool:
	# Dump/spill hand ledger volume to transport parcels at the lip instead of
	# writing terrain directly; parcels fall under gravity and settle back
	# through the deposit pipeline where they land.
	if _parcel_pool == null or not bool(batch.get("eligible", false)) or _consumed_batch_keys.has(String(batch.get("key", ""))):
		return false
	var pour_direction := (opening_transform.basis * Vector3.DOWN).normalized()
	var released := _parcel_pool.release_volume(volume_m3, opening_transform.origin, pour_direction)
	if released <= BucketSoilState.EPSILON_M3:
		return false
	_consume_interaction_batch(batch, operation)
	return true


func _create_parcel_pool(contract: Dictionary) -> void:
	_parcel_pool = SoilParcelPool.new()
	_parcel_pool.name = "SoilParcelPool"
	var layers := {"machine": 2, "terrain": 1}
	if _tracked_chassis_controller != null:
		layers.merge(_tracked_chassis_controller.get_collision_layers(), true)
	var payload_layer := int(layers.get("payload", 6))
	var machine_layer := int(layers.get("machine", 2))
	var terrain_layer := int(layers.get("terrain", 1))
	add_child(_parcel_pool)
	_parcel_pool.setup({
		"soil_state": soil_state,
		"budget": 48,
		"density_kg_m3": soil_state.material_density_kg_m3,
		"collision_layer": 1 << (payload_layer - 1),
		"collision_mask": (1 << (terrain_layer - 1)) | (1 << (machine_layer - 1)),
		"barrier_layer": 1 << (machine_layer - 1),
		"barrier_extents": _cavity_extents_from_contract(contract),
		"deposit_sequencer": _allocate_command_sequence,
	})


func _allocate_command_sequence() -> int:
	var sequence := _next_command_sequence
	_next_command_sequence += 1
	return sequence


func _spawn_cut_parcels(soil_result: Dictionary) -> void:
	if _parcel_pool == null:
		return
	for event_value in soil_result.get("cut_events", []):
		var event := event_value as Dictionary
		_parcel_pool.spawn_from_cut(
			event.get("tooth_world", Vector3.ZERO) as Vector3,
			float(event.get("volume_m3", 0.0)),
			event.get("tooth_velocity", Vector3.ZERO) as Vector3
		)


func _step_parcel_pool(delta: float) -> void:
	var current: Dictionary = _last_pose_snapshot.get("current", {})
	if not current.has("cavity"):
		return
	var contract := _presentation.get_soil_contract() if _presentation != null else {}
	_parcel_pool.step_pool(delta, current["cavity"] as Transform3D, _cavity_extents_from_contract(contract))


func _cavity_extents_from_contract(contract: Dictionary) -> Vector3:
	var cavity_proxy: Dictionary = (contract.get("proxies", {}) as Dictionary).get("cavity", {})
	var size_array: Variant = cavity_proxy.get("size_m", [])
	if size_array is Array and (size_array as Array).size() == 3:
		return Vector3(float(size_array[0]), float(size_array[1]), float(size_array[2])) * 0.5
	return Vector3(0.25, 0.25, 0.35)


func _consume_interaction_batch(batch: Dictionary, operation: String) -> void:
	var key := String(batch.get("key", ""))
	if key.is_empty() or _consumed_batch_keys.has(key):
		return
	_consumed_batch_keys[key] = operation
	_consumed_batch_order.append(key)
	while _consumed_batch_order.size() > 512:
		_consumed_batch_keys.erase(_consumed_batch_order.pop_front())
	_last_interaction_batch = batch.duplicate(true)
	_last_interaction_batch["operation"] = operation
	_last_interaction_batch["transaction_queued"] = true


func _update_support_contact(snapshot: Dictionary, current: Dictionary, contract: Dictionary) -> void:
	var support_transform := current["rear_support"] as Transform3D
	var raw_support_transform := support_transform
	if _tracked_chassis_controller != null:
		raw_support_transform = _tracked_chassis_controller.raw_world_transform(support_transform)
	var center_xz := Vector2(raw_support_transform.origin.x, raw_support_transform.origin.z)
	var surface := terrain_world.terrain_state.sample_surface_bilinear_at(center_xz)
	var support_contract: Dictionary = (contract.get("proxies", {}) as Dictionary).get("rear_support", {})
	var radius := float(support_contract.get("radius_m", 0.0))
	var penetration := 0.0 if is_nan(surface) else maxf(0.0, surface + radius - raw_support_transform.origin.y)
	var movement := raw_support_transform.origin - _last_raw_support_point if _has_raw_support_point else Vector3.ZERO
	var penetration_delta := penetration - float(_last_support.get("penetration_m", 0.0))
	var cutting_direction := snapshot.get("cutting_direction_world", Vector3.DOWN) as Vector3
	var opening_normal := snapshot.get("opening_normal_world", Vector3.UP) as Vector3
	var classification := BucketGroundLiftReaction.classify_contact(
		penetration,
		penetration_delta,
		movement,
		Vector3.UP,
		cutting_direction,
		opening_normal,
		bool(_last_support.get("eligible", false))
	)
	var eligible := bool(classification.get("eligible", false))
	_last_support = {
		"active": penetration > 0.0,
		"eligible": eligible,
		"classification": String(classification.get("classification", "invalid")),
		"penetration_m": penetration,
		"point_world": raw_support_transform.origin,
		"movement_world": movement,
		"surface_y": surface,
		"terrain_normal_world": Vector3.UP,
		"opening_down_dot": opening_normal.dot(Vector3.DOWN),
		"model_id": _presentation.get_active_model_id() if _presentation != null else "",
		"authority_generation": authority_generation,
		"physics_hint_status": "heightfield_fallback",
	}
	_last_raw_support_point = raw_support_transform.origin
	_has_raw_support_point = true
	if _tracked_chassis_controller != null:
		_tracked_chassis_controller.submit_bucket_support_contact(_last_support)


func _sample_bucket_pose() -> Dictionary:
	if _presentation == null or terrain_world == null or terrain_world.terrain_state == null:
		return {"valid": false, "reason": "unavailable"}
	return _presentation.sample_bucket_pose_fixed(terrain_world.terrain_state.world_generation, authority_generation)


func _settle_bucket_cells(delta: float) -> bool:
	var current: Dictionary = _last_pose_snapshot.get("current", {})
	if not current.has("cavity"):
		return false
	return soil_state.settle_cells(current["cavity"] as Transform3D, delta)


func _queue_backend_feedback() -> void:
	if not backend_feedback_enabled or _motion_client == null or soil_state == null:
		return
	var status := soil_state.get_status_snapshot()
	var interaction := soil_state.soil_contract.get("interaction", {}) as Dictionary
	var maximum_depth := float(interaction.get("maximum_cut_depth_m", 0.08))
	var penetration := float(_last_support.get("penetration_m", 0.0))
	_motion_client.queue_bucket_load_feedback(
		{
			"world_generation": int(status.get("world_generation", 0)),
			"authority_generation": authority_generation,
			"payload_mass_kg": float(status.get("payload_mass_kg", 0.0)),
			"center_of_mass_local": status.get("center_of_mass_local", Vector3.ZERO),
			"fill_ratio": clampf(float(status.get("fill_ratio", 0.0)), 0.0, 1.5),
			"resistance": clampf(penetration / maxf(maximum_depth, 0.001), 0.0, 1.0),
			"quality": feedback_quality,
		}
	)


func _settled_deposit_center(opening_world: Vector3) -> Variant:
	var center_xz := Vector2(opening_world.x, opening_world.z)
	if not terrain_world.terrain_state.is_inside_grid(center_xz):
		return null
	var surface := terrain_world.terrain_state.sample_surface_bilinear_at(center_xz)
	if is_nan(surface):
		return null
	return Vector3(opening_world.x, maxf(opening_world.y, surface + BucketSoilState.DUMP_CLEARANCE_M), opening_world.z)


func _on_pose_cleared(generation: int, _reason: String) -> void:
	authority_generation = maxi(authority_generation, generation)
	_clear_local_material("pose_cleared")


func _on_authority_changed(_session_id: String, _simulation_epoch: String, generation: int) -> void:
	_on_pose_cleared(generation, "authority_generation")


func _on_model_activated(_model_id: String, _asset_root: Node3D) -> void:
	var contract := _presentation.get_soil_contract()
	_sync_local_tooth_offset(contract)
	if soil_state != null:
		soil_state.configure_contract(contract)
	if _parcel_pool != null:
		_parcel_pool.configure_barrier_extents(_cavity_extents_from_contract(contract))
	_clear_local_material("model_activated")


func _sync_local_tooth_offset(contract: Dictionary) -> void:
	var cutting: Dictionary = (contract.get("proxies", {}) as Dictionary).get("cutting_edge", {})
	var raw_center: Variant = cutting.get("center_godot", [])
	if raw_center is Array and (raw_center as Array).size() == 3:
		local_tooth_offset = Vector3(float(raw_center[0]), float(raw_center[1]), float(raw_center[2]))


func _on_world_reset(generation: int) -> void:
	if terrain_scheduler != null:
		terrain_scheduler.reset_for_generation(generation)
	if soil_state != null:
		soil_state.reset_for_generation(generation)
	if _parcel_pool != null:
		_parcel_pool.clear_all()
	_next_command_sequence = 0
	_last_pose_snapshot.clear()
	_last_interaction = "reset"
	_last_support = {"active": false, "penetration_m": 0.0}
	_last_raw_support_point = Vector3.ZERO
	_has_raw_support_point = false
	_last_interaction_batch.clear()
	_consumed_batch_keys.clear()
	_consumed_batch_order.clear()
	if _tracked_chassis_controller != null:
		_tracked_chassis_controller.clear_bucket_support_contact()
	_last_flow_volume_m3 = 0.0
	if _motion_client != null:
		_motion_client.clear_bucket_load_feedback()
	_material_generation += 1
	if _presentation != null:
		_presentation.clear_bucket_pose_history()
	excavation_changed.emit(get_status_snapshot())


func _clear_local_material(reason: String) -> void:
	if terrain_world != null and terrain_world.terrain_state != null:
		if terrain_scheduler != null:
			terrain_scheduler.reset_for_generation(terrain_world.terrain_state.world_generation)
		if soil_state != null:
			soil_state.reset_for_generation(terrain_world.terrain_state.world_generation)
	if _parcel_pool != null:
		_parcel_pool.clear_all()
	_last_pose_snapshot.clear()
	_last_interaction = reason
	_last_support = {"active": false, "penetration_m": 0.0}
	_last_raw_support_point = Vector3.ZERO
	_has_raw_support_point = false
	_last_interaction_batch.clear()
	_consumed_batch_keys.clear()
	_consumed_batch_order.clear()
	if _tracked_chassis_controller != null:
		_tracked_chassis_controller.clear_bucket_support_contact()
	_last_flow_volume_m3 = 0.0
	if _motion_client != null:
		_motion_client.clear_bucket_load_feedback()
	_material_generation += 1
	if _presentation != null:
		_presentation.clear_bucket_pose_history()
	excavation_changed.emit(get_status_snapshot())
