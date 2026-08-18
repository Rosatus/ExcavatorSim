"""Shared budgets and report evaluation for the Jolt product soak."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any


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


def evaluate_godot_report(report: Mapping[str, Any], budgets: SoakBudgets) -> dict[str, bool]:
    metrics = _mapping(report.get("metrics"))
    scenario = _mapping(report.get("scenario"))
    contract = _mapping(report.get("contract"))
    return {
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


def _mapping(value: object) -> Mapping[str, Any]:
    return value if isinstance(value, Mapping) else {}


def _number(value: object) -> float:
    if isinstance(value, (int, float)):
        return float(value)
    return float("inf")
