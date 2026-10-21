# Converge lightweight Trellis routing and context

## Goal

Reduce redundant routing, injected context and duplicated policy in local Trellis while retaining reliable task recovery and main-agent-only implementation.

## Requirements

- Only the main agent changes implementation/configuration/specs; subagents explore and verify.
- Ordinary delegation uses native tools; channel is for cross-tool or durable collaboration needs.
- History lookup is triggered by missing historical context, not routine workflow phases.
- No-task turns receive no workflow injection. Active tasks keep small stateless recovery breadcrumbs.
- Subagent hooks supply task artifact paths rather than loading entire document/manifests.
- Centralize role policy, preserve platform identity wiring and protect maintained adapters from upstream replacement.
- Keep the verified Windows bootstrap; no environment or global npm replacement.

## Acceptance Criteria

- [x] Native/channel/OpenCode role instructions consistently prohibit subordinate implementation.
- [x] Channel and memory skills no longer over-trigger or prescribe round quotas.
- [x] Hook tests cover no-task silence, active/recovery output, malformed input and session isolation.
- [x] Large task documents are not embedded by subagent hooks; focused context remains discoverable.
- [x] Adapters parse/load; existing OpenCode shell identity behavior remains intact.
- [x] Maintenance ownership and upgrade checks are documented without removing existing protections blindly.

## Notes

- Keep `prd.md` focused on requirements, constraints, and acceptance criteria.
- Detail the current milestone; keep later milestones as outcomes, dependencies and acceptance.
- Separate `design.md` / `implement.md` are optional; use them when they improve clarity or recovery.

## Progress

- Completed: global/project AGENTS main-agent-only boundary; shared delegation policy and eight thin role adapters; canonical channel/memory capability routing; OpenCode capability redirects; no-task hook silence; repeatable task breadcrumbs; path-only subagent context; exact hook session identity; preserved shell identity propagation.
- Evidence: 8 Python regression tests + 5 Node plugin tests pass. Tests use temporary repositories and cover recovery repetition, no-task/malformed input, large task document non-injection, missing/other parent isolation and conflicting process environment. Codex TOML/hooks JSON, effective config, all 46 update exclusions, canonical skill metadata, 13 phase routes and scoped whitespace checks pass.
- Independent review found environment identity precedence in OpenCode; fixed with opt-out for interactive consumers and a conflicting-two-session regression. Existing CLI/pull environment behavior preserved.
- Decisions: bootstrap unchanged because the prior probe confirmed a real PATH dependency. Stateless active breadcrumbs retained for compaction; no persistent dedupe cache. The unused SessionStart compatibility file is retained and remains unregistered. Capability policy owns canonical shared files; OpenCode entries redirect rather than duplicate them.
- Maintenance: update.skip increased from 35 to 46 to cover previously unprotected adapters and edited skill routing. Policy text and injection code are consolidated; no claim of fewer protected files. See customization.md for upgrade ownership and repeatable checks.
- Changed areas: AGENTS.md; global C:/Users/rosatus/.codex/AGENTS.md; .agents/skills/trellis-{channel,session-insight,check}; Codex/OpenCode role adapters and context hooks; OpenCode context helpers and capability adapters; .trellis/{delegation,workflow,config,customization}.md/yaml, role adapters and tests.
- Limits: isolated tests verify payloads and integrations, not live client hook approval/loading or model-quality/latency benchmarks. Node reports existing unspecified module-type warning; tests pass. Fresh sessions may be needed to reload skill metadata and role configuration.
- Git: changes uncommitted; unrelated existing project modifications preserved. No product code, global npm packages or original task pointers changed; only this task's pointer was created and will be cleared by archive.
- Blockers: none.
- Next: hand off; observe ordinary tasks for unnecessary reads/checks and recovery accuracy. No scheduled monitoring or additional approval required.
