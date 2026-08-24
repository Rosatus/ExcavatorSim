class_name SoilAuthorityModeController
extends RefCounted

## Locks one material owner for the lifetime of a material generation. Requested
## changes are applied only by begin_generation(); runtime faults pause writes
## and schedule legacy for the next clean generation instead of mixing owners.

const SCHEMA_VERSION := "soil-authority-mode-controller-v1"
const MODES := ["legacy", "shadow", "active_patch"]
const STAGES := ["cut", "bucket_entry", "release", "settle"]
const PRODUCT_OWNER_BY_MODE := {
	"legacy": "legacy",
	"shadow": "legacy",
	"active_patch": "active_patch",
}

var requested_mode := "legacy"
var selected_mode := ""
var generation_key := ""
var locked := false
var writes_paused := false
var runtime_failure_reason := ""
var initialization_fallback_reason := ""
var selection_sequence := 0
var writer_configuration_valid := false
var owner_violation_count := 0


func set_requested_mode(value: String) -> bool:
	if value not in MODES:
		return false
	requested_mode = value
	return true


func begin_generation(key: String) -> bool:
	if key.is_empty() or requested_mode not in MODES:
		return false
	generation_key = key
	selected_mode = requested_mode
	locked = true
	writes_paused = false
	runtime_failure_reason = ""
	initialization_fallback_reason = ""
	selection_sequence += 1
	writer_configuration_valid = bind_product_writers(selected_mode != "active_patch", selected_mode == "active_patch")
	return has_single_product_owner() and writer_configuration_valid


func fallback_initialization_to_legacy(reason: String) -> bool:
	if not locked or reason.is_empty():
		return false
	selected_mode = "legacy"
	requested_mode = "legacy"
	initialization_fallback_reason = reason
	writes_paused = false
	writer_configuration_valid = bind_product_writers(true, false)
	return has_single_product_owner() and writer_configuration_valid


func report_runtime_failure(reason: String) -> bool:
	if not locked or selected_mode != "active_patch" or reason.is_empty():
		return false
	writes_paused = true
	runtime_failure_reason = reason
	requested_mode = "legacy"
	return true


func product_owner() -> String:
	return String(PRODUCT_OWNER_BY_MODE.get(selected_mode, ""))


func can_product_owner_write(owner: String) -> bool:
	return locked and writer_configuration_valid and not writes_paused and owner == product_owner()


func bind_product_writers(legacy_enabled: bool, active_patch_enabled: bool) -> bool:
	var enabled_count := (1 if legacy_enabled else 0) + (1 if active_patch_enabled else 0)
	var expected_owner := product_owner()
	var matches_selection := (
		enabled_count == 1
		and legacy_enabled == (expected_owner == "legacy")
		and active_patch_enabled == (expected_owner == "active_patch")
	)
	if not matches_selection:
		owner_violation_count += 1
	writer_configuration_valid = matches_selection
	return matches_selection


func has_single_product_owner() -> bool:
	var owner := product_owner()
	if owner.is_empty():
		return false
	for _stage in STAGES:
		var count := 1 if owner in ["legacy", "active_patch"] else 0
		if count != 1:
			return false
	return true


func get_status_snapshot() -> Dictionary:
	var owner := product_owner()
	var owners := {}
	for stage in STAGES:
		owners[stage] = owner
	return {
		"schema_version": SCHEMA_VERSION,
		"requested_mode": requested_mode,
		"selected_mode": selected_mode,
		"generation_key": generation_key,
		"locked": locked,
		"writes_paused": writes_paused,
		"runtime_failure_reason": runtime_failure_reason,
		"initialization_fallback_reason": initialization_fallback_reason,
		"selection_sequence": selection_sequence,
		"product_owner": owner,
		"stage_owners": owners,
		"single_owner_valid": has_single_product_owner() and writer_configuration_valid,
		"writer_configuration_valid": writer_configuration_valid,
		"owner_violation_count": owner_violation_count,
		"shadow_observer_enabled": selected_mode == "shadow",
		"legacy_parcel_material_callbacks_enabled": product_owner() == "legacy",
		"active_patch_presentation_replaces_hero_parcels": selected_mode == "active_patch",
	}
