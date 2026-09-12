"""Analyze a bounded Godot capture without starting Godot or changing its data."""

# Chinese report copy intentionally uses full-width punctuation.
# ruff: noqa: RUF001

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any

SCHEMA = "excavator-performance-capture-v1"
REQUIRED_COLUMNS = {
    "t_ms",
    "frame_interval_ms",
    "paused",
    "focused",
    "soil_total_ms",
    "soil_automatic_ms",
    "soil_step_ms",
    "soil_publish_ms",
    "commit_ms",
    "coverage_ms",
    "native_edit_ms",
    "render_cpu_ms",
    "render_gpu_ms",
    "recorder_ms",
}


def distribution(values: list[float]) -> dict[str, float | int]:
    values = sorted(value for value in values if value >= 0)
    if not values:
        return {"count": 0}

    def percentile(fraction: float) -> float:
        return values[max(0, math.ceil(len(values) * fraction) - 1)]

    return {
        "count": len(values),
        "mean": sum(values) / len(values),
        "p50": percentile(0.5),
        "p95": percentile(0.95),
        "p99": percentile(0.99),
        "max": values[-1],
    }


def analyze_capture(report: dict[str, Any]) -> dict[str, Any]:
    if report.get("schema") != SCHEMA:
        raise ValueError("Unsupported capture schema")
    if report.get("complete") is not True:
        raise ValueError("Capture is incomplete: stop and save recording in the game first")
    columns = report.get("frame_columns", [])
    if not isinstance(columns, list) or not all(isinstance(key, str) for key in columns):
        raise ValueError("Invalid frame column names")
    if len(set(columns)) != len(columns) or not REQUIRED_COLUMNS.issubset(columns):
        raise ValueError("Missing or duplicate frame columns")
    rows = report.get("frames")
    if not isinstance(rows, list):
        raise ValueError("Missing frame rows")
    frames: list[dict[str, float]] = []
    last_time = -1.0
    for index, row in enumerate(rows):
        if not isinstance(row, list) or len(row) != len(columns):
            raise ValueError(f"Frame {index} does not match the column schema")
        if any(
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(value)
            for value in row
        ):
            raise ValueError(f"Frame {index} contains non-finite or non-numeric data")
        frame = dict(zip(columns, row, strict=True))
        if frame["t_ms"] < last_time or frame["frame_interval_ms"] < 0:
            raise ValueError(f"Frame {index} has invalid monotonic timing")
        last_time = frame["t_ms"]
        frames.append(frame)
    # First row is a partial interval. Pause/focus transitions are encoded by producer.
    active = [row for row in frames[1:] if row["paused"] == 0 and row["focused"] == 1]
    intervals = [row["frame_interval_ms"] for row in active]
    total_ms = sum(intervals)
    slow = [row for row in active if row["frame_interval_ms"] > 1000 / 30]
    metrics = {
        key: distribution([row[key] for row in active])
        for key in columns
        if key.endswith("_ms") and key != "t_ms"
    }
    events = report.get("events", [])
    contexts = report.get("contexts", [])
    if not isinstance(events, list) or not all(isinstance(event, dict) for event in events):
        raise ValueError("Invalid event rows")
    if not isinstance(contexts, list) or not all(isinstance(context, dict) for context in contexts):
        raise ValueError("Invalid context rows")
    markers = []
    for event in events:
        if event.get("kind") != "marker":
            continue
        when = event.get("t_ms", 0)
        if not isinstance(when, (int, float)) or not math.isfinite(when):
            raise ValueError("Invalid marker timestamp")
        nearby = [row for row in active if when - 2000 <= row["t_ms"] <= when + 500]
        markers.append(
            {
                "t_ms": when,
                "label": str(event.get("label", "")),
                "frames": len(nearby),
                "worst_frame": max(nearby, key=lambda row: row["frame_interval_ms"], default=None),
            }
        )
    warnings = []
    metadata = report.get("metadata", {})
    if not isinstance(metadata, dict):
        raise ValueError("Invalid capture metadata")
    diagnostics_enabled = bool(metadata.get("soil_diagnostics_enabled", False))
    if diagnostics_enabled:
        warnings.append(
            "录制前已开启完整土体诊断：soil/commit 耗时包含额外摘要计算。"
            "这是诊断负载，建议关闭切削诊断再录一份正常负载。"
        )
    if not active:
        warnings.append("没有完整且处于焦点内的驾驶帧；可能全程暂停、窗口失焦或使用了 headless。")
    if report.get("dropped_events", 0):
        warnings.append(f"事件达到上限，丢弃 {report['dropped_events']} 条；逐帧累计耗时仍保留。")
    if not any(row["render_gpu_ms"] > 0 for row in active):
        warnings.append("GPU 计时没有有效正值，不能据此排除 GPU 瓶颈。")
    warnings.append(
        "同帧相关性用于筛选调查方向，不证明因果；渲染计时可能延迟，CPU/GPU 与嵌套阶段不可直接相加。"
    )
    models = sorted(
        {str(context.get("model_id")) for context in contexts if context.get("model_id")}
    )
    return {
        "metadata": report.get("metadata", {}),
        "full_diagnostics_enabled": diagnostics_enabled,
        "models": models,
        "total_frames": len(frames),
        "active_frames": len(active),
        "excluded_frames": len(frames) - len(active),
        "average_fps": len(active) * 1000 / total_ms if total_ms else 0,
        "over_budget": {
            str(limit): sum(value > limit for value in intervals)
            for limit in [1000 / 60, 1000 / 30, 50, 100]
        },
        "metrics_ms": metrics,
        "slow_frame_count": len(slow),
        "slow_frame_clues": {
            "soil_at_least_half_interval": sum(
                row["soil_total_ms"] >= row["frame_interval_ms"] * 0.5 for row in slow
            ),
            "render_gpu_at_least_20ms": sum(row["render_gpu_ms"] >= 20 for row in slow),
            "render_cpu_at_least_10ms": sum(row["render_cpu_ms"] >= 10 for row in slow),
            "recorder_at_least_1ms": sum(row["recorder_ms"] >= 1 for row in slow),
        },
        "worst_frames": sorted(active, key=lambda row: row["frame_interval_ms"], reverse=True)[:20],
        "markers": markers,
        "transaction_events": sum(event.get("kind") == "transaction" for event in events),
        "max_pending_readiness": max(
            (context.get("pending_readiness_count") or 0 for context in contexts), default=0
        ),
        "max_queue_depth": max(
            (context.get("queue_depth") or 0 for context in contexts), default=0
        ),
        "stop_reason": report.get("stop_reason"),
        "warnings": warnings,
    }


