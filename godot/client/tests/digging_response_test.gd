extends SceneTree

const TICK := 1.0 / 60.0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	for model_id in ["sy205", "sy135"]:
		var first := _record_curves(model_id)
		var second := _record_curves(model_id)
		if first != second:
			return _fail("%s fixed-step response was not deterministic" % model_id)
		var phases := first["phases"] as Dictionary
		for required_phase in ["free", "contact", "scrape", "cut", "load", "overflow", "dump", "blocked", "escape"]:
			if not phases.has(required_phase):
				return _fail("%s did not record %s" % [model_id, required_phase])
		if float(phases["cut"]["bucket_scale"]) >= float(phases["contact"]["bucket_scale"]):
			return _fail("%s productive cut did not slow more than contact" % model_id)
		if float(phases["load"]["bucket_scale"]) >= float(phases["cut"]["bucket_scale"]):
			return _fail("%s near-full load did not deepen the response" % model_id)
		if float(phases["overflow"]["bucket_scale"]) > float(phases["load"]["bucket_scale"]):
			return _fail("%s overflow response was weaker than load" % model_id)
		if float(phases["dump"]["bucket_scale"]) < 0.98 or float(phases["escape"]["bucket_scale"]) < 0.98:
			return _fail("%s dump/escape did not recover full command authority" % model_id)
		if float(first["minimum_scale"]) <= 0.0 or float(first["minimum_scale"]) < float(first["safe_minimum"]) - 0.0001:
			return _fail("%s violated its nonzero speed clamp" % model_id)
		if float(first["maximum_one_tick_delta"]) > 0.16:
			return _fail("%s response contained a one-tick scale spike" % model_id)

	var shaper := DiggingResponseShaper.new()
	shaper.configure("sy205")
	var soil := _status("cut", 0.02, 0.4, 0.0, "compact", true)
	var before := soil.duplicate(true)
	shaper.set_enabled(false)
	var disabled := shaper.step_fixed(TICK, Vector4(0.0, -1.0, -1.0, -1.0), soil)
	if disabled["scaled_commands"] != disabled["raw_commands"] or soil != before:
		return _fail("disabled response changed commands or soil state")
	shaper.set_enabled(true)
	shaper.reset_response("rearm")
	var reset := shaper.get_status_snapshot()
	if reset.get("phase") != "free" or reset.get("speed_scales") != Vector4.ONE:
		return _fail("reset did not restore free response")

	print("digging_response_test: PASS")
	quit(0)


func _record_curves(model_id: String) -> Dictionary:
	var shaper := DiggingResponseShaper.new()
	if not shaper.configure(model_id):
		return {}
	var digging := Vector4(0.0, -1.0, -1.0, -1.0)
	var phases := {}
	var minimum_scale := 1.0
	var maximum_delta := 0.0
	var previous_scale := 1.0
	var scenarios := [
		{"name": "free", "status": _status("free", 0.0, 0.0, 0.0, "loose", false), "ticks": 30, "commands": digging},
		{"name": "contact", "status": _status("contact", 0.0, 0.0, 0.0, "loose", true), "ticks": 6, "commands": digging},
		{"name": "scrape", "status": _status("scrape", 0.003, 0.25, 0.0, "loose", true), "ticks": 24, "commands": digging},
		{"name": "cut", "status": _status("cut", 0.006, 0.45, 0.0, "compact", true), "ticks": 30, "commands": digging},
		{"name": "load", "status": _status("cut", 0.006, 0.86, 0.0, "compact", true), "ticks": 30, "commands": digging},
		{"name": "overflow", "status": _status("cut", 0.004, 1.0, 0.04, "damp", true), "ticks": 30, "commands": digging},
		{"name": "dump", "status": _status("dump", 0.004, 0.7, 0.0, "damp", false), "ticks": 30, "commands": Vector4(0.0, 0.0, 0.0, 1.0)},
		{"name": "blocked", "status": _status("contact", 0.0, 0.2, 0.0, "compact", true), "ticks": 35, "commands": digging},
		{"name": "escape", "status": _status("contact", 0.0, 0.2, 0.0, "compact", true), "ticks": 30, "commands": Vector4(0.0, 1.0, 1.0, 1.0)},
	]
	for scenario_value in scenarios:
		var scenario := scenario_value as Dictionary
		var snapshot := {}
		for _tick_index in int(scenario["ticks"]):
			snapshot = shaper.step_fixed(TICK, scenario["commands"] as Vector4, scenario["status"] as Dictionary)
			var scale := (snapshot["speed_scales"] as Vector4).w
			minimum_scale = minf(minimum_scale, scale)
			maximum_delta = maxf(maximum_delta, absf(scale - previous_scale))
			previous_scale = scale
		phases[String(scenario["name"])] = {
			"phase": String(snapshot.get("phase", "missing")),
			"intensity": snappedf(float(snapshot.get("intensity", 0.0)), 0.000001),
			"bucket_scale": snappedf((snapshot["speed_scales"] as Vector4).w, 0.000001),
		}
	return {
		"phases": phases,
		"minimum_scale": snappedf(minimum_scale, 0.000001),
		"maximum_one_tick_delta": snappedf(maximum_delta, 0.000001),
		"safe_minimum": 0.34 if model_id == "sy205" else 0.38,
	}


func _status(
	kind: String,
	flow: float,
	fill_ratio: float,
	overflow: float,
	material: String,
	contact: bool
) -> Dictionary:
	var action := kind
	if kind == "contact":
		action = "none"
	var transaction := {}
	if kind not in ["free", "contact"]:
		transaction = {
			"kind": kind,
			"accepted_volume_m3": flow,
		}
	return {
		"flow_volume_m3": flow,
		"selected_soil_payload": {"fill_ratio": fill_ratio, "ledger_identity": "legacy:0:1"},
		"soil_lifecycle_shadow": {
			"configured": true,
			"ledger_identity": "sy205:0:12",
			"material_preset": material,
			"fill_ratio": fill_ratio,
			"overflow_volume_m3": overflow,
			"bucket_capacity_m3": 0.35,
			"last_transaction": transaction,
		},
		"soil_interaction_batch": {
			"operation": kind,
			"analytic_penetration_m": 0.06 if contact else 0.0,
			"soil_tool_shadow": {
				"candidates": [{
					"role_scope": "stable" if contact else "none",
					"classification": action,
					"overlap": contact,
					"penetration_m": 0.06 if contact else 0.0,
				}],
			},
		},
	}


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
