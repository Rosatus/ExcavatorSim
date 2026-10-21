# Automated product-journey evidence

## Current focused journeys

The driver now uses the production scene and a terrain-height feedback loop. It
must place the tooth edge at a shallow cutting depth before curling, then reach
the curl target before lifting, and reach the dump target before declaring the
payload transition complete. No test-only terrain or payload injection is used.

| Model | Contact | Scoop/carry | Dump | Result |
|---|---:|---:|---:|---|
| SY205 balanced | tooth clearance about `-0.03 m` | bucket about `+23 deg`, `22.57 kg` payload | bucket about `-85.5 deg`, payload `0 kg` | automated chain achieved |
| SY135 balanced | tooth clearance about `-0.055 m` | bucket about `+39.5 deg`, `3.63 kg` payload | bucket about `-5.4 deg`, payload `0 kg` | automated chain achieved |

SY205 uses a provisional gameplay range of approximately `-95 deg` outward to
`+30 deg` inward. This direction is based on the user's live visual observation,
which corrected the earlier invalid `+95 deg` assumption. The SY205 opening
plane normal was corrected independently so negative-side visual outward motion
also becomes authoritative spill/dump motion.

The active soil ledger now:

- keeps one generation-scoped material owner;
- extracts scoop flux only from active representatives local to the teeth,
  opening, or inner shell;
- stops scoop capture once the selected model reaches its spill orientation;
- uses each model contract's spill/dump thresholds for release;
- prevents released aggregate representatives from being recaptured as fresh
  bucket entry.

## Human-reported usability closure

- The permanent `OperatorUI/SkyAttribution` viewport label was removed. Full
  ESO/S. Brunier / CC BY 4.0 attribution remains in `NOTICE.md` and the adjacent
  Sky3D third-party files.
- SY205 now declares `chassis_dynamics.spawn_yaw_rad = PI`; the controller
  applies it before terrain-normal alignment, so one authority transform rotates
  Jolt, both local track sides, presentation, camera frames, and soil proxies.
- `TerrainState` now owns the complete 129×129, 0.5 m (64 m) construction-site
  surface. The central 20 m pad remains level and the existing outer grades/
  spoil contours now feed the same TerrainCollider and support sampler used by
  Jolt.
- `OperatorUI/PanelToggle` remains visible while the top-left status panel is
  collapsed and restores it without touching the onboarding guide.
- Camera mode 5 adds model-local SY205/SY135 cab poses attached to
  `upper_structure_link`. Only each manifest-declared upper-body subtree gets
  duplicated alpha material overrides; exit/model switch/teardown restores the
  original overrides and reset safely reapplies an active cab mode.
- SY205 now declares `tracks.local_forward_axis = +Z`; Jolt derives vehicle
  forward and right from that one model-space contract. Settled contacts prove
  left/right probes remain on their visual sides, while SY135 keeps the
  backward-compatible `-Z` convention.
- Product track keys are now Q/A for visual left forward/reverse and W/S for
  visual right forward/reverse; runtime input registration, HUD, onboarding,
  and evidence token checks agree.
- XInput gamepads now share those track actions through LT/LB on the visual left
  and RT/RB on the visual right. The equipment axes use the ISO excavator layout:
  left stick swing/arm and right stick boom/bucket. Canonical runtime registration
  removes the superseded bucket-trigger mapping rather than accumulating events.
- Human direction feedback is applied only to model-selected JoypadMotion
  events: SY205 reverses swing/boom/arm/bucket, while SY135 reverses only swing.
  ProductSession refreshes the profile on offline startup/model switch; all
  keyboard bindings, rig axes, and joint limits remain unchanged.
- `Test Grid` selects an explicit test presentation profile: Terrain3D textured
  presentation and native grass/rocks deactivate, shared site cues and soil
  particles drop to zero, and the unchanged accepted fallback terrain renders
  with a procedural texture-free black/white grid.

Focused code gates passed on 2026-08-24:

- `motion_client_test.gd`
- `operator_ui_test.gd`
- `camera_workflow_test.gd`
- `terrain_state_test.gd`
- `construction_site_terrain_test.gd`
- `terrain3d_adapter_test.gd`
- `visual_pass_test.gd`
- `jolt_chassis_track_test.gd`
- `tracked_chassis_locomotion_test.gd`
- `git diff --check`
- Trellis task validation

No screenshot or subjective visual review was performed by the assistant.

## Superseded evidence

The complete six-cell run at
`artifacts/benchmark/visual-baseline-after-raw/20260824T070829Z-0740dcc2/`
achieved all scripted scenarios but is not final after evidence: it used the
visually wrong SY205 positive-side bucket extension. A later run was interrupted
as soon as the user reported the direction error. Neither run may close the
human or final-matrix gates.

## User-directed closure

On 2026-08-25 the user explicitly requested commit, push, and archival and asked
that development not spend more time on assistant-led visual checks. The
focused automated journeys and code gates above are the accepted closure basis.
The following items are intentionally not represented as passing evidence:

- fresh human acceptance of the SY205 `-95/+30 deg` endpoints and ordinary O/L
  operation;
- fresh human acceptance of spawn direction, full-site support, panel collapse,
  QA/WS track semantics, Test Grid recovery, cab positions/transparency, and
  model-specific XInput directions;
- a replacement 34-artifact after matrix after the corrected SY205 endpoint.

These remain reusable manual-review prompts in `human-review.md`, not blockers
to the user-directed archival decision.
