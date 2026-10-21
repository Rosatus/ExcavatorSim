# Design — Terrain3D construction-site terrain and materials

## Architecture and boundaries

The existing one-way terrain flow remains intact:

```text
bucket command
  -> BucketSoilState / TerrainState
  -> accepted logical snapshot
  -> Terrain3DAdapter
  -> project-owned Terrain3D assets/materialization
  -> optional Jolt collision query
```

This task changes the authored visual terrain and material resources, not the
logical authority model.

## Production terrain shape

The site uses a 129 × 129 presentation grid at 0.5 m spacing, producing a
64 m × 64 m footprint. The central 41 × 41 logical patch is sampled directly
from `TerrainState`; every logical grid point remains exact. Outside that patch,
a deterministic presentation profile adds gentle grading, spoil piles/berms,
a haul-track approach, damp drainage ground, and grass transitions at the outer
edge.

The site should avoid buildings and decorative clutter that distract from the
excavation loop.

## Material strategy

The palette contains four Terrain3D texture slots:

0. disturbed soil / loose earth,
1. compacted haul track,
2. grass / undisturbed outer ground,
3. darker damp soil in the drainage low point.

The temporary visual baseline extracts the official demo's two texture assets
and `Terrain3DMaterial` into minimal production resources under
`res://assets/terrain/`. Projection, dual-scale, macro variation, auto-shader,
and world-background parameters retain their official values. The local control
map uses demo material ID 0 on the central pad/access route and ID 1 on the
surrounding ground.

The adapter reuses the official RockA/B/C meshes across three bounded
`MultiMeshInstance3D` layers. It also instantiates the official grass particle
scene with a project extension parameter, `exclusion_radius = 12.0`, so the
central work pad remains clear. None of these presentation objects add collision
or feed state back to `TerrainState`.

## Logical patch vs visible site

`TerrainState` algorithm `godot-terrain-state-v2-flat` initializes the central
logical surface at zero height. The flat work pad is the interaction affordance. The outer
haul track, piles, damp ground, and grass are visual context only. Their heights
are rebuilt from the accepted snapshot plus deterministic presentation
functions and are never copied back into `TerrainState`.

## Validation shape

The planning output should define:
- asset/resource ownership,
- scene/resource files expected to change,
- material placement rules,
- collision/adapter expectations,
- tests or smoke checks needed to prove the new site still respects authority
  boundaries.
