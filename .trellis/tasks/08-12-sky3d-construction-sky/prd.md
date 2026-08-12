# Integrate Sky3D construction-sky environment

## Goal

Introduce a more convincing construction-site sky and atmospheric environment by
evaluating and integrating the locally downloaded Sky3D addon in a way that
fits ExcavatorSim's existing Godot presentation contracts.

The desired outcome is a restrained, realistic sky treatment for the excavator
scene that improves horizon, light, fog, and cloud quality without creating a
new gameplay authority, changing motion/terrain cadence, or breaking the
existing scene/test seams.

## Background and confirmed facts

- The local Sky3D addon is present at `godot/client/addons/sky_3d/` and reports
  version 2.1 in `plugin.cfg`.
- Sky3D is not a plain sky material. It is a `WorldEnvironment`-based addon with
  integrated sky, sun/moon, fog, cloud, and time-of-day controls.
- The current main scene already contains a root `WorldEnvironment`, a root
  `KeyLight`, and project-owned `VisualEnvironment` and
  `VisualQualityController` nodes.
- Current visual contracts require quality changes to remain presentation-only.
  They may not alter authoritative motion state, terrain bytes, bucket volume,
  or deterministic cadence.
- Existing tests assert the presence of `WorldEnvironment`, `KeyLight`,
  `VisualEnvironment`, and `VisualQualityController` in the main scene.
- Sky3D's README assumes removing an existing `WorldEnvironment` and adding a
  new `Sky3D` node, which conflicts with the current main-scene contract.

## Requirements

- R1 — Produce an evidence-backed integration plan for Sky3D under the existing
  Godot client boundary, including what parts of the addon are adopted,
  adapted, or rejected.
- R2 — Keep the visual layer presentation-only. Sky, fog, cloud, exposure, and
  light changes must not change Python authority, local terrain authority,
  bucket inventory, or simulation cadence.
- R3 — Preserve the main-scene structural seam required by current tests, or
  update those tests only if the new structure remains equally explicit and
  stable.
- R4 — Decide whether Sky3D is used as:
  - a full scene-environment replacement,
  - a partial runtime component under project wrappers,
  - an isolated prototype/reference implementation,
  - or not adopted.
- R5 — If Sky3D is adopted, define how quality profiles (`low/balanced/high`)
  continue to govern environment cost and how runtime/editor enablement is
  handled.
- R6 — Record any third-party asset/license/credit obligations introduced by
  Sky3D and the chosen project-owned asset scope.
- R7 — Avoid direct dependence on addon demo scenes in production scene data.

## Acceptance Criteria

- [ ] A written decision states whether Sky3D is adopted for the main excavator
      scene, and at what integration depth.
- [ ] The chosen plan preserves or explicitly replaces the current
      `WorldEnvironment` / `KeyLight` / `VisualEnvironment` /
      `VisualQualityController` contract with stable runtime seams.
- [ ] Quality-profile behavior remains presentation-only and testable.
- [ ] Any Sky3D-specific time, fog, light, or cloud behavior is bounded and
      documented as visual-only.
- [ ] Licensing/provenance requirements for shipped Sky3D assets are recorded.
- [ ] The task ends with an implementation-ready plan rather than an ad hoc demo
      splice.

## Key decisions to resolve

- Whether the project should integrate full Sky3D runtime behavior or only
  borrow a constrained subset that fits existing presentation boundaries.
- Whether the main scene keeps the current `WorldEnvironment` shape or moves to
  a project-owned wrapper around Sky3D.
- Whether construction-site realism needs dynamic time-of-day, or only a fixed
  daytime sky tuned for earthwork visuals.

## Out of scope

- Changing Python protocols, motion authority, terrain authority, or bucket
  accounting.
- Turning Sky3D into a gameplay, replay, or wall-clock authority.
- Implementing nighttime gameplay or a general weather system unless a later
  task explicitly broadens scope.

## Planning status

- Complex task: `prd.md`, `design.md`, and `implement.md` required before
  activation.
- Blocking open questions: none for planning; the task's purpose is to converge
  the Sky3D integration shape before implementation.

