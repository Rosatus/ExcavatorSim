# Soil authority migration validation

## Goal and user value

Promote the new full-bucket active-soil path to the default product mode only
after it proves visual continuity, material conservation, game feel, lifecycle
safety, performance, and fallback behavior on both excavator models.

## Dependencies

Requires all prior children of `08-24-gameplay-soil-interaction-rebuild` and the
before evidence from `08-24-visual-baseline-evidence`.

## Requirements

- Run legacy and new shadow paths against the same scripted and interactive
  journeys; record transfer, field, ledger, response, performance, and visual
  differences with explicit expected/defect classifications.
- Select `legacy`, `shadow`, or `active_patch` once per generation. Cutover and
  rollback occur only through reset/model/authority transitions with no
  in-flight material migration.
- In `active_patch`, disable every legacy parcel call that owns bucket credit,
  release debit, or terrain settlement. Optional parcels become bounded visual
  hero clods sourced from immutable accepted transfers.
- Preserve the complete legacy mode as a compatibility fallback through this
  task and document automatic/manual fallback behavior.
- Exercise full-bucket cut, side cut, scrape/grade, push/back-drag, scoop, carry,
  spill, dump, pile settle, support, pause/focus, reset, disable, and model switch
  in real offline product runs for SY205 and SY135.
- Feed the versioned soil/response snapshots into the separate visual product
  tasks without allowing presentation to become an authority.

## Acceptance criteria

- [ ] `active_patch` is the default only after both models complete the real
      operator journey with nonzero payload, visible carry/dump, conservative
      settle, and no test-only credit or manual Dig/Deposit seam.
- [ ] Exactly one owner handles cut, bucket entry/release, and settlement in every
      mode; assertions catch any old/new double owner.
- [ ] Twenty-cycle and fault-injection soaks remain within the declared material
      tolerance and leave no stale body, patch, transfer, payload, or response.
- [ ] Legacy fallback completes its prior regression contract and can be selected
      only at a clean generation boundary after new-path initialization/runtime
      failure.
- [ ] Hero-clod/particle/fill density and audio/mute/quality settings cannot
      change material totals or final terrain within tolerance.
- [ ] Side-by-side evidence shows clear improvement in soil entering the bucket,
      carry readability, dumping, pile formation, push/grading, and machine
      response for both models.
- [ ] Balanced 1920×1080 sustains 60 FPS on the development machine; low and
      unsupported-compute fallbacks remain usable and visually coherent.
- [ ] Offline/gateway degradation, Terrain3D/fallback, low/balanced/high,
      lifecycle, standalone, `pixi run verify`, provenance, task validation,
      diff, and human visual-review gates pass.

## In scope

Shadow comparison, mode selection/cutover/rollback, disabling legacy ownership in
primary mode, visual-only hero-clod adapter, final two-model evidence and soaks,
default-mode switch, specs, runbook, and release guidance.

## Out of scope

Deleting the legacy implementation, expanding the solver after gates pass,
professional calibration, new mission/economy content, simultaneous machines,
or unrelated HUD/camera/site polish.
