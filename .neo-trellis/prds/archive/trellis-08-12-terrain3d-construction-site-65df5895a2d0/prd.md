# Author Terrain3D construction-site terrain and materials

## Goal

Build a production Terrain3D presentation pass that turns the surroundings of
the excavator into a medium-scale earthwork site, with terrain forms and
surface materials appropriate for a soil-moving construction environment.

The desired outcome is a realistic, readable construction-site terrain that
temporarily uses the official Terrain3D demo visual stack while preserving
`TerrainState` and `BucketSoilState` as the logical excavation authority.

## Background and confirmed facts

- Terrain3D is already enabled in `godot/client/project.godot` and the main
  scene already includes a `Terrain3DAdapter`.
- The adapter intentionally uses an extracted minimal copy of the official demo
  assets and material parameters as the current reviewed visual baseline.
- Existing docs/specs already define Terrain3D as a derived presentation and
  optional collision backend, not a logical terrain authority.
- The current logical terrain is a small deterministic heightfield owned by
  `TerrainState`; accepted edits flow into renderer/collider backends after the
  logical snapshot is accepted.
- The user wants a medium construction site focused on earthwork, not buildings,
  with terrain zones that use appropriate materials such as soil and grass.

## Requirements

- R1 — Reuse the official Terrain3D demo materials, shader configuration,
  macro background, grass particles, and rock assets as a bounded visual layer.
- R2 — Keep `TerrainState` and `BucketSoilState` as the only logical owners of
  terrain deformation and bucket volume. Terrain3D remains derived.
- R3 — Define the target site composition for a medium earthwork setting:
  excavated working area, spoil zones, access transitions, surrounding ground,
  and any restrained vegetation/grass boundaries needed for readability.
- R4 — Define a Terrain3D material palette and placement strategy appropriate
  for the site, including at minimum disturbed soil and grass/undisturbed edge
  conditions; additional materials must justify their value.
- R5 — Keep the retained demo dependency explicit, intentional, and covered by
  provenance and runtime tests.
- R6 — Preserve current runtime authority boundaries, snapshot gating, and Jolt
  collision semantics.
- R7 — Define how the production terrain remains compatible with the current
  deterministic logical grid, including how the visible surrounding site relates
  to the excavatable logical patch.
- R8 — Record provenance, packaging, and validation requirements for the chosen
  materials/textures/resources.
- R9 — Materialize a 64 m × 64 m visible site at the current 0.5 m spacing.
  The central 20 m × 20 m logical patch must reproduce the accepted
  `TerrainState` surface exactly; the surrounding terrain is disposable visual
  context and may not become excavatable authority.
- R10 — Temporarily use the official Terrain3D demo assets and material stack
  as the reviewed visual baseline instead of maintaining custom procedural
  construction textures.
- R11 — Keep the official demo grass particles outside a 12 m central exclusion
  radius so the excavator starts on a clear work pad.
- R12 — Reuse the official demo RockA/B/C assets as bounded, collision-free
  presentation outside the logical excavation rectangle.
- R13 — Initialize the logical `TerrainState` baseline as a true zero-height
  plane while preserving stable/loose editing, reset, and volume contracts.

## Acceptance Criteria

- [x] The running main scene presents a medium construction site with a central
      flat work pad, surrounding earth forms, an access route, official rocks,
      and demo grass outside the protected work area.
- [x] Terrain3D loads the official demo bare-ground and grass texture roles and
      applies them through a deterministic control map.
- [x] The intentional official demo production dependencies are reduced to the
      required textures and rocks, documented, and regression-tested.
- [x] The central logical patch matches accepted `TerrainState` samples while
      the surrounding site remains derived and non-authoritative.
- [x] Terrain snapshot guards, fallback rendering, bucket-volume accounting,
      and optional Jolt collision behavior remain green.
- [x] Terrain3D and official demo asset provenance are documented.
- [x] The running main scene uses the official Terrain3D demo assets, material
      configuration, macro terrain background, grass particles, and rocks.
- [x] The excavator starts on a flat logical pad with a 12 m grass exclusion
      radius; official rocks remain outside the logical excavation rectangle.

## Key decisions

- The visible site is 64 m × 64 m; only the central logical patch is excavatable.
- The active material palette is the official demo bare-ground and grass pair;
  deterministic control-map placement keeps the logical pad and access route bare.
- The official Terrain3D demo visual stack is an intentional temporary baseline;
  production packaging retains only the required textures, rocks, and extracted
  material parameters until a separately approved art pass replaces it.
- Demo terrain heights are never imported as logical state; only its assets,
  material configuration, rocks, particles, and macro background are reused.

## Out of scope

- Replacing `TerrainState` with Terrain3D-native editing.
- Introducing buildings, full site infrastructure, or unrelated decorative
  worldbuilding.
- Expanding Python protocols or making physics authoritative for excavation.

## Implementation status

- Active Trellis task; implementation is approved.
- Blocking open questions: none.
