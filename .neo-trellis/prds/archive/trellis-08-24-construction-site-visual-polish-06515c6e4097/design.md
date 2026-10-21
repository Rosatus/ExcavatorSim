# Design — construction site visual polish

## Shared site identity

`TerrainState` and the selected soil authority remain the only terrain/material
truth. Terrain3D and `TerrainRenderer` consume accepted snapshots; a new
`ConstructionSiteDressing` consumes the same snapshot only to place disposable,
non-colliding scale cues. The dressing is a sibling of both render backends so
native success/fallback cannot produce different work-zone identity.

The central logical patch stays byte-identical. Context height, material zones,
and deterministic dressing layout remain in `ConstructionSiteTerrainProfile`.
Active-patch and stable/loose edits affect presentation only through their
accepted terrain snapshots; no shader, prop, mark, or effect writes material.

## Worksite composition

Code-native mesh primitives establish a clear perimeter, dig-face stakes, haul
route markers, warning barriers/signage, track context, and stored pipe/aggregate
scale cues. All transforms are deterministic and height-sampled from the shared
construction-site presentation map. Props occupy an exclusion ring outside the
10 m logical excavation patch and avoid the positive-X haul corridor.

Every prop is a `GeometryInstance3D` with no collision node, layer, mask, or
physics body. Quality profiles select bounded subsets and shadow policy without
changing placement identity.

## Terrain and lighting presentation

The fallback mesh uses a procedural spatial material driven by accepted height,
slope, and world position to distinguish compacted base, disturbed/loose soil,
damp lows, and macro breakup at near/far distance. It uses no external asset and
does not infer material volume. Terrain3D retains its provenanced CC0 ground
textures and shared material-zone map; both paths keep matching earth/damp/
vegetation roles.

Fixed 10:30 Sky3D remains the reproducible baseline. Profile tuning may adjust
ambient/SSAO, sun/contact shadows, atmosphere, and exposure only within the
existing single-sun boundary, keeping yellow machine silhouettes separate from
the earth palette.

## Quality budgets

Low keeps primary barriers/stakes with no prop shadows; balanced adds route
marks and stored materials with bounded shadows; high enables the complete
deterministic set. Each profile publishes prop, shadow, and material budget
telemetry through `VisualQualityController` and the dressing snapshot.

## Validation strategy

Extend deterministic construction-site and visual-state contracts for zone
layout, prop counts/transforms, collision absence, quality budgets, shared
backend visibility, shader material identity, and reset/model invariance. Run
one completion verification gate. Subjective screenshots and composition
approval remain a focused human gate in final product-experience validation.
