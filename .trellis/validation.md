# Validation policy

This shared method replaces generic full-suite-per-edit instructions. Explicit user acceptance, actual CI merge requirements and triggered domain correctness/provenance/visual/performance gates remain binding.

## Select by affected behavior

- Prose-only documentation: review accuracy and links; no application suite.
- Workflow/configuration: parse formats and exercise affected consumers in isolation; no unrelated product suite.
- Local logic: applicable static checks and focused behavior/boundary tests. Add regression coverage for meaningful failure modes not already covered, not every function.
- Shared API/lifecycle/concurrency/protocol/schema: check affected producers/consumers and transitions; expand to integration/full suite when coupling leaves uncertainty.
- Assets/visuals/performance/packaging: use domain gates when their triggers apply. Preserve required human judgment; automated state checks do not prove subjective visual quality.

Use existing commands/fixtures; inspect aggregate command scope before running. Do not create duplicate runners or weaken assertions. Explicit expensive acceptance remains required. Explain material escalation briefly; this does not require permission unless authorization is missing.

## Execution and reuse

Run cheap discriminating checks first. Stabilize before expensive matrices/exports/soaks; use a canary before fan-out. Investigate failures instead of blindly retrying, preserving first failure evidence. Fix in-scope defects; report unrelated baseline failures without claiming green.
For long tasks record command/scope, result, relevant code/config/artifact state and limits. Passing checks survive compaction/unrelated edits. Revalidate affected behavior/dependencies when changed; evidence for another version cannot validate changed code. Resolve uncertain validity with the smallest meaningful check.
Final review covers cumulative task changes and acceptance. Reuse valid evidence and fill gaps; do not rerun merely to finish/commit/archive. No forced second reviewer or full re-review after every local repair. Independent review is useful for high-impact or complex work; provide existing evidence to avoid duplication.

## Completion

Report verified behavior and material omissions. Unrun is not passed. Never declare unmet acceptance complete. Pending human-only gates remain pending with an exact next action; do not manufacture a pass or archive as completed.
