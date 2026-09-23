class_name RaceModeProfile
extends RefCounted
## Loads race-mode overlays for the locomotion solvers. An overlay is pure
## data: "params" and "body" are {"set","scale"} maps applied only to keys
## already present in the base dictionary (schema-validated solvers never see
## unknown fields); "assist" holds race-only gains consumed by RaceMotionAssist.
const PATH := "res://resources/physics/race_mode_profiles.json"
const SECTION_KEYS := ["params", "body", "assist"]

## Merged overlay for one model and locomotion kind ("tracked"/"wheeled"):
## defaults.<kind> deep-merged with models.<model_id>.<kind>. Empty when the
## registry is missing or malformed — callers treat that as "no change".
static func overlay_for(model_id: String, kind: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if not parsed is Dictionary or parsed.get("schema_version") != 1:
		return {}
	var result := _merge_sections({}, _as_dict((parsed.get("defaults", {}) as Dictionary).get(kind, {})))
	var models := _as_dict(parsed.get("models", {}))
	var model_entry := _as_dict(models.get(model_id, {}))
	if model_entry.has(kind):
		result = _merge_sections(result, _as_dict(model_entry[kind]))
	return result

## Apply a {"set","scale"} overlay onto a base parameter dictionary. Only keys
## already present in base are written and only finite numeric values apply.
static func apply_overlay(base: Dictionary, overlay: Dictionary) -> Dictionary:
	var result := base.duplicate(true)
	for section in ["set", "scale"]:
		for key in _as_dict(overlay.get(section, {})):
			var value: Variant = overlay[section][key]
			if not base.has(key) or not _finite(value):
				continue
			result[key] = float(value) if section == "set" else float(base[key]) * float(value)
	return result

static func _merge_sections(into: Dictionary, overlay: Dictionary) -> Dictionary:
	var result := into.duplicate(true)
	for section in SECTION_KEYS:
		var incoming := _as_dict(overlay.get(section, {}))
		if incoming.is_empty():
			continue
		var merged := _as_dict(result.get(section, {}))
		for key in incoming:
			var value: Variant = incoming[key]
			# params/body hold nested {"set","scale"} maps; assist is flat.
			if value is Dictionary and _as_dict(merged.get(key, {})).keys() != []:
				var inner := _as_dict(merged.get(key, {}))
				for inner_key in value:
					inner[inner_key] = value[inner_key]
				merged[key] = inner
			elif value is Dictionary:
				merged[key] = value.duplicate(true)
			else:
				merged[key] = value
		result[section] = merged
	return result

static func _as_dict(value: Variant) -> Dictionary:
	return value if value is Dictionary else {}

static func _finite(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))
