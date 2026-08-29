"""Run the rendered Jolt product path against a gateway-only backend."""

from __future__ import annotations

import argparse
import ctypes
import json
import os
import platform
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from contextlib import ExitStack
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from babylon_sim.product_soak import (
    BUCKET_GROUND_MODES,
    QUALITY_PROFILES,
    SOAK_REPORT_SCHEMA_VERSION,
    SoakBudgets,
    evaluate_gateway_report,
    evaluate_godot_report,
    paired_bucket_ground_coverage_complete,
    summarize_paired_bucket_ground_reports,
)

ROOT = Path(__file__).resolve().parents[2]
CLIENT_DIR = ROOT / "godot/client"
DEFAULT_OUTPUT = ROOT / "artifacts/benchmark/jolt-product-soak.json"
KNOWN_GODOT_EXECUTABLES = (
    Path(r"E:\applications\Godot_v4.7.1-stable_mono_win64") / "Godot_v4.7.1-stable_mono_win64.exe",
    Path(r"E:\applications\Godot_v4.7.1-stable_mono_win64")
    / "Godot_v4.7.1-stable_mono_win64_console.exe",
)
STARTUP_TIMEOUT_SECONDS = 120.0
GODOT_STARTUP_TIMEOUT_SECONDS = 240.0
PROCESS_QUERY_INFORMATION = 0x0400
PROCESS_VM_READ = 0x0010


class _ProcessMemoryCounters(ctypes.Structure):
    _fields_ = [
        ("cb", ctypes.c_ulong),
        ("page_fault_count", ctypes.c_ulong),
        ("peak_working_set_size", ctypes.c_size_t),
        ("working_set_size", ctypes.c_size_t),
        ("quota_peak_paged_pool_usage", ctypes.c_size_t),
        ("quota_paged_pool_usage", ctypes.c_size_t),
        ("quota_peak_non_paged_pool_usage", ctypes.c_size_t),
        ("quota_non_paged_pool_usage", ctypes.c_size_t),
        ("pagefile_usage", ctypes.c_size_t),
        ("peak_pagefile_usage", ctypes.c_size_t),
    ]


