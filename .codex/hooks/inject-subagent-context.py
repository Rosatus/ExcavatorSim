#!/usr/bin/env python3
"""Codex SubagentStart adapter: exact parent task and on-demand context paths.

Only the event registered in .codex/hooks.json is supported here. Role policy
lives in .trellis/delegation.md; no task documents or manifest targets are read.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

AGENTS_ALL = ("trellis-implement", "trellis-check", "trellis-research")


def find_repo_root(start: str) -> Path | None:
    current = Path(start).resolve()
    for candidate in (current, *current.parents):
        if (candidate / ".git").exists():
            return candidate
    return None


def resolve_parent_task(root: Path, session_id: str) -> str | None:
    scripts = root / ".trellis" / "scripts"
    if str(scripts) not in sys.path:
        sys.path.insert(0, str(scripts))
    from common.active_task import resolve_active_task

    active = resolve_active_task(
        root, {"session_id": session_id}, platform="codex",
        allow_single_session_fallback=False, allow_environment_context=False,
    )
    if active.stale or not active.task_path:
        return None
    if not (root / active.task_path).is_dir():
        return None
    return active.task_path


def build_context(root: Path, role: str, task: str | None) -> str:
    parts = [
        "<!-- trellis-hook-injected -->",
        "Only the main agent implements or fixes. Follow .trellis/delegation.md.",
        "The dispatch supplies scope, goal and relevant acceptance. Read missing relevant sections only; these paths are not preloaded context.",
    ]
    if role == "trellis-implement":
        parts.append("Legacy implement role: return analysis and suggestions without edits.")
    if task:
        parts.append(f"Active task: {task}")
        names = ["prd.md", "design.md", "implement.md"]
        if role in ("trellis-check", "trellis-implement"):
            names.append("check.jsonl" if role == "trellis-check" else "implement.jsonl")
        for name in names:
            if (root / task / name).is_file():
                parts.append(f"- {Path(task).as_posix()}/{name}")
    else:
        parts.append("No active task resolved for this parent. Use supplied scope; do not borrow another session's task.")
    return "\n".join(parts)


def handle(data: dict) -> dict | None:
    event = data.get("hook_event_name") or data.get("hookEventName")
    role = data.get("agent_type") or data.get("agentType")
    session = data.get("session_id")
    if event != "SubagentStart" or role not in AGENTS_ALL:
        return None
    if not isinstance(session, str) or not session.strip():
        return None
    cwd = data.get("cwd") or os.getcwd()
    if not isinstance(cwd, str):
        return None
    root = find_repo_root(cwd)
    if root is None or not (root / ".trellis").is_dir():
        return None
    task = resolve_parent_task(root, session.strip())
    return {"hookSpecificOutput": {
        "hookEventName": "SubagentStart",
        "additionalContext": build_context(root, role, task),
    }}


def main() -> int:
    if os.environ.get("TRELLIS_HOOKS") == "0" or os.environ.get("TRELLIS_DISABLE_HOOKS") == "1":
        return 0
    try:
        data = json.load(sys.stdin)
        output = handle(data) if isinstance(data, dict) else None
    except (ValueError, OSError, TypeError, ImportError):
        return 0  # Missing or invalid runtime context must not block dispatch.
    if output:
        print(json.dumps(output, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
