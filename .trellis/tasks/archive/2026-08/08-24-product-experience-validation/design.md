# Design — product experience validation

## Closure strategy

This child closes the two completed product parents; it is not another feature
workstream. Existing focused contracts remain the source of truth for HUD,
camera, site, active-soil lifecycle, game-feel response, feedback/audio, model
switching, and offline operation. Final validation composes those contracts and
adds only the missing release-evidence semantics.

The visual evidence runner gains an explicit `before` / `after` phase. Baseline
runs continue to tolerate scenario failures as recorded findings. After runs
must keep the exact 34-cell model/profile/checkpoint matrix and additionally
require every scripted scenario to be achieved. The controls-visible checkpoint
reads the production onboarding HUD instead of preserving the original baseline
failure as a hard-coded result.

## Evidence and review boundary

Automation owns product state, matrix completeness, artifact integrity,
resolution, commit identity, error logs, performance samples, active authority,
payload transitions, lifecycle recovery, and existing fixed-step budgets. The
tracked final evidence records the raw after-run location and hashes while large
PNG artifacts remain under the ignored benchmark directory.

Human review owns composition, material readability, camera clipping during
free operation, effect feel, audio balance, and the clean-profile five-minute
discoverability gate. Codex does not repeatedly inspect screenshots or claim
these judgments. A compact representative checklist is handed to one human
reviewer after all automated gates are complete.

## Compatibility and rollback

- The existing capture command remains compatible: omitted phase means
  `before`, with the original baseline output directory and non-blocking
  scenario findings.
- `after` is opt-in and fails when a journey checkpoint is not achieved.
- No presentation or simulation authority is introduced by validation code.
- If a P0/P1 integration defect appears, fix it in its owning production
  controller; do not weaken the after gate. P2 findings remain explicit in the
  final scorecard.

## Human-reported P0/P1 closure

- `TrackedChassisController` remains the single spawn-heading authority. The
  model-specific SY205 180-degree yaw is applied before terrain-normal posture
  alignment so Jolt, tracks, presentation, cameras, and soil proxies share one
  transform; no GLB-only compensation is allowed.
- The logical `TerrainState` and its derived `TerrainCollider` cover the same
  64 m footprint as the visible construction site. Terrain3D remains a derived
  renderer and optional collider, never a second support authority.
- `MotionOperatorUI` owns a persistent header-level collapse toggle outside the
  collapsible body, so the panel can always be restored. Onboarding remains a
  separate modal guide.
- `CameraRig` adds a fifth cab mode bound to the current model's semantic
  `upper_structure_link`. Its pose is an explicit model-local preset. Entering
  cab mode installs per-instance transparent material overrides only on the
  manifest-declared upper-body visual subtree; leaving the mode or changing the
  active model restores every prior override.
- Runtime attribution text is removed from the scene. Full Milky Way title,
  author, source, modification, and CC BY 4.0 attribution remains in `NOTICE.md`
  and the adjacent third-party provenance/license files.
- Track space is model data, not a keyboard or GLB-node workaround. The optional
  physics-rig `tracks.local_forward_axis` declares `-Z` (backward-compatible
  default) or `+Z`; Jolt derives vehicle forward, vehicle right, distributed
  side probes, longitudinal cleanup, and response telemetry from that one axis.
  SY205 declares `+Z`, while SY135 keeps the default `-Z` contract.
- Track action names remain stable and their runtime owner registers both input
  families: left forward/reverse is Q/A or LT/LB, and right forward/reverse is
  W/S or RT/RB. The analog triggers and digital shoulder buttons feed the same
  action strengths, so focus and neutral re-arm remain downstream invariants.
- Existing four-axis equipment actions adopt the ISO excavator gamepad pattern
  without changing keyboard or protocol order: left X is swing, left Y is arm,
  right Y is boom, and right X is bucket. Runtime registration replaces stale
  joy-axis mappings so the former bucket-trigger layout cannot survive a reload.
  HUD/onboarding copy projects these same public semantics.
- ISO stick layout, action names, keyboard bindings, and protocol channel order
  remain global. `MotionClient` owns a model-specific multiplier profile only
  for `InputEventJoypadMotion`: SY205 multiplies all four stick channels by
  `-1`, while SY135 multiplies only swing by `-1`. `ProductSession` refreshes
  that profile after initial activation and each successful offline model
  switch; transport hello acceptance does the same for compatibility profiles.
  Physical rig axes and joint limits remain untouched.
- `VisualQualityController` owns an explicit `test` presentation identity. It
  reuses low sky/audio/material-simulation budgets, disables disposable soil and
  site effects, deactivates Terrain3D so its texture/grass/rock layer cannot
  leak through, and switches the existing fallback `TerrainRenderer` to a
  procedural untextured black/white grid. The accepted terrain snapshot and
  collider remain unchanged.