def render_markdown(result: dict[str, Any]) -> str:
    lines = [
        "# 性能录制分析",
        "",
        (
            "**注意：本次开启完整土体诊断，耗时包含额外诊断负载。**"
            if result["full_diagnostics_enabled"]
            else "本次使用轻量计时，录制器未启用额外地形摘要计算。"
        ),
        "",
        f"机型：{', '.join(result['models']) or '未记录'}。"
        f"驾驶帧 {result['active_frames']} / 总帧 {result['total_frames']}；"
        f"排除首个不完整帧、暂停或失焦帧 {result['excluded_frames']}。"
        f"平均 {result['average_fps']:.1f} FPS。",
        "",
        "耗时单位为毫秒；-1 为不可用，统计中已排除。物理指标是引擎最近报告的单步耗时。",
        "",
        "| 指标 | P50 | P95 | P99 | 最大 |",
        "|---|---:|---:|---:|---:|",
    ]
    labels = {
        "frame_interval_ms": "帧间隔（含等待）",
        "engine_process_ms": "引擎 process",
        "engine_physics_ms": "引擎 physics 单步",
        "render_cpu_ms": "渲染 CPU（主视口）",
        "render_gpu_ms": "渲染 GPU（主视口）",
        "render_setup_cpu_ms": "渲染准备 CPU",
        "soil_total_ms": "土体总计",
        "soil_automatic_ms": "姿态/切割提案",
        "soil_step_ms": "土体 step（含提交/就绪查询）",
        "soil_publish_ms": "状态发布/订阅者",
        "commit_ms": "切割/卸土提交",
        "coverage_ms": "覆盖采样",
        "material_ms": "材料账本",
        "native_edit_ms": "原生地形编辑",
        "digest_ms": "诊断摘要",
        "readiness_issue_ms": "碰撞就绪登记",
        "recorder_ms": "录制器自身",
    }
    for key, label in labels.items():
        metric = result["metrics_ms"].get(key, {})
        if metric.get("count", 0):
            values = " | ".join(f"{metric[field]:.3f}" for field in ["p50", "p95", "p99", "max"])
            lines.append(f"| {label} | {values} |")
        else:
            lines.append(f"| {label} | 不可用 | — | — | — |")
    lines.extend(["", "## 卡顿线索", ""])
    for limit, count in result["over_budget"].items():
        lines.append(f"- 超过 {float(limit):.2f} ms：{count} 帧")
    clues = result["slow_frame_clues"]
    lines.extend(
        [
            f"- 在 {result['slow_frame_count']} 个超过 33.33 ms 的帧中："
            f"土体耗时至少占一半 {clues['soil_at_least_half_interval']} 帧；"
            f"GPU 报告 ≥20 ms {clues['render_gpu_at_least_20ms']} 帧；"
            f"渲染 CPU ≥10 ms {clues['render_cpu_at_least_10ms']} 帧；"
            f"录制器 ≥1 ms {clues['recorder_at_least_1ms']} 帧。",
            f"- 4 Hz 抽样的最大待碰撞就绪工作数：{result['max_pending_readiness']}；"
            f"最大土体队列：{result['max_queue_depth']}。",
            f"- 记录事务事件 {result['transaction_events']} 条；"
            f"停止原因：{result['stop_reason']}。",
            "",
            "## 最慢驾驶帧",
            "",
            "| 时间(s) | 帧间隔 | 土体总计 | 提案 | Step | 发布 |"
            " 原生编辑 | 渲染CPU | GPU | 录制器 |",
            "|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
        ]
    )
    for frame in result["worst_frames"]:
        keys = [
            "frame_interval_ms",
            "soil_total_ms",
            "soil_automatic_ms",
            "soil_step_ms",
            "soil_publish_ms",
            "native_edit_ms",
            "render_cpu_ms",
            "render_gpu_ms",
            "recorder_ms",
        ]
        cells = " | ".join(f"{frame[key]:.3f}" if frame[key] >= 0 else "不可用" for key in keys)
        lines.append(f"| {frame['t_ms'] / 1000:.3f} | {cells} |")
    lines.extend(["", "## 手动标记（前 2 秒至后 0.5 秒）", ""])
    for marker in result["markers"]:
        worst = marker["worst_frame"]
        evidence = (
            f"最慢 {worst['frame_interval_ms']:.2f} ms，土体 {worst['soil_total_ms']:.2f} ms"
            if worst
            else "附近无完整驾驶帧"
        )
        label = marker["label"].replace("\n", " ").replace("\r", " ")
        lines.append(f"- {marker['t_ms'] / 1000:.3f}s · {label}：{evidence}。")
    if not result["markers"]:
        lines.append("无手动标记。")
    lines.extend(["", "## 测量限制", ""])
    lines.extend(f"- {warning}" for warning in result["warnings"])
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("--output", type=Path, help="Markdown report; defaults beside the capture")
    parser.add_argument("--json-output", type=Path, help="Optional machine-readable analysis")
    args = parser.parse_args()
    try:
        report = json.loads(args.capture.read_text(encoding="utf-8-sig"))
        if not isinstance(report, dict):
            raise ValueError("Capture root must be an object")
        result = analyze_capture(report)
        output = args.output or args.capture.with_suffix(".analysis.md")
        if output.resolve() == args.capture.resolve() or (
            args.json_output
            and args.json_output.resolve() in {args.capture.resolve(), output.resolve()}
        ):
            raise ValueError("Output paths must not overwrite the capture or each other")
        output.write_text(render_markdown(result), encoding="utf-8")
        if args.json_output:
            args.json_output.write_text(
                json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
            )
    except (OSError, ValueError, TypeError) as error:
        parser.exit(1, f"Capture analysis failed: {error}\n")
    print(f"Analysis saved: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
