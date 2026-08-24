# Product usability and visual experience polish

## Goal and user value

Turn the technically functional Godot/Jolt excavator simulation into a coherent,
learnable operator experience whose construction-site presentation, camera,
machine feedback, soil interaction, and recovery flow feel intentional for both
SY205 and SY135. A first-time user should be able to understand what to do,
operate the machine, excavate, carry, dump, and recover without debug seams or
outside instructions.

## Confirmed product baseline

- The default product path is offline Godot/Jolt and activates SY205 without a
  Python service (`godot/client/project.godot:37-53`,
  `godot/client/tests/offline_product_test.gd:26-36`).
- The production HUD exposes architecture diagnostics and F6/F7/F8, but not the
  track, work-equipment, or camera controls
  (`godot/client/scripts/operator_ui.gd:135-182`,
  `godot/client/scenes/main.tscn:284-318`).
- The only camera is a single mouse-orbit rig with one shared framing profile and
  no occlusion handling (`godot/client/scripts/camera_rig.gd:1-65`).
- The site has deterministic Sky3D/quality profiles and procedural terrain, but
  limited dressing and a single-color fallback material
  (`godot/client/scripts/construction_site_terrain_profile.gd:81-101,141-157`,
  `godot/client/scripts/terrain_renderer.gd:212-219`).
- Soil feedback uses spherical particles/clods and an unshaded procedural bucket
  fill (`godot/client/scripts/soil_effects.gd:74-148,210-361`). There is no
  runtime audio player or product audio asset outside editor addons.
- Existing screenshot automation emits artifacts but does not evaluate visual
  quality (`godot/client/tests/visual_evidence_capture.gd:7-75,132-148`).

## Requirements

### R1 — Evidence-led iteration

Establish reproducible before/after evidence for both models across low,
balanced, and high quality. The core matrix covers carry, dump, terrain, and
bucket-ground support; balanced additionally covers the complete operator
journey. Every material visual change must map to an observed journey defect and
retain comparison evidence, metadata, error-log outcome, performance data, and
an acceptance rationale.

### R2 — Learnable operator flow

Replace diagnostic-first presentation with a product information hierarchy:
clear startup state, model identity, essential controls, current action/state,
bucket payload/soil feedback, warnings, and recovery. Keep advanced diagnostics
available behind an explicit toggle.

### R3 — Operational camera

Provide stable, discoverable operator, chase/orbit, work-tool, and inspection
views with model-specific framing, consistent switching, reset behavior,
mouse/keyboard/gamepad support where applicable, and collision/occlusion safety.

### R4 — Coherent construction-site presentation

Improve terrain material readability, lighting/atmosphere, composition, scale
cues, props, and machine-ground integration while keeping the terrain authority
and deterministic fixed-time visual baseline unchanged.

### R5 — Credible action feedback

Make drivetrain, hydraulics, digging, soil capture/carry/spill/settle, impacts,
warnings, and lifecycle changes readable through bounded visual effects and an
audio mix. Effects consume existing authoritative state and never become a new
simulation authority.

### R6 — Double-model product quality

Every operator journey and evidence gate must run on SY205 and SY135. Shared UI,
camera, effects, and site systems may use model-specific presentation contracts
but may not assume SY205 geometry or linkage behavior.

### R7 — Performance, compatibility, and provenance

Balanced quality targets 60 FPS at 1920×1080 on the development machine during
the standard dig/carry/dump journey. Existing fixed-step physics budgets,
offline operation, optional gateway behavior, quality profiles, reset/model
generation boundaries, asset provenance rules, and the standalone test matrix
must remain intact.

## Acceptance criteria

- [ ] A versioned before/after evidence matrix covers SY205/SY135 ×
      low/balanced/high × carry/dump/terrain/bucket-ground-support at 1080p;
      balanced additionally covers startup, controls-visible, travel, dig, and
      reset/recovery. Every cell records commit/model/profile/resolution,
      error-log outcome, and comparable performance data.
- [ ] A first-time evaluator can discover the essential controls and complete
      start → travel → dig → carry → dump → reset in at most five minutes without
      source code, debug controls, or external documentation.
- [ ] The default HUD leads with operator-relevant state; epoch, revision, ACK,
      penetration, and other engineering diagnostics are absent until the user
      opens advanced diagnostics.
- [ ] Four camera workflows are usable on both models, retain the machine/work
      area in frame, recover deterministically, and do not clip through terrain
      or the excavator during the acceptance journey.
- [ ] The construction site communicates scale and work zones, terrain types are
      visually distinguishable, and no required product presentation depends on
      an optional Terrain3D success path.
- [ ] Digging, carrying, dumping, settling, hydraulics, drivetrain, impacts,
      warnings, pause, and reset have coherent, rate-limited feedback; muting
      audio does not remove required visual/state information.
- [ ] Balanced 1080p acceptance journeys sustain the 60 FPS target without
      violating existing fixed-step budgets; low/balanced/high profiles retain
      explicit effect, shadow, camera, and audio budgets.
- [ ] SY205 and SY135 product journeys, Godot standalone matrix, `pixi run verify`,
      task validation, provenance checks, and visual review all pass.

## In scope

- Godot product UI/onboarding, camera, site dressing/materials/lighting,
  presentation-only soil/VFX/audio, evidence capture, quality profiles, tests,
  specs, and provenance records.
- Small presentation telemetry additions derived from existing authoritative
  state when required for readable feedback.

## Out of scope

- Replacing either excavator GLB, rewriting Jolt/terrain authority, changing
  excavation physics to hide visual defects, multiplayer, VR, dynamic weather or
  day/night simulation, backend protocol redesign, and a new mission/economy
  system.
- Photorealism at the cost of deterministic operation or the balanced quality
  target.

## Key decisions and deferred items

- Optimize the complete operator journey before decorative breadth.
- Keep fixed daytime as the reproducible baseline; atmosphere polish may improve
  that baseline but dynamic time/weather is deferred.
- Prefer code-native/procedural presentation and already-provenanced assets;
  every new external asset requires provenance before integration.
- Pixel-perfect screenshot thresholds are deferred until the baseline task has
  measured nondeterminism; human visual review remains a required gate.
