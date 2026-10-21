# Godot Validation Budget and Human Acceptance

This policy controls validation scope for changes under `godot/client/`. Its
goal is to obtain useful regression evidence without turning every task into a
release-candidate exercise. More tests are not automatically better: use the
smallest gate that can disprove the changed behavior.

This policy does **not** discourage Godot AI MCP development. MCP remains the
recommended tool for editor-state inspection, scene/resource discovery,
structured and undoable scene authoring, property inspection, log access, and
post-edit structural verification. The budget applies to validation workload,
especially game launches and visual/experiential judgment, not to the choice of
development tool.

## Scope / Trigger

Apply this policy when planning or executing Godot client validation, including
standalone scripts, MCP/editor checks, Forward+ runs, export smoke, screenshots,
performance soak, and product-experience review.

Feature-specific contracts in other frontend specs still define *what* must be
true. This policy defines *who* verifies it, *when* a heavy gate is justified,
and how much evidence is required for an ordinary development task.

## Default Agent Validation

For a routine code change, the Agent owns fast, deterministic, low-output checks:

1. Run the narrowest available lint, parser, type, or import check for the
   changed files.
2. Run focused unit/regression tests beside the owning module.
3. If the contract cannot be exercised without Godot, run at most one targeted
   headless standalone scenario per affected behavior after the final relevant
   edit. Do not substitute the full standalone matrix merely because it is
   convenient to invoke.
4. Inspect the exit code and concise failure output. Redirect large logs to an
   artifact and summarize them instead of streaming or rereading the full log.

Routine Agent validation **must not** launch the game solely for visual or
experiential inspection. The Agent may and should use Godot AI MCP during
development to inspect or edit the project and to verify objective editor state,
node paths, resources, properties, imports, and logs. That structural MCP work
is not a human visual test and does not consume the heavy-validation budget.
Routine validation also does not run the full standalone matrix, source/export
parity, multi-model repeated soak, or screenshot evidence matrix unless an
escalation trigger below applies.

## Human-Owned Validation

The following are human checks by default:

- Forward+ image quality, materials, terrain/vegetation appearance, lighting,
  camera composition, animation feel, readability, and audio mix;
- interactive control feel, operator workflow, subjective responsiveness, and
  whether a visual artifact is noticeable during real play;
- repeated screenshots or videos used to compare presentation quality;
- long-running game observation and performance soak whose main value is
  watching rather than asserting deterministic counters.

The Agent supplies the smallest representative scene/model/profile, startup
command, actions, and expected observations. Until the user reports the result,
record the criterion as `pending human review`; never infer a pass from a
headless exit code, a nonblank screenshot, or assistant confidence.

Human review does not replace deterministic verification of bytes, payloads,
state identities, lifecycle transitions, conservation, or other code-level
contracts. Those remain Agent-owned focused tests.

Planning artifacts and final handoffs must split validation into `Agent
automated` and `Human manual` lists. A routine code handoff may leave a
non-release subjective review to the user without running it first; list the
exact manual steps instead of silently treating them as complete. If subjective
quality is an explicit acceptance or release criterion, keep that criterion
pending until the user reports the result.

## Escalation Triggers

Heavy automated validation is allowed only when at least one trigger is present:

| Gate | Trigger |
|---|---|
| Full standalone Godot matrix | Shared lifecycle/authority code, the matrix runner itself, broad protocol compatibility, a focused failure suggesting cross-feature regression, or final release validation |
| Source/export parity and packaged smoke | Export preset, packaging contents, native library/resource inclusion, packaged startup, or final release validation |
| Repeated or paired performance soak | Scheduler/timing/performance semantics, an explicit performance acceptance criterion, suspected regression, or final release validation |
| Interactive Forward+ / MCP runtime visual pass | Renderer, shader, material, camera, scene composition, imported visual asset, or an explicit visual milestone; execution and judgment are human-owned unless the user explicitly requests Agent-driven runtime operation |

When escalating, state the trigger before running the gate and choose the
smallest representative case set. A feature-specific spec may require a heavy
gate for its final milestone, but that requirement must not be generalized to
unrelated routine changes.

The accepted bucket pass-through performance mode is an explicit exception: its
paired soak is retired and must not be triggered by ordinary development, final
release validation, regression checks, or task archival. Only a new explicit
user-approved performance evaluation scope may reactivate that comparison.

## Stable-Then-Once Scheduling

- Do not start a heavy gate while implementation or its focused tests are still
  changing. Reach a stable candidate with static and focused deterministic
  checks first.
- Before expanding a multi-model/profile/cell gate, run the cheapest
  representative canary that proves dependencies, startup, scene readiness, and
  report plumbing. If it fails, stop; do not fan the same failure out across the
  Cartesian matrix.
- After the canary passes, run each justified heavy gate once after the final
  relevant edit. “Full-scope quality check” means covering every affected
  contract with the selected evidence; it does not mean invoking every available
  matrix, export, soak, and visual command.
- If that final gate exposes a real defect, return to focused reproduction and
  restabilize first. Only the directly affected heavy gate may then be rerun;
  unrelated passing gates remain valid.

## Evidence Reuse and Reruns

- A passing gate remains valid for the same source revision, configuration, and
  relevant artifacts. Do not rerun it to create newer-looking evidence.
- After a fix, rerun the failed or directly affected focused gate. Do not rerun
  every previously passing suite unless the fix changed their shared boundary.
- Run an escalated full-scope gate at most once after the final relevant edit;
  follow the stable-then-once prerequisites above.
- Retry only a clearly identified pre-scenario infrastructure/startup failure.
  Preserve the first result and retry reason; never rerun a completed scenario
  to hide a functional or performance failure.
- Existing evidence from a different revision may inform diagnosis but cannot
  be claimed as validation of changed code.

## Validation Matrix

| Change | Agent required | Human required | Not routine |
|---|---|---|---|
| Pure GDScript logic | Parser/static checks plus focused unit or targeted headless regression | None unless behavior is subjective | Full matrix, editor launch, export, soak |
| UI state or deterministic layout contract | Focused state/layout assertions | Visual clarity and interaction feel | Repeated screenshots and full product tour |
| Material, lighting, vegetation, camera, animation, audio | Import/parser checks and any focused state contract | One representative Forward+ review | Agent-declared aesthetic pass, full evidence matrix |
| Shared lifecycle/authority/protocol | Focused contract tests, then one justified full matrix after final edit | Only subjective product behavior | Repeating the matrix after every fix |
| Packaging/export | Focused packaging checks and one source/export smoke after final edit | Packaged visual/interaction review when relevant | Soak or unrelated feature matrices |
| Performance behavior | Focused counters/invariants; justified benchmark once | Long observation or subjective smoothness | Blind repeated soak without an acceptance criterion |

Godot AI MCP inspection/authoring may accompany every row when it helps develop
or objectively verify the change; it is not itself an escalation trigger.

## Good / Base / Bad Cases

- Good: a bucket-state change runs its focused GDScript regression; the handoff
  asks the user to verify one representative Forward+ interaction if feel or
  appearance changed.
- Base: documentation or non-runtime metadata changes use static checks only.
- Bad: every Godot change launches the editor, runs 36 standalone scripts,
  exports twice, performs multi-model soak, and captures screenshots even though
  none of those gates can disprove the edited contract.

## Wrong vs Correct

```text
Wrong: routine script edit -> avoid MCP -> edit scene blind -> full matrix -> repeated soak -> Agent visual judgment
Correct: MCP-assisted inspection/authoring -> focused deterministic test -> concise result -> targeted human visual check only when needed
```
