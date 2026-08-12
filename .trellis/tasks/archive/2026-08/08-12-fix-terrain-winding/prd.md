# Fix Godot Terrain Triangle Winding

## Goal

Make the generated brown soil terrain visible from the normal above-ground camera while preserving Godot back-face culling and correct lighting.

## Background

Runtime diagnostics showed that `TerrainMesh` generates triangles whose index winding is rejected by Godot's default `CULL_BACK` material from above. Temporarily disabling culling makes the full soil surface visible, confirming an index-order defect rather than missing geometry or material data.

## Requirements

- Reverse the generated terrain triangle index order in `godot/client/scripts/terrain_renderer.gd` so Godot treats the top-facing soil surface as front-facing.
- Keep the terrain material back-face culled; do not use `CULL_DISABLED` as the fix.
- Preserve explicit vertex normals pointing upward for correct lighting.
- Add a regression test in `godot/client/tests/terrain_state_test.gd` that checks the first generated cell's six indices, winding direction, and upward vertex normals.

## Out Of Scope

- Terrain topology, dimensions, soil simulation, collider behavior, materials, camera setup, or unrelated scene/editor changes.
- Changes to the existing untracked Godot import/editor metadata.

## Acceptance Criteria

1. The first terrain cell uses the Godot-compatible order `top_left, top_right, bottom_left` and `top_right, bottom_right, bottom_left`.
2. The generated index triangles have a cross product with a negative dot product against `Vector3.UP`, while their stored vertex normals have positive Y.
3. With the normal runtime material (`CULL_BACK`), the brown soil surface is visible from the default above-ground view.
4. The terrain regression test and applicable Godot test suite pass.

## Open Questions

None.
