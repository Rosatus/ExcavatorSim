# Product experience validation

## Goal

Prove the accumulated changes form one usable product, close integration defects,
and produce after evidence and release-candidate guidance for both models.

## Requirements

- Regenerate the exact baseline matrix as after evidence and create side-by-side
  comparisons with the original scorecard.
- Execute cold-start and experienced-operator journeys on SY205 and SY135:
  onboarding/start, camera setup, travel, dig, carry, dump, pause/focus recovery,
  reset, model switch, and repeat.
- Extend the soil journey with forward/side cut, floor scrape/grade, back push,
  nonzero scoop, controlled spill, dump, pile settle, and legacy fallback.
- Measure time-to-discover/time-to-complete, camera clipping, warning clarity,
  balanced 1080p frame pacing, fixed-step maxima, and effect/audio budgets.
- Run the five-minute discoverability gate from a clean profile with an evaluator
  who did not implement the controls: timing starts at product launch, only
  in-product prompts/onboarding are allowed, and success requires start, straight
  travel, productive dig, nonzero carry, dump, and reset without intervention.
- Exercise offline default, optional gateway degradation, low/balanced/high
  profiles, 1280×720 and 1920×1080 UI, mute, focus loss, and reset generations.
- Fix P0/P1 integration defects within parent scope and explicitly defer any
  remaining P2 with evidence and rationale.
- Update specs, runbook, provenance, and release-candidate checks.

## Acceptance criteria

- [ ] Both models complete every operator journey without debug seams, external
      instructions, stale state, camera clipping, stuck effects/audio, or material
      simulation regressions.
- [ ] Active soil mode has one material owner, conservative 20-cycle behavior,
      nonzero real payload, continuous cut/carry/dump/settle visuals, bounded
      speed response, and clean generation-level legacy fallback.
- [ ] A first-time evaluator completes the core journey within five minutes and
      the scorecard improves in every P0/P1-owned dimension.
- [ ] Before/after evidence is complete, comparable, and linked to closed/deferred
      backlog items.
- [ ] Balanced 1080p sustains 60 FPS on the development machine and existing
      fixed-step acceptance budgets remain green.
- [ ] Offline/gateway, quality, resolution, focus, reset, and model-switch matrices
      pass.
- [ ] Full Godot matrix, `pixi run verify`, task validation, provenance, diff
      check, and human visual/audio review pass; all child and parent tasks archive.

## Out of scope

New feature work outside the approved visual and gameplay-soil parents, external
user research programs, professional hydraulic/soil calibration, multiplayer/VR,
and dynamic weather/time.
