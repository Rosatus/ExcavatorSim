# Local lightweight Trellis policy

Customized 2026-09-10 against installed Trellis 0.6.8. Project-local, not a global CLI patch or upstream fork.

Canonical method: workflow.md. Validation: validation.md. Delegation: delegation.md. Only the main agent implements and fixes; subordinate roles explore and review. Task storage and hook event wiring are preserved. Prompt-producing adapters and the new-task PRD skeleton avoid old approval/document gates. Codex executes inline; bookkeeping auto-commit is disabled.

Preserved: acceptance, domain correctness/provenance/visual gates, task decomposition, checkpoints and recovery. Removed: routine approvals, document quotas, compulsory agent chains, full-suite-per-edit, forced retrospectives and bookkeeping commits.

## Updates

Exact maintained files are in config.yaml update.skip, including config.yaml itself. In installed 0.6.8 this excludes them from normal template updates; breaking-release migrations can explicitly bypass skips. Do not use skip as an unconditional guarantee, manually edit template hashes, or reselect/reinitialize an upstream workflow over this policy.

Before upgrading, save current work and inspect the upgrade in an isolated copy/worktree. Compare relevant upstream fixes manually; skipped files do not merge automatically. Check update.skip, session_auto_commit:false and codex.dispatch_mode:inline remain correct. Review changes to the small modified runtime helpers and exercise phase extraction/hook payloads after upgrade. Keep these policy files versioned for portability.

## Ownership and reduced duplication

- Eight role cards are thin platform adapters to delegation.md. The legacy implement role remains discoverable but returns analysis only. Codex cards use read-only sandbox configuration; OpenCode cards deny write/edit. Channel cards enforce the same policy in their prompts.
- Shared channel/session-insight skills own capability routing. Their OpenCode SKILL.md files redirect to the canonical `.agents/skills/` files; legacy OpenCode reference copies are not on that route and are not separately customized. CLI syntax references otherwise remain upstream-owned.
- Codex's subagent hook supports only the actually registered native SubagentStart event. It supplies task paths, not full task documents or manifest expansions. OpenCode keeps its Task hook and shell identity bridge with the same path-only context policy. These interactive hooks use event identity without borrowing a different session or accepting server-wide environment overrides.
- No-task workflow hooks are silent. Active-task breadcrumbs remain stateless and repeatable so compaction does not depend on an external dedupe cache. Duplicate inline status blocks and per-turn mode/bootstrap banners are removed. Python hook startup still occurs on each registered event; this change does not eliminate process startup cost.
- The unregistered Codex session-start.py is retained as a compatibility asset. It is not counted as live prompt overhead and is not newly wired into sessions.
- The verified Windows/FNM bootstrap remains in global AGENTS.md; it is an environment requirement, not a Trellis workflow gate. No wrapper or global npm modification was needed in this pass.

There are now 46 protected files rather than 35: previously unprotected active adapters and capability routing also require protection. The improvement is fewer independent policy bodies and much smaller injection code, not a claim that the exclusion count decreased. Do not remove protections merely to reduce that number. Future upstream adoption can retire adapters only after equivalent behavior is verified. New delegation.md and regression fixtures are local-owned files, not upstream template replacements.

## Behavioral acceptance

- Small edit: no task/approval ceremony or unrelated suites.
- Plan-only: no implementation until authorized.
- Large work: milestones/acceptance overall, only current milestone detailed.
- Compaction: goal/checkpoint, actual code, then Next; no replayed approvals/tests.
- Repair: affected checks, reuse unrelated passing evidence.
- Pending human acceptance: keep incomplete and record Next.
- Finish: concise handoff; no automatic commits or duplicate journal.

Actual model behavior still needs observation on real tasks: measure unnecessary approvals, repeated checks, recovery accuracy and defects. A shorter prompt is not proof of quality or wall-clock improvement.

## Validation of this customization

Current routing/context validation: 8 Python regression tests and 5 Node plugin tests using temporary repositories, including no-task silence, repeatable active-task recovery, malformed input, path-only injection with large documents, exact-parent isolation, conflicting server environment, and Windows/POSIX shell identity prefixes. Codex TOML/hooks JSON parsing, effective auto-commit/dispatch configuration, canonical skill routing, all 46 exclusion paths and 13 phase extraction routes were checked. Scoped diff whitespace checks passed. No unrelated application suite or upstream update was run.

Repeat after affected changes:

```text
python -m unittest discover -s .trellis/tests -p test_context_hooks.py
node --test .trellis/tests/opencode-context.test.mjs
```

Earlier lightweight-policy validation covered SessionStart fixtures and PRD generation; this pass did not change those consumers. Actual client hook approval/loading is not established by these isolated tests. Skill description and role discovery changes may require a fresh client session.

These checks establish parser/prompt integration, not a live-client compact/recovery or model-quality benchmark. Backup before edits: `C:/Users/rosatus/.codex/backups/trellis-lightweight-20260910/`.