def main() -> int:
    args = _build_parser().parse_args()
    duration_seconds = args.duration_seconds
    warmup_seconds = args.warmup_seconds
    if duration_seconds is None:
        duration_seconds = 90.0 if args.mode == "quick" else 900.0
    if warmup_seconds is None:
        warmup_seconds = 15.0 if args.mode == "quick" else 30.0
    if duration_seconds <= 0.0 or warmup_seconds < 0.0 or warmup_seconds >= duration_seconds:
        raise SystemExit("duration must be positive and warmup must be within the run")
    godot_exe = _find_godot(args.godot_exe)
    output = args.output if args.output.is_absolute() else ROOT / args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    budgets = SoakBudgets()
    model_reports: list[dict[str, Any]] = []
    execution_order: list[dict[str, Any]] = []
    run_ordinal = 0
    for model_id in args.models:
        for quality_profile in args.quality_profiles:
            for repetition in range(1, args.repetitions + 1):
                ordered_modes = list(args.bucket_ground_modes)
                if repetition % 2 == 0:
                    ordered_modes.reverse()
                for bucket_ground_mode in ordered_modes:
                    run_ordinal += 1
                    execution_order.append(
                        {
                            "run_ordinal": run_ordinal,
                            "model_id": model_id,
                            "quality_profile": quality_profile,
                            "repetition": repetition,
                            "bucket_ground_mode": bucket_ground_mode,
                            "trace_identity": "bucket-ground-cycle-v1",
                        }
                    )
                    model_reports.append(
                        _run_model_with_retry(
                            model_id=model_id,
                            quality_profile=quality_profile,
                            bucket_ground_mode=bucket_ground_mode,
                            repetition=repetition,
                            run_ordinal=run_ordinal,
                            trace_identity="bucket-ground-cycle-v1",
                            godot_exe=godot_exe,
                            duration_seconds=duration_seconds,
                            warmup_seconds=warmup_seconds,
                            output_dir=output.parent,
                            budgets=budgets,
                            allow_incomplete_scenario=args.allow_incomplete_scenario,
                            headless=args.headless,
                        )
                    )
    comparisons = summarize_paired_bucket_ground_reports(model_reports)
    paired_comparison_required = "bucket_passthrough" in args.bucket_ground_modes
    paired_comparison_complete = not paired_comparison_required or (
        "normal" in args.bucket_ground_modes
        and paired_bucket_ground_coverage_complete(
            comparisons, args.models, args.quality_profiles
        )
    )
    report = {
        "schema_version": SOAK_REPORT_SCHEMA_VERSION,
        "captured_at_utc": datetime.now(UTC).isoformat(),
        "machine_id": platform.node(),
        "source_revision": _source_revision(),
        "mode": args.mode,
        "rendered": not args.headless,
        "quality_profiles": args.quality_profiles,
        "bucket_ground_modes": args.bucket_ground_modes,
        "repetitions": args.repetitions,
        "duration_seconds_per_cell": duration_seconds,
        "duration_seconds_per_model": (
            duration_seconds
            * len(args.quality_profiles)
            * len(args.bucket_ground_modes)
            * args.repetitions
        ),
        "warmup_seconds": warmup_seconds,
        "budgets": budgets.as_dict(),
        "models": model_reports,
        "execution_order": execution_order,
        "paired_comparisons": comparisons,
        "paired_comparison_required": paired_comparison_required,
        "paired_comparison_complete": paired_comparison_complete,
        "pass": all(bool(model.get("pass", False)) for model in model_reports)
        and paired_comparison_complete
        and all(
            bool(comparison.get("pass_through_lower_median_p95", False))
            for comparison in comparisons
        ),
    }
    output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    for model in model_reports:
        failed = [name for name, passed in model["gates"].items() if not passed]
        status = "PASS" if model["pass"] else "FAIL"
        identity = (
            f"{model['model_id']}/{model['quality_profile']}/"
            f"{model['bucket_ground_mode']}#{model['repetition']}"
        )
        print(f"{identity}: {status}" + (f" ({', '.join(failed)})" if failed else ""))
    print(f"Jolt product soak report: {output}")
    return 0 if report["pass"] else 1


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    parser.add_argument("--mode", choices=("quick", "release"), default="quick")
    parser.add_argument(
        "--models", nargs="+", choices=("sy205", "sy135"), default=["sy205", "sy135"]
    )
    parser.add_argument(
        "--quality-profile",
        dest="quality_profiles",
        nargs="+",
        choices=QUALITY_PROFILES,
        default=["balanced"],
    )
    parser.add_argument("--duration-seconds", type=float)
    parser.add_argument("--warmup-seconds", type=float)
    parser.add_argument("--godot-exe", type=Path)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--allow-incomplete-scenario", action="store_true")
    parser.add_argument(
        "--bucket-ground-mode",
        dest="bucket_ground_modes",
        nargs="+",
        choices=BUCKET_GROUND_MODES,
        default=["normal"],
    )
    parser.add_argument("--repetitions", type=int, choices=range(1, 10), default=1)
    parser.add_argument("--headless", action="store_true")
    return parser


