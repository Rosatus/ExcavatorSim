# Design — visual baseline and evidence

## Capture model

Extend the existing SceneTree evidence runner into a checkpoint driver that uses
the production `main.tscn`, activates each model through ProductSession, selects
low/balanced/high quality, fixes viewport size, waits deterministic settle
frames, and records PNG plus JSON metadata. The core driver produces
carry/dump/terrain/bucket-ground-support for all six model/profile cells; the
balanced driver adds startup/controls-visible/travel/dig/reset. Scripted state
setup may use existing test seams, but lifecycle/model transitions must use the
real offline product control plane and every image must render the production
presentation path.

A batched human milestone separately evaluates discoverability, input, camera
occlusion, recovery, realism, and composition because those qualities cannot be
inferred from static pixels. Routine code children retain automated state and
artifact checks but do not repeatedly perform assistant-led visual inspection.
The human review uses the same checkpoint names and scorecard.

## Artifact layout

- `research/visual-baseline.md`: scorecard, P0/P1/P2 backlog, nondeterminism, and
  ownership map.
- `research/evidence/before/manifest.json`: regeneration metadata, complete
  matrix index, per-cell visual finding, error-log result, and performance
  result. Each entry identifies model, quality, checkpoint, support-case
  definition where applicable, PNG/hash, capture command, Godot/commit/hardware,
  authority/lifecycle, resolution, timestamp, and evidence links.
- PNG captures under `research/evidence/before/<model>/` when repository size is
  acceptable; otherwise the manifest records the stable external artifact path
  and hashes while the markdown embeds review-sized evidence.

## Review boundary

Automation verifies file completeness, dimensions, metadata, nonblank renders,
and deterministic scene state. A human side-by-side review owns composition,
legibility, realism, audio mix, and interaction judgments. Human review is
batched at declared visual milestones and must not block unrelated soil/code
implementation. No pixel threshold is introduced until repeat captures quantify
normal variance.
