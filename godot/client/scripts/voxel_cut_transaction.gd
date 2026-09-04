class_name VoxelCutTransaction
extends RefCounted

const SCHEMA_VERSION := "voxel-soil-transaction-v2"

var generation := -1
var revision := -1
var sequence := -1
var fixed_tick_begin := -1
var fixed_tick_end := -1
var model_id := ""
var operation := "cut"
var transaction_id := ""
var area_voxels := AABB()
var input_hash := ""
var pre_sdf_digest := ""
var post_sdf_digest := ""
var requested_mass_q := 0
var accepted_mass_q := 0
var represented_mass_q := 0
var mass_discretization_error_q := 0
var mass_discretization_tolerance_q := 0
var requested_volume_m3 := 0.0
var accepted_volume_m3 := 0.0
var affected_cells := 0
var affected_samples := 0
var capacity_clipped := false
var accounting_mode := "exact_sdf_volume"
var native_path_count := 0
var overburden_path_count := 0
var coverage_candidate_count := 0
var coverage_new_count := 0
var coverage_usec := 0
var support_query_usec := 0
var batch_wait_usec := 0
var material_usec := 0
var native_edit_usec := 0
var digest_usec := 0
var readiness_issue_usec := 0
var release_world := Vector3.ZERO
var deposit_world := Vector3.ZERO
var release_fill_ratio := 0.0
var rejection_reason := ""
var commit_usec := 0


func accepted() -> bool:
	return rejection_reason.is_empty() and accepted_mass_q > 0 and revision >= 0


func to_dictionary() -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION,
		"generation": generation,
		"revision": revision,
		"sequence": sequence,
		"fixed_tick_begin": fixed_tick_begin,
		"fixed_tick_end": fixed_tick_end,
		"model_id": model_id,
		"operation": operation,
		"transaction_id": transaction_id,
		"area_voxels": area_voxels,
		"input_hash": input_hash,
		"pre_sdf_digest": pre_sdf_digest,
		"post_sdf_digest": post_sdf_digest,
		"requested_mass_q": requested_mass_q,
		"accepted_mass_q": accepted_mass_q,
		"represented_mass_q": represented_mass_q,
		"mass_discretization_error_q": mass_discretization_error_q,
		"mass_discretization_tolerance_q": mass_discretization_tolerance_q,
		"requested_volume_m3": requested_volume_m3,
		"accepted_volume_m3": accepted_volume_m3,
		"affected_cells": affected_cells,
		"affected_samples": affected_samples,
		"capacity_clipped": capacity_clipped,
		"accounting_mode": accounting_mode,
		"native_path_count": native_path_count,
		"overburden_path_count": overburden_path_count,
		"coverage_candidate_count": coverage_candidate_count,
		"coverage_new_count": coverage_new_count,
		"coverage_usec": coverage_usec,
		"support_query_usec": support_query_usec,
		"batch_wait_usec": batch_wait_usec,
		"material_usec": material_usec,
		"native_edit_usec": native_edit_usec,
		"digest_usec": digest_usec,
		"readiness_issue_usec": readiness_issue_usec,
		"release_world": release_world,
		"deposit_world": deposit_world,
		"release_fill_ratio": release_fill_ratio,
		"rejection_reason": rejection_reason,
		"commit_usec": commit_usec,
	}