def _source_revision() -> dict[str, Any]:
    completed = subprocess.run(
        ["git", "status", "--porcelain=v1"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    head = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    return {
        "git_head": head.stdout.strip() if head.returncode == 0 else "unavailable",
        "working_tree_dirty": bool(completed.stdout.strip()) if completed.returncode == 0 else None,
    }


def _find_godot(explicit: Path | None) -> Path:
    candidates: list[Path] = []
    if explicit is not None:
        candidates.append(explicit)
    configured = os.environ.get("GODOT_EXE")
    if configured:
        candidates.append(Path(configured))
    discovered = shutil.which("godot")
    if discovered:
        candidates.append(Path(discovered))
    candidates.extend(KNOWN_GODOT_EXECUTABLES)
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    raise SystemExit("Godot executable unavailable; pass --godot-exe or set GODOT_EXE")


def _run_model_with_retry(**kwargs: Any) -> dict[str, Any]:
    try:
        return _run_model(**kwargs)
    except RuntimeError as exc:
        if "gateway health endpoint did not become ready" not in str(exc):
            raise
        print(f"gateway startup retry for {kwargs['model_id']}: {exc}", file=sys.stderr)
        return _run_model(**kwargs)


def _run_model(
    *,
    model_id: str,
    quality_profile: str,
    bucket_ground_mode: str,
    repetition: int,
    run_ordinal: int,
    trace_identity: str,
    godot_exe: Path,
    duration_seconds: float,
    warmup_seconds: float,
    output_dir: Path,
    budgets: SoakBudgets,
    allow_incomplete_scenario: bool,
    headless: bool,
) -> dict[str, Any]:
    port = _reserve_port()
    health_url = f"http://127.0.0.1:{port}/health"
    endpoint = f"ws://127.0.0.1:{port}/ws"
    cell_id = f"{model_id}-{quality_profile}-{bucket_ground_mode}-r{repetition}"
    godot_report_path = output_dir / f"jolt-product-soak-{cell_id}-godot.json"
    backend_log_path = output_dir / f"jolt-product-soak-{cell_id}-backend.log"
    godot_log_path = output_dir / f"jolt-product-soak-{cell_id}-godot.log"
    backend_command = [
        sys.executable,
        "-u",
        "-m",
        "babylon_sim.cli",
        "--runtime-profile",
        "gateway-only",
        "--model",
        model_id,
        "--host",
        "127.0.0.1",
        "--port",
        str(port),
        "--frontend-dir",
        str(ROOT / "godot/dist"),
        "--no-browser",
    ]
    godot_command = [str(godot_exe)]
    if headless:
        godot_command.append("--headless")
    godot_command.extend(
        [
            "--path",
            str(CLIENT_DIR),
            "--script",
            str(ROOT / "backend/scripts/godot/jolt_product_soak.gd"),
            "--",
            "--model",
            model_id,
            "--quality-profile",
            quality_profile,
            "--bucket-ground-mode",
            bucket_ground_mode,
            "--duration-seconds",
            str(duration_seconds),
            "--warmup-seconds",
            str(warmup_seconds),
            "--endpoint",
            endpoint,
            "--report",
            str(godot_report_path),
        ]
    )
    if allow_incomplete_scenario:
        godot_command.append("--allow-incomplete-scenario")
    samples: list[tuple[float, int]] = []
    health_samples = 0
    telemetry = {"accepted_batches": 0, "dropped_batches": 0, "maximum_history_count": 0}
    observed_model_id = ""
    started = time.monotonic()
    with ExitStack() as stack:
        backend_log = stack.enter_context(backend_log_path.open("w", encoding="utf-8"))
        godot_log = stack.enter_context(godot_log_path.open("w", encoding="utf-8"))
        backend = subprocess.Popen(
            backend_command,
            cwd=ROOT,
            stdout=backend_log,
            stderr=subprocess.STDOUT,
            text=True,
        )
        try:
            _wait_for_health(health_url, backend)
            godot = subprocess.Popen(
                godot_command,
                cwd=ROOT,
                stdout=godot_log,
                stderr=subprocess.STDOUT,
                text=True,
            )
            try:
                deadline = time.monotonic() + duration_seconds + GODOT_STARTUP_TIMEOUT_SECONDS
                while godot.poll() is None and time.monotonic() < deadline:
                    elapsed = time.monotonic() - started
                    samples.append((elapsed, _working_set(backend.pid) + _working_set(godot.pid)))
                    health = _read_json(health_url)
                    if health is not None:
                        health_samples += 1
                        observed_model_id = str(health.get("model_id", observed_model_id))
                        current = health.get("sensor_telemetry")
                        if isinstance(current, dict):
                            telemetry["accepted_batches"] = max(
                                telemetry["accepted_batches"],
                                int(current.get("accepted_batches", 0)),
                            )
                            telemetry["dropped_batches"] = max(
                                telemetry["dropped_batches"], int(current.get("dropped_batches", 0))
                            )
                            telemetry["maximum_history_count"] = max(
                                telemetry["maximum_history_count"],
                                int(current.get("history_count", 0)),
                            )
                    time.sleep(0.5)
                if godot.poll() is None:
                    _terminate(godot)
                    raise RuntimeError(f"Godot soak timed out for {model_id}")
                godot_exit_code = int(godot.returncode)
            finally:
                if godot.poll() is None:
                    _terminate(godot)
        finally:
            _terminate(backend)
    godot_report = _load_report(godot_report_path)
    memory = _memory_summary(samples, warmup_seconds)
    gateway_report: dict[str, Any] = {
        "health_samples": health_samples,
        "model_id": observed_model_id,
        "telemetry": telemetry,
        "memory": memory,
    }
    gates = evaluate_godot_report(
        godot_report, budgets, model_id, quality_profile, bucket_ground_mode
    )
    gates.update(evaluate_gateway_report(gateway_report, budgets, model_id))
    gates["godot_process_exit"] = godot_exit_code == 0
    gates["rendered_product_path"] = not headless
    if allow_incomplete_scenario:
        for name in tuple(gates):
            if name.startswith("scenario_"):
                gates[name] = True
    return {
        "model_id": model_id,
        "quality_profile": quality_profile,
        "bucket_ground_mode": bucket_ground_mode,
        "repetition": repetition,
        "run_ordinal": run_ordinal,
        "trace_identity": trace_identity,
        "godot_exit_code": godot_exit_code,
        "godot": godot_report,
        "gateway": gateway_report,
        "gates": gates,
        "pass": all(gates.values()),
        "logs": {"backend": str(backend_log_path), "godot": str(godot_log_path)},
    }


def _reserve_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def _wait_for_health(url: str, process: subprocess.Popen[str]) -> None:
    deadline = time.monotonic() + STARTUP_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("gateway exited before becoming healthy")
        if _read_json(url) is not None:
            return
        time.sleep(0.1)
    raise RuntimeError("gateway health endpoint did not become ready")


def _read_json(url: str) -> dict[str, Any] | None:
    try:
        with urllib.request.urlopen(url, timeout=0.4) as response:
            value = json.loads(response.read().decode("utf-8"))
            return value if isinstance(value, dict) else None
    except (OSError, ValueError, urllib.error.URLError):
        return None


def _working_set(pid: int) -> int:
    if os.name != "nt":
        return 0
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    psapi = ctypes.WinDLL("psapi", use_last_error=True)
    handle = kernel32.OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, False, pid)
    if not handle:
        return 0
    counters = _ProcessMemoryCounters()
    counters.cb = ctypes.sizeof(counters)
    try:
        if not psapi.GetProcessMemoryInfo(handle, ctypes.byref(counters), counters.cb):
            return 0
        return int(counters.working_set_size)
    finally:
        kernel32.CloseHandle(handle)


def _memory_summary(
    samples: list[tuple[float, int]], warmup_seconds: float
) -> dict[str, int | float]:
    measured = [value for elapsed, value in samples if elapsed >= warmup_seconds and value > 0]
    if not measured:
        measured = [value for _, value in samples if value > 0]
    baseline = measured[0] if measured else 0
    peak = max(measured, default=0)
    growth = max(0, peak - baseline)
    return {
        "baseline_bytes": baseline,
        "peak_bytes": peak,
        "growth_bytes": growth,
        "growth_ratio": float(growth) / float(baseline) if baseline > 0 else 0.0,
        "sample_count": len(measured),
    }


def _load_report(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    value = json.loads(path.read_text(encoding="utf-8"))
    return value if isinstance(value, dict) else {}


def _terminate(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    if os.name == "nt":
        subprocess.run(
            ["taskkill", "/PID", str(process.pid), "/T", "/F"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    else:
        process.terminate()
    try:
        process.wait(timeout=10.0)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=10.0)


if __name__ == "__main__":
    raise SystemExit(main())
