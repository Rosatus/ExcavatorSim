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
- Close the current human-reported usability defects before final evidence:
  remove the in-world Milky Way credit overlay while retaining repository
  license attribution; spawn SY205 with the complete machine facing the correct
  direction; keep authoritative terrain support across the visible 64 m site;
  make the top-left operator panel collapsible; and add a cab first-person view
  for both models that makes only the upper-body shell transparent while active.
- Close the follow-up operator defects before final evidence: align SY205's
  model-local vehicle-forward axis with Jolt track sides, bind left-track
  forward/reverse to Q/A and right-track forward/reverse to W/S, and provide an
  operator-selectable test graphics mode with an untextured black/white terrain
  grid and no grass or construction-site dressing.
- Add XInput-compatible gamepad operation with the ISO excavator work-equipment
  pattern on both sticks, left/right triggers driving the corresponding track
  forward, and left/right shoulder buttons driving the corresponding track in
  reverse. Keyboard operation remains available in parallel.
- Apply the reported model-specific XInput direction calibration: reverse all
  four SY205 stick axes and reverse only SY135 swing, without changing the
  shared ISO layout, keyboard actions, physical joint axes, or joint limits.
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
- [ ] SY205 spawn/reset uses the corrected 180-degree authority heading with
      local left/right tracks, camera anchors, bucket proxies, and soil frames
      remaining aligned.
- [ ] The machine remains supported and driveable throughout the visible 64 m
      construction site; presentation terrain and authoritative height/collider
      coverage no longer diverge.
- [ ] The operator HUD can collapse and reopen without hiding its own restore
      control or breaking onboarding, and no Milky Way credit label overlays the
      running simulation.
- [ ] Both models expose a cab first-person mode attached to the upper structure;
      only that model's upper-body visual shell becomes transparent in the mode
      and is restored on exit/teardown/model switch while an authority reset
      safely reapplies the still-active cab mode.
- [ ] SY205 track commands use its visual +Z vehicle-forward convention so
      physical left/right and forward/reverse match the complete machine after
      the 180-degree spawn heading; SY135 retains its declared -Z convention.
- [ ] Keyboard input and all visible help consistently bind left forward/reverse
      to Q/A and right forward/reverse to W/S.
- [ ] XInput gamepads use the ISO excavator pattern: left stick controls
      swing/arm, right stick controls boom/bucket, LT/RT command the matching
      track forward, and LB/RB command the matching track in reverse. Focus loss,
      reset, and model switching retain the existing neutral re-arm behavior.
- [ ] SY205 XInput stick motion reverses swing, boom, arm, and bucket from the
      prior build; SY135 XInput changes only swing, while keyboard directions
      remain unchanged on both models.
- [ ] Test graphics mode is selectable in the operator HUD, uses low presentation
      budgets, disables Terrain3D textured presentation, grass, rocks, and shared
      site dressing, and renders the authoritative fallback surface as a
      texture-free black/white grid without changing terrain or physics state.
- [ ] Full Godot matrix, `pixi run verify`, task validation, provenance, diff
      check, and human visual/audio review pass; all child and parent tasks archive.

## Out of scope

New feature work outside the approved visual and gameplay-soil parents, external
user research programs, professional hydraulic/soil calibration, multiplayer/VR,
and dynamic weather/time.
