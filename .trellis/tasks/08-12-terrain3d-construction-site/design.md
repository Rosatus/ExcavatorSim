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

Project-owned deterministic code generates same-sized albedo-height and
normal-roughness textures. A control image encodes base/overlay/blend fields and
is imported alongside every derived height image. No production resource points
to `res://demo/**`.

## Logical patch vs visible site

The central disturbed-soil work pad is the interaction affordance. The outer
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
