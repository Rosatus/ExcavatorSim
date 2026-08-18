from __future__ import annotations

from babylon_sim.product_soak import SoakBudgets, evaluate_gateway_report, evaluate_godot_report


def test_godot_report_requires_performance_and_complete_scenario() -> None:
    report = {
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
    gates = evaluate_godot_report(report, SoakBudgets())
    assert all(gates.values())
    report["scenario"]["cut_frames"] = 0
    assert not evaluate_godot_report(report, SoakBudgets())["scenario_cut"]


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
