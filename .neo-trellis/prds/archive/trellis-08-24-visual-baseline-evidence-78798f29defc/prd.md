# Visual baseline and evidence

## Goal and user value

Create a reproducible, reviewable picture of the current SY205/SY135 experience
and convert subjective dissatisfaction into an evidence-linked backlog and
measurable targets for the later visual children and the separate gameplay-soil
task tree.

## Requirements

- Capture the 24-cell core matrix at 1920×1080: SY205/SY135 ×
  low/balanced/high × carry/dump/terrain/bucket-ground-support. Here `support`
  means the existing deterministic bucket-ground support/contact-transfer case,
  not an optional renderer path.
- At balanced quality, additionally capture startup/idle, controls-visible,
  travel, dig, and reset/recovery; together with carry and dump these form the
  complete seven-checkpoint operator journey for both models.
- Record commit, Godot version, model, quality profile, resolution, authority,
  lifecycle, soil-authority mode, capture command, checkpoint, support-case definition, Godot
  error-log outcome, and comparable FPS/frame-time sampling details next to
  every artifact. An explicit no-error result is evidence, not an omitted field.
- Score each model from 1–5 for control discoverability, HUD hierarchy, camera
  usability/framing, site composition/scale, lighting/material readability,
  machine-ground contact, soil feedback, audio feedback, and recovery clarity.
- Produce a P0/P1/P2 backlog. Every item includes screenshot/checkpoint evidence,
  repository anchor, observable user impact, acceptance target, and exactly one
  owning visual child or gameplay-soil task.
- Reuse and minimally extend `visual_evidence_capture.gd`; do not alter simulation
  behavior merely to create a better baseline image.
- Document capture nondeterminism and decide which checkpoints can support future
  automated comparison versus mandatory human review.
- Keep subjective visual review batched and human-owned. Routine soil/code tasks
  use objective artifact/state/performance gates and do not pause for repeated
  assistant-led screenshot inspection.

## Acceptance criteria

- [x] The 24-cell core matrix and ten balanced-only journey captures exist with
      complete metadata and can be regenerated from one documented runbook.
- [x] Every matrix cell links a visual-defect result, captured Godot error-log
      result, and comparable performance sample including sampling window,
      hardware, command, timestamp, FPS, and frame-time summary.
- [x] The scorecard contains all nine dimensions for both models with evidence,
      not unanchored aesthetic claims.
- [x] The backlog has no uncategorized P0/P1 issue and maps every P0/P1 to exactly
      one later visual child or gameplay-soil task plus an observable acceptance
      target.
- [x] Current no-audio, diagnostic-first HUD, single non-collision camera,
      placeholder soil close-up, limited site scale cues, and fallback terrain
      parity are explicitly evaluated.
- [x] Capture additions pass focused tests, the standalone matrix remains green,
      task context validates, and `git diff --check` is clean.

## In scope

Evidence harness/runbook, task research artifacts, metadata, rubric, prioritized
backlog, and small test-only capture hooks needed for deterministic checkpoints.

## Out of scope

Product-facing HUD, camera, site, soil, VFX, or audio improvements. Those belong
to later implementation tasks so the legacy before evidence stays honest.
