"""Shared budgets and report evaluation for the Jolt product soak."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from statistics import median
from typing import Any

SOAK_REPORT_SCHEMA_VERSION = "excavator-sim-jolt-product-soak-v2"
GODOT_REPORT_SCHEMA_VERSION = "excavator-sim-jolt-product-soak-godot-v2"
QUALITY_PROFILES = ("low", "balanced", "high")
BUCKET_GROUND_MODES = ("normal", "bucket_passthrough")


@dataclass(frozen=True)
class SoakBudgets:
    fixed_p95_ms: float = 4.0
    fixed_peak_ms: float = 10.0
    render_p95_ms: float = 16.7
    render_p99_ms: float = 33.3
    memory_growth_ratio: float = 0.10
    memory_growth_bytes: int = 128 * 1024 * 1024
    telemetry_drops: int = 0
    telemetry_capacity: int = 256

    def as_dict(self) -> dict[str, float | int]:
        return {
            "fixed_p95_ms": self.fixed_p95_ms,
            "fixed_peak_ms": self.fixed_peak_ms,
            "render_p95_ms": self.render_p95_ms,
            "render_p99_ms": self.render_p99_ms,
            "memory_growth_ratio": self.memory_growth_ratio,
            "memory_growth_bytes": self.memory_growth_bytes,
            "telemetry_drops": self.telemetry_drops,
            "telemetry_capacity": self.telemetry_capacity,
        }


def evaluate_godot_report(
    report: Mapping[str, Any],
    budgets: SoakBudgets,
    expected_model_id: str,
    expected_quality_profile: str,
    expected_bucket_ground_mode: str = "normal",
) -> dict[str, bool]:
    metrics = _mapping(report.get("metrics"))
    scenario = _mapping(report.get("scenario"))
    contract = _mapping(report.get("contract"))
    quality = _mapping(report.get("quality"))
    bucket_ground = _mapping(report.get("bucket_ground"))
    bucket_ground_work = _mapping(bucket_ground.get("work_delta"))
    requested_quality_profile = str(report.get("requested_quality_profile", ""))
    observed_quality_profile = str(report.get("observed_quality_profile", ""))
    gates = {
        "godot_report_schema": report.get("schema_version") == GODOT_REPORT_SCHEMA_VERSION,
        "godot_model_identity": str(report.get("model_id", "")) == expected_model_id,
        "quality_profile_expected": expected_quality_profile in QUALITY_PROFILES,
        "quality_profile_requested": requested_quality_profile == expected_quality_profile,
        "quality_profile_observed": observed_quality_profile == expected_quality_profile,
        "quality_profile_known": requested_quality_profile in QUALITY_PROFILES
        and observed_quality_profile in QUALITY_PROFILES,
        "quality_profile_applied": bool(quality.get("applied", False))
        and str(quality.get("last_error", "")) == ""
        and str(quality.get("profile", "")) == observed_quality_profile,
        "bucket_ground_mode_expected": expected_bucket_ground_mode in BUCKET_GROUND_MODES,
        "bucket_ground_mode_requested": str(report.get("requested_bucket_ground_mode", ""))
        == expected_bucket_ground_mode,
        "bucket_ground_mode_observed": str(report.get("observed_bucket_ground_mode", ""))
        == expected_bucket_ground_mode,
        "godot_contract_clean": bool(contract.get("clean", False)),
        "single_authoritative_runtime": int(contract.get("maximum_runtime_count", 0)) == 1,
        "fixed_step_p95": _number(metrics.get("fixed_step_p95_ms")) <= budgets.fixed_p95_ms,
        "fixed_step_peak": _number(metrics.get("fixed_step_peak_ms")) <= budgets.fixed_peak_ms,
        "render_frame_p95": _number(metrics.get("render_frame_p95_ms")) <= budgets.render_p95_ms,
        "render_frame_p99": _number(metrics.get("render_frame_p99_ms")) <= budgets.render_p99_ms,
        "scenario_track_motion": bool(scenario.get("track_motion_observed", False)),
        "scenario_articulation": bool(scenario.get("articulation_observed", False)),
        "scenario_cut": int(scenario.get("cut_frames", 0)) > 0,
        "scenario_loaded": _number(scenario.get("maximum_payload_mass_kg")) > 0.0,
        "scenario_dump": int(scenario.get("dump_frames", 0)) > 0,
        "scenario_support": int(scenario.get("support_frames", 0)) > 0,
        "reset_completed": bool(scenario.get("reset_completed", False)),
        "reconnect_completed": bool(scenario.get("reconnect_completed", False)),
    }
    if expected_bucket_ground_mode == "bucket_passthrough":
        gates.update(
            {
                "scenario_cut": int(scenario.get("cut_frames", -1)) == 0,
                "scenario_loaded": _number(scenario.get("maximum_payload_mass_kg")) == 0.0,
                "scenario_dump": int(scenario.get("dump_frames", -1)) == 0,
                "scenario_support": int(scenario.get("support_frames", -1)) == 0,
                "passthrough_transition_terrain_unchanged": bool(
                    bucket_ground.get("transition_terrain_unchanged", False)
                ),
                "passthrough_query_execution_zero": int(
                    bucket_ground_work.get("query_executed", -1)
                )
                == 0,
                "passthrough_query_bypass_observed": int(
                    bucket_ground_work.get("query_bypassed", 0)
                )
                > 0,
                "passthrough_soil_execution_zero": int(
                    bucket_ground_work.get("soil_steps_executed", -1)
                )
                == 0,
                "passthrough_soil_bypass_observed": int(
                    bucket_ground_work.get("soil_steps_bypassed", 0)
                )
                > 0,
                "passthrough_terrain_commit_zero": int(
                    bucket_ground_work.get("terrain_commits_executed", -1)
                )
                == 0,
                "passthrough_effects_execution_zero": int(
                    bucket_ground_work.get("effects_update_executed", -1)
                )
                == 0,
                "passthrough_effects_bypass_observed": int(
                    bucket_ground_work.get("effects_update_bypassed", 0)
                )
                > 0,
            }
        )
    return gates


def evaluate_gateway_report(
    report: Mapping[str, Any], budgets: SoakBudgets, expected_model_id: str
) -> dict[str, bool]:
    telemetry = _mapping(report.get("telemetry"))
    memory = _mapping(report.get("memory"))
    baseline = int(memory.get("baseline_bytes", 0))
    growth = int(memory.get("growth_bytes", 0))
    growth_ratio = float(growth) / float(baseline) if baseline > 0 else float("inf")
    return {
        "gateway_health_observed": int(report.get("health_samples", 0)) > 0,
        "gateway_model_identity": str(report.get("model_id", "")) == expected_model_id,
        "telemetry_observed": int(telemetry.get("accepted_batches", 0)) > 0,
        "telemetry_zero_drops": int(telemetry.get("dropped_batches", -1))
        == budgets.telemetry_drops,
        "telemetry_history_bounded": 0
        < int(telemetry.get("maximum_history_count", 0))
        <= budgets.telemetry_capacity,
        "memory_baseline_observed": baseline > 0,
        "memory_growth_ratio": growth_ratio <= budgets.memory_growth_ratio,
        "memory_growth_absolute": growth <= budgets.memory_growth_bytes,
    }


def summarize_paired_bucket_ground_reports(
    model_reports: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    grouped: dict[tuple[str, str], dict[str, list[float]]] = {}
    work_deltas: dict[tuple[str, str], dict[str, list[dict[str, Any]]]] = {}
    for report in model_reports:
        key = (str(report.get("model_id", "")), str(report.get("quality_profile", "")))
        mode = str(report.get("bucket_ground_mode", ""))
        godot = _mapping(report.get("godot"))
        metrics = _mapping(godot.get("metrics"))
        value = metrics.get("fixed_step_p95_ms")
        if not isinstance(value, (int, float)):
            continue
        grouped.setdefault(key, {}).setdefault(mode, []).append(float(value))
        bucket_ground = _mapping(godot.get("bucket_ground"))
        delta = _mapping(bucket_ground.get("work_delta"))
        work_deltas.setdefault(key, {}).setdefault(mode, []).append(dict(delta))
    comparisons: list[dict[str, Any]] = []
    for key, modes in sorted(grouped.items()):
        normal = modes.get("normal", [])
        passthrough = modes.get("bucket_passthrough", [])
        if not normal or not passthrough:
            continue
        normal_median = median(normal)
        passthrough_median = median(passthrough)
        comparisons.append(
            {
                "model_id": key[0],
                "quality_profile": key[1],
                "normal_fixed_step_p95_ms": normal,
                "pass_through_fixed_step_p95_ms": passthrough,
                "normal_median_fixed_step_p95_ms": normal_median,
                "pass_through_median_fixed_step_p95_ms": passthrough_median,
                "pass_through_lower_median_p95": passthrough_median < normal_median,
                "work_deltas": work_deltas.get(key, {}),
            }
        )
    return comparisons


def paired_bucket_ground_coverage_complete(
    comparisons: list[dict[str, Any]],
    expected_models: list[str],
    expected_quality_profiles: list[str],
) -> bool:
    expected = {
        (model_id, quality_profile)
        for model_id in expected_models
        for quality_profile in expected_quality_profiles
    }
    observed = {
        (str(comparison.get("model_id", "")), str(comparison.get("quality_profile", "")))
        for comparison in comparisons
    }
    return observed == expected


def _mapping(value: object) -> Mapping[str, Any]:
    return value if isinstance(value, Mapping) else {}


def _number(value: object) -> float:
    if isinstance(value, (int, float)):
        return float(value)
    return float("inf")
