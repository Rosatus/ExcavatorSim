# Author Terrain3D construction-site terrain and materials

## Goal

Build a production Terrain3D presentation pass that turns the surroundings of
the excavator into a medium-scale earthwork site, with terrain forms and
surface materials appropriate for a soil-moving construction environment.

The desired outcome is a realistic, readable construction-site terrain that
uses Terrain3D for project-owned presentation assets and material distribution,
while preserving `TerrainState` and `BucketSoilState` as the logical
excavation authority.

## Background and confirmed facts

- Terrain3D is already enabled in `godot/client/project.godot` and the main
  scene already includes a `Terrain3DAdapter`.
- The current adapter still defaults to `res://demo/data/assets.tres`, which
  couples runtime terrain materials to the vendored demo dataset.
- Existing docs/specs already define Terrain3D as a derived presentation and
  optional collision backend, not a logical terrain authority.
- The current logical terrain is a small deterministic heightfield owned by
  `TerrainState`; accepted edits flow into renderer/collider backends after the
  logical snapshot is accepted.
- The user wants a medium construction site focused on earthwork, not buildings,
  with terrain zones that use appropriate materials such as soil and grass.

## Requirements

- R1 — Replace demo-coupled Terrain3D materials/assets with project-owned,
  deterministic construction-site terrain assets.
- R2 — Keep `TerrainState` and `BucketSoilState` as the only logical owners of
  terrain deformation and bucket volume. Terrain3D remains derived.
- R3 — Define the target site composition for a medium earthwork setting:
  excavated working area, spoil zones, access transitions, surrounding ground,
  and any restrained vegetation/grass boundaries needed for readability.
- R4 — Define a Terrain3D material palette and placement strategy appropriate
  for the site, including at minimum disturbed soil and grass/undisturbed edge
  conditions; additional materials must justify their value.
- R5 — Replace dependence on addon demo assets where they currently leak into
  the runtime path, or make any retained third-party asset dependency explicit
  and intentional.
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
- R10 — Use four bounded material roles: disturbed soil, compacted haul track,
  grass/undisturbed edge, and damp soil. Generate their textures from
  project-owned deterministic code so runtime no longer depends on demo assets.

## Acceptance Criteria

- [x] The running main scene presents a medium construction site with a central
      work pad, spoil piles/berms, a compacted access track, damp low ground,
      and grass at undisturbed outer edges.
- [x] Terrain3D exposes the four project-owned material roles and applies them
      through a deterministic control map.
- [x] Production runtime has no `res://demo/**` dependency.
- [x] The central logical patch matches accepted `TerrainState` samples while
      the surrounding site remains derived and non-authoritative.
- [x] Terrain snapshot guards, fallback rendering, bucket-volume accounting,
      and optional Jolt collision behavior remain green.
- [x] Procedural asset ownership and Terrain3D MIT provenance are documented.

## Key decisions

- The visible site is 64 m × 64 m; only the central logical patch is excavatable.
- The material palette is disturbed soil, compacted haul track, grass edge, and
  damp soil.
- Terrain textures and control maps are generated deterministically by
  project-owned code. Addon demo textures and scenes are not runtime inputs.

## Out of scope

- Replacing `TerrainState` with Terrain3D-native editing.
- Introducing buildings, full site infrastructure, or unrelated decorative
  worldbuilding.
- Expanding Python protocols or making physics authoritative for excavation.

## Implementation status

- Active Trellis task; implementation is approved.
- Blocking open questions: none.
