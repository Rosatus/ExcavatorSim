# Fine dirt 03 soil presentation

Use the user-provided Fab yd0jchk fine dirt 03 texture set for voxel soil.
Reuse its textures below the original surface with darker tint, roughness and
normal-strength variation, and a softly irregular depth transition. Small plant
marks may remain. No soil accounting, geometry or collision changes.

Use 2 m tiling and 2K runtime textures derived from the supplied 4K JPGs.
Keep bucket/release soil on the same texture family. Preserve preview clipping
and configured map origins; layers are presentation by original ground depth,
not tracked geological provenance of deposited material.

Agent automated: import/resource checks and focused material/visual contract.
Human manual: SY135 voxel map, inspect flat soil then excavate a 0.5 m deep cut;
check layer transition, wall normals and bucket soil under normal lighting.

Progress: implementation and automated checks complete; human appearance review
pending. No commit created. Unrelated pre-existing godot_ai/config/telemetry edits
were preserved.

Changed: fine03 textures/import settings/provenance, reproducible Pillow importer,
shared SoilVisualResources, bounded voxel shader and per-zone surface datum.
Shader preserves ownership clipping and slope preview; triplanar normal detail
is projected in world space so vertical cuts do not depend on mesh tangents.

Agent automated (Godot 4.7.2 custom Voxel Tools build):
- `voxel_soil_surface_material_test.gd`: PASS (exit 0), relocated datum/bounds,
  flat/starter profile, shader uniform parsing, texture size, packed roughness
  alpha after import, and local/world texture resource reuse.
- `soil_release_visual_quality_test.gd`: PASS (exit 0), stable deposit and shared
  bucket/release resource behavior.
- Scoped `git diff --check`: PASS.
- Source normal/height correlation supports OpenGL Y+ (see asset README).

The PowerShell import launcher did not return reliably and was interrupted after
its child exited; no successful import-process exit is claimed. Subsequent direct
Python subprocess Godot checks loaded the imported resources successfully and
verified their dimensions/alpha. Logs: material-check.log, release-check.log.

Human manual: accepted by user feedback on 2026-09-23. Representative check: start the usual SY135 voxel map; compare untouched surface,
a roughly 0.5 m deep excavation, vertical cut walls and bucket contents. Expect
the same dirt family, a subtle darker irregular depth transition and no inverted
normal highlights. Do not infer aesthetic approval from headless tests.

Next: no implementation work outstanding; archive with the authorized material commit. Depth-based presentation does not preserve geological
origin on deposited piles; no new provenance ledger was introduced.
