# Delegation policy

The main agent owns decisions, implementation, fixes, integration and final delivery. Subagents explore and verify without editing project files. Research notes and review findings return to the main agent for persistence and fixes.

Use native subagents for ordinary bounded work. Use Trellis channel only for cross-tool peer processes, durable shared records or capabilities missing from the native tools. Multiple turns, progress inspection and waiting alone do not require a channel. Ask follow-up questions only while material uncertainty or disagreement remains; there is no round quota.

Dispatch the bounded question, current goal/acceptance relevant to it, ownership/scope, known evidence and expected output. Include an exact task path when needed. Task artifacts and optional manifests are discovery paths, not a package to preload. Read only missing relevant sections and contracts; do not infer another session's active task. If supplied scope is sufficient, no task is required.

Reuse supplied valid evidence and follow validation.md when checks are needed. Return concrete findings with file:line or source links, uncertainty and verification limits. Do not run unrelated suites, repeat valid checks or create tests just to complete a review. Do not spawn further agents or perform Git operations.

Role adapters under .codex/agents/, .opencode/agents/ and .trellis/agents/ reference this file. The legacy implement role is retained for compatibility as an analysis-only advisor; it must return proposed changes to the main agent without applying them.
