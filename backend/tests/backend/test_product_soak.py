from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from babylon_sim.product_soak import (
    GODOT_REPORT_SCHEMA_VERSION,
    SoakBudgets,
    evaluate_gateway_report,
    evaluate_godot_report,
    paired_bucket_ground_coverage_complete,
    summarize_paired_bucket_ground_reports,
)


def test_soak_cli_rejects_an_unknown_quality_profile() -> None:
    script = Path(__file__).parents[2] / "scripts/jolt_product_soak.py"
    result = subprocess.run(
        [sys.executable, str(script), "--quality-profile", "ultra"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 2
    assert "invalid choice" in result.stderr


def test_godot_report_requires_performance_and_complete_scenario() -> None:
    report = {
        "schema_version": GODOT_REPORT_SCHEMA_VERSION,
        "model_id": "sy205",
        "requested_quality_profile": "balanced",
        "observed_quality_profile": "balanced",
        "requested_bucket_ground_mode": "normal",
        "observed_bucket_ground_mode": "normal",
        "quality": {"profile": "balanced", "applied": True, "last_error": ""},
        "metrics": {
            "fixed_step_p95_ms": 3.0,
            "fixed_step_peak_ms": 9.0,
            "render_frame_p95_ms": 16.0,
            "render_frame_p99_ms": 30.0,
        },
        "contract": {"clean": True, "maximum_runtime_count": 1},
        "scenario": {
            "track_motion_observed": True,
            "articulation_observed": True,
            "cut_frames": 1,
            "maximum_payload_mass_kg": 20.0,
            "dump_frames": 1,
            "support_frames": 1,
            "reset_completed": True,
            "reconnect_completed": True,
        },
    }
    gates = evaluate_godot_report(report, SoakBudgets(), "sy205", "balanced")
    assert all(gates.values())
    report["scenario"]["cut_frames"] = 0
    assert not evaluate_godot_report(report, SoakBudgets(), "sy205", "balanced")[
        "scenario_cut"
    ]


def test_godot_report_rejects_missing_unknown_and_mismatched_quality_profiles() -> None:
    report = {
        "schema_version": GODOT_REPORT_SCHEMA_VERSION,
        "model_id": "sy135",
        "requested_quality_profile": "high",
        "observed_quality_profile": "high",
        "requested_bucket_ground_mode": "normal",
        "observed_bucket_ground_mode": "normal",
        "quality": {"profile": "high", "applied": True, "last_error": ""},
    }
    gates = evaluate_godot_report(report, SoakBudgets(), "sy135", "high")
    assert gates["quality_profile_requested"]
    assert gates["quality_profile_observed"]
    assert gates["quality_profile_known"]
    assert gates["quality_profile_applied"]

    missing = dict(report)
    missing.pop("requested_quality_profile")
    assert not evaluate_godot_report(missing, SoakBudgets(), "sy135", "high")[
        "quality_profile_requested"
    ]

    unknown = dict(report, observed_quality_profile="ultra")
    assert not evaluate_godot_report(unknown, SoakBudgets(), "sy135", "high")[
        "quality_profile_known"
    ]

    mismatch = dict(report, observed_quality_profile="low")
    assert not evaluate_godot_report(mismatch, SoakBudgets(), "sy135", "high")[
        "quality_profile_observed"
    ]


def test_gateway_report_requires_bounded_lossless_telemetry_and_memory() -> None:
    report = {
        "health_samples": 10,
        "model_id": "sy135",
        "telemetry": {
            "accepted_batches": 20,
            "dropped_batches": 0,
            "maximum_history_count": 20,
        },
        "memory": {
            "baseline_bytes": 1_000_000_000,
            "growth_bytes": 90_000_000,
        },
    }
    gates = evaluate_gateway_report(report, SoakBudgets(), "sy135")
    assert all(gates.values())
    report["memory"]["growth_bytes"] = 140_000_000
    failed = evaluate_gateway_report(report, SoakBudgets(), "sy135")
    assert not failed["memory_growth_ratio"]
    assert not failed["memory_growth_absolute"]


def test_pass_through_report_requires_inverse_soil_and_query_gates() -> None:
    report = {
        "schema_version": GODOT_REPORT_SCHEMA_VERSION,
        "model_id": "sy205",
        "requested_quality_profile": "balanced",
        "observed_quality_profile": "balanced",
        "requested_bucket_ground_mode": "bucket_passthrough",
        "observed_bucket_ground_mode": "bucket_passthrough",
        "quality": {"profile": "balanced", "applied": True, "last_error": ""},
        "metrics": {
            "fixed_step_p95_ms": 3.0,
            "fixed_step_peak_ms": 9.0,
            "render_frame_p95_ms": 16.0,
            "render_frame_p99_ms": 30.0,
        },
        "contract": {"clean": True, "maximum_runtime_count": 1},
        "scenario": {
            "track_motion_observed": True,
            "articulation_observed": True,
            "cut_frames": 0,
            "maximum_payload_mass_kg": 0.0,
            "dump_frames": 0,
            "support_frames": 0,
            "reset_completed": True,
            "reconnect_completed": True,
        },
        "bucket_ground": {
            "transition_terrain_unchanged": True,
            "work_delta": {
                "query_executed": 0,
                "query_bypassed": 10,
                "soil_steps_executed": 0,
                "soil_steps_bypassed": 10,
                "terrain_commits_executed": 0,
                "effects_update_executed": 0,
                "effects_update_bypassed": 10,
            },
        },
    }
    gates = evaluate_godot_report(
        report, SoakBudgets(), "sy205", "balanced", "bucket_passthrough"
    )
    assert all(gates.values())
    report["bucket_ground"]["work_delta"]["query_executed"] = 1
    assert not evaluate_godot_report(
        report, SoakBudgets(), "sy205", "balanced", "bucket_passthrough"
    )["passthrough_query_execution_zero"]


def test_paired_bucket_ground_summary_uses_mode_medians_and_preserves_work() -> None:
    reports = []
    for repetition, normal, passthrough in [(1, 3.4, 2.1), (2, 3.0, 2.2), (3, 3.2, 2.0)]:
        for mode, p95, executed in [
            ("normal", normal, 20),
            ("bucket_passthrough", passthrough, 0),
        ]:
            reports.append(
                {
                    "model_id": "sy205",
                    "quality_profile": "balanced",
                    "bucket_ground_mode": mode,
                    "repetition": repetition,
                    "godot": {
                        "metrics": {"fixed_step_p95_ms": p95},
                        "bucket_ground": {"work_delta": {"query_executed": executed}},
                    },
                }
            )
    summary = summarize_paired_bucket_ground_reports(reports)
    assert len(summary) == 1
    assert summary[0]["normal_median_fixed_step_p95_ms"] == 3.2
    assert summary[0]["pass_through_median_fixed_step_p95_ms"] == 2.1
    assert summary[0]["pass_through_lower_median_p95"]
    assert summary[0]["work_deltas"]["bucket_passthrough"][0]["query_executed"] == 0
    assert paired_bucket_ground_coverage_complete(summary, ["sy205"], ["balanced"])


def test_paired_bucket_ground_coverage_rejects_missing_normal_baseline() -> None:
    reports = [
        {
            "model_id": "sy205",
            "quality_profile": "balanced",
            "bucket_ground_mode": "bucket_passthrough",
            "godot": {"metrics": {"fixed_step_p95_ms": 2.0}},
        }
    ]
    comparisons = summarize_paired_bucket_ground_reports(reports)
    assert comparisons == []
    assert not paired_bucket_ground_coverage_complete(
        comparisons, ["sy205"], ["balanced"]
    )
