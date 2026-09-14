# Development Workflow

Local lightweight policy. Preserve task persistence and recovery; choose methods to suit the work.

## Phase Index

Plan -> Execute -> Finish are recovery landmarks, not approval ceremonies.
- Discussion, read-only investigation and small edits: work directly without asking to create a task.
- Sustained/cross-context implementation: create/reuse a matching task within existing authorization unless the user opts out.
- Ask only for unresolved decisions materially affecting scope, visible behavior, compatibility, acceptance or irreversible actions. Respect plan-only requests.
- Read relevant contracts once; load missing context on demand. Do not reread unchanged files/history at every step.
- Detail the current milestone; retain later milestones as outcomes, dependencies and acceptance. Refine technical steps without renewed approval.
- Only the main agent implements and fixes. Delegate useful exploration/review under `.trellis/delegation.md`; continue independent work while waiting.
- Verify cumulative affected behavior and reuse valid evidence. Full-scope review does not mean running every test.
- On recovery read the goal and checkpoint, reconcile actual workspace state, then resume Next.
- Skills are aids, not mandatory gates: brainstorm for unclear requirements; before-dev for missing conventions; check for validation; break-loop for repeated failed fixes; update-spec for durable knowledge; finish-work for handoff.

Load detail only when needed: `python ./.trellis/scripts/get_context.py --mode phase --step <X.Y>`.

[workflow-state:no_task]
Work directly for discussion/small edits. For sustained implementation create/reuse a task within existing authorization unless the user opted out. Ask only for material unresolved decisions; no task-creation ceremony.
[/workflow-state:no_task]

[workflow-state:planning]
Read goal/current milestone. Detail only next executable work; future unknowns need not block it. If authorized and current blockers are resolved, run task.py start and proceed without another approval round.
[/workflow-state:planning]

[workflow-state:in_progress]
If recovering, read prd.md and implement.md/Progress, reconcile code and resume Next. Otherwise continue without reloading. Implement directly, validate affected behavior, reuse valid checks and checkpoint at milestones. No commit/extra approval needed for completion.
[/workflow-state:in_progress]

[workflow-state:completed]
Hand off/archive genuinely completed work. Do not restart checks or request a commit for bookkeeping.
[/workflow-state:completed]

## Phase 1: Plan

#### 1.0 Select or create a task
For sustained work query `python ./.trellis/scripts/task.py current --source` only if the session task is unknown. Reuse a matching task, not unrelated work. Create with `task.py create "<title>" --slug <name>` when persistence helps. No separate consent for ordinary bookkeeping within authorized implementation. User opt-out takes precedence; continue authorized work without task files. Preserve session identity; never fabricate another session's pointer.

#### 1.1 Requirements and rolling planning
Record goal, scope/non-goals, constraints and observable acceptance in `prd.md`. Investigate repository-answerable facts. Ask only material unresolved choices; batch independent questions when useful and continue unrelated work.
For large work record milestones, dependencies and integration acceptance. Detail only the next milestone: intended changes, relevant contracts and validation. Later milestones may retain unknowns and resolution triggers. Only unknowns blocking current work prevent execution.
Use parent/child tasks for independently deliverable work. Parent owns scope, milestone map, dependencies and integration acceptance. Children remain coarse until ready. Start the next ready child. Links are not an executable dependency graph; check documented prerequisites before starting.
Use `implement.md` for rolling steps/checkpoints when helpful; a PRD Progress section suffices for smaller work. Add `design.md` only for substantial architectural decisions. No document count is a readiness gate; avoid duplicate requirements.
Refine technical plans autonomously within scope, recording important reasons. Changes to user commitments need clarification only if not already authorized. An implementation request can authorize execution; a plan-only request cannot.

#### 1.2 Research on demand
Research to resolve decisions. Return concise sourced findings; persist expensive/reusable evidence needed after compaction. One-off lookups need no research file. Avoid reopening sufficiently established sources.

#### 1.3 Context on demand
Read relevant indexes/contracts once; use `get_context.py --mode packages` when locations are unknown. Optional implement/check JSONL manifests support selected subagent injection; missing/seed-only manifests do not block main-session work. Curate only for useful dispatch. Give agents bounded scope and evidence references, not unrelated journals/full transcripts.

#### 1.4 Activate ready work
Run `python ./.trellis/scripts/task.py start <task>` when current work is understood and authorized. No fresh approval to change status. Future milestones need not be fully designed. Follow CLI session-identity errors; do not manually alter runtime pointers.

#### 1.5 Readiness
Ready means current goal/acceptance understood, current blockers resolved, relevant constraints known and execution authorized. Files alone neither prove readiness nor justify waiting for optional documents.

## Phase 2: Execute

#### 2.1 Implement and checkpoint
Read actual code before editing; preserve unrelated changes. Choose methods within project contracts and revise steps as evidence develops. Avoid premature abstractions and tests mirroring implementation.
At milestones, significant decisions, interruptions or before anticipated compaction update the existing checkpoint: completed/current/pending work, key decisions/reasons, changed areas, checks/results, blockers and exact Next. Identify relevant code/config/artifact state (commit if available, otherwise scoped paths/diff and commands); no commit required. Mark evidence stale when affected code changes. No per-tool journal or duplicate progress record.
On recovery read the checkpoint, reconcile code and uncommitted changes, then continue. Do not replay planning/passing tests because context changed.

#### 2.2 Risk-based verification
Use `.trellis/validation.md`. Review cumulative task changes including earlier edits and select meaningful checks. Honor explicit acceptance and triggered domain gates. Never skip necessary verification, weaken assertions for green, or claim unrun checks passed.
Reuse evidence unaffected by subsequent edits. Expand/repeat only for new changes, failures, invalid evidence or unresolved concerns. Independent review is optional unless explicitly required. Report limitations honestly.

#### 2.3 Adjust or recover
Isolate failures, fix and rerun affected checks. Update technical plans and continue within scope. Pause only work dependent on unresolved product decisions. Do not automatically revert code/reset branches. Repeated failed fixes may warrant focused break-loop analysis.

## Phase 3: Finish

#### 3.2 Debug learning on demand
Analyze repeated failed fixes or surprising high-impact defects. Record supported prevention when useful. No mandatory retrospective, numerical confidence table or whole-repo search for routine fixes.

#### 3.3 Knowledge on demand
Update specs for durable contracts/non-obvious lessons; replace stale text. Tests/code may document obvious behavior sufficiently. No fixed template, speculative rules or synchronization to nonexistent upstream templates.

#### 3.4 Git operations by authorization
Completion is independent of commits. Commit/push/merge/deploy only within authorization; do not request a commit solely to finish a phase. If authorized, stage only intended changes, including appropriate hunks in mixed files. Preserve unrelated work and reuse valid checks. No fixed work/archive/journal commit sequence; authorization for one operation does not imply another.

#### 3.5 Handoff and archive
Summarize delivered behavior, verification and limitations; update the checkpoint. Archive a genuinely completed task when appropriate with `task.py archive <task>`. Never archive incomplete/unrelated tasks to finish a session. Verified uncommitted work may be handed off/archived with pending Git status recorded. Required human acceptance pending means incomplete.
Keep the pointer for continuing work; `task.py finish` only clears the session pointer, not completion. Journals are optional for cross-task knowledge, not checkpoint duplicates. `session_auto_commit: false` prevents bookkeeping commits. No extra approval/testing just for archival.

## Maintenance

This policy replaces generic ceremony, not domain contracts. Storage, session identity and hook events remain unchanged. Step numbers/tags stay parser-compatible. See `.trellis/customization.md` for update protection.
