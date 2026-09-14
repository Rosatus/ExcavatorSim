"""Isolated regressions for the installed Codex context hooks.

Run: python -m unittest discover -s .trellis/tests -p test_context_hooks.py
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ContextHooksTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="trellis-hooks-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / ".git").mkdir()
        self.task = ".trellis/tasks/fixture"
        self.task_dir = self.root / self.task
        self.task_dir.mkdir(parents=True)
        (self.root / ".trellis/workflow.md").write_text(
            (ROOT / ".trellis/workflow.md").read_text(encoding="utf-8"), encoding="utf-8"
        )
        self.sessions = self.root / ".trellis/.runtime/sessions"
        self.sessions.mkdir(parents=True)
        (self.sessions / "codex_owner.json").write_text(
            json.dumps({"current_task": self.task}), encoding="utf-8"
        )
        self.status("in_progress")
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("TRELLIS_", "CODEX_", "CLAUDE_", "CURSOR_", "GEMINI_",
                                   "ZCODE_", "KIRO_", "FACTORY_", "QODER_", "CODEBUDDY_",
                                   "COPILOT_", "TRAE_"))
        }
        self.env["PYTHONPATH"] = str(ROOT / ".trellis/scripts")

    def status(self, status):
        (self.task_dir / "task.json").write_text(
            json.dumps({"id": "fixture", "status": status}), encoding="utf-8"
        )

    def run_hook(self, name, payload, **env):
        raw = payload if isinstance(payload, str) else json.dumps({"cwd": str(self.root), **payload})
        result = subprocess.run(
            [sys.executable, "-X", "utf8", str(ROOT / ".codex/hooks" / name)],
            input=raw, capture_output=True, text=True, encoding="utf-8",
            cwd=self.root, env={**self.env, **env}, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout) if result.stdout.strip() else None

    def native(self, **payload):
        return self.run_hook("inject-subagent-context.py", {
            "hook_event_name": "SubagentStart", "agent_type": "trellis-check",
            "session_id": "owner", **payload,
        })

    def test_no_task_turn_is_silent_even_with_another_session(self):
        for payload in ({"session_id": "other"}, {}):
            self.assertIsNone(self.run_hook("inject-workflow-state.py", payload))

    def test_active_task_and_recovery_repeat_current_breadcrumb(self):
        for status in ("planning", "in_progress", "completed"):
            self.status(status)
            first = self.run_hook("inject-workflow-state.py", {"session_id": "owner"})
            second = self.run_hook("inject-workflow-state.py", {"session_id": "owner"})
            self.assertEqual(first, second)  # No dedupe cache that can hide context after compaction.
            context = first["hookSpecificOutput"]["additionalContext"]
            self.assertIn(f"fixture ({status})", context)
            self.assertNotIn("<codex-mode>", context)
            self.assertNotIn("<trellis-bootstrap>", context)
            self.assertLess(len(context), 1000)

    def test_unknown_status_and_stale_pointer_remain_visible(self):
        self.status("blocked")
        context = self.run_hook("inject-workflow-state.py", {"session_id": "owner"})
        self.assertIn("blocked", context["hookSpecificOutput"]["additionalContext"])
        (self.sessions / "codex_owner.json").write_text(
            json.dumps({"current_task": ".trellis/tasks/missing"}), encoding="utf-8"
        )
        context = self.run_hook("inject-workflow-state.py", {"session_id": "owner"})
        self.assertIn("stale", context["hookSpecificOutput"]["additionalContext"])

    def test_malformed_metadata_does_not_inject_policy(self):
        for raw in ("broken", "[]", "null"):
            (self.task_dir / "task.json").write_text(raw, encoding="utf-8")
            self.assertIsNone(self.run_hook("inject-workflow-state.py", {"session_id": "owner"}))

    def test_disabled_and_malformed_hooks_are_silent(self):
        for hook in ("inject-workflow-state.py", "inject-subagent-context.py"):
            for payload in ("{bad", "[]", "null"):
                self.assertIsNone(self.run_hook(hook, payload))
            self.assertIsNone(self.run_hook(hook, {"session_id": "owner"}, TRELLIS_HOOKS="0"))

    def test_native_context_is_bounded_without_reading_task_documents(self):
        marker = "TASK_DOCUMENT_MUST_NOT_BE_INJECTED"
        for name in ("prd.md", "design.md", "implement.md"):
            (self.task_dir / name).write_text(marker * 10000, encoding="utf-8")
        (self.task_dir / "check.jsonl").write_text(
            json.dumps({"file": f"{self.task}/prd.md"}) + "\n", encoding="utf-8"
        )
        result = self.native()
        context = result["hookSpecificOutput"]["additionalContext"]
        self.assertEqual(result["hookSpecificOutput"]["hookEventName"], "SubagentStart")
        self.assertIn(f"Active task: {self.task}", context)
        self.assertIn(f"{self.task}/check.jsonl", context)
        self.assertNotIn(marker, context)
        self.assertLess(len(context), 1200)

    def test_native_missing_parent_never_borrows_environment_or_single_session(self):
        self.assertIsNone(self.native(session_id=""))
        result = self.native(session_id="other")
        context = result["hookSpecificOutput"]["additionalContext"]
        self.assertNotIn(self.task, context)
        self.assertIn("No active task", context)
        result = self.run_hook("inject-subagent-context.py", {
            "hook_event_name": "SubagentStart", "agent_type": "trellis-check",
            "session_id": "other",
        }, TRELLIS_CONTEXT_ID="codex_owner", CODEX_THREAD_ID="owner")
        self.assertNotIn(self.task, result["hookSpecificOutput"]["additionalContext"])

    def test_native_roles_and_event_filtering(self):
        for role in ("trellis-check", "trellis-research", "trellis-implement"):
            context = self.native(agent_type=role)["hookSpecificOutput"]["additionalContext"]
            self.assertIn("Only the main agent implements or fixes", context)
            if role == "trellis-implement":
                self.assertIn("without edits", context)
        self.assertIsNone(self.native(agent_type="default"))
        self.assertIsNone(self.native(hook_event_name="PreToolUse"))


if __name__ == "__main__":
    unittest.main()
