# Terrain3D restoration program — integration evidence

## Ordered phases

All five children completed their stop gates and are archived under
`.trellis/tasks/archive/2026-08/`:

1. `08-29-terrain3d-forwardplus-render-spike` — stable non-black Godot 4.7
   Forward+/D3D12 native frame.
2. `08-29-terrain3d-material-visual-parity` — project procedural soil on native
   and fallback; user accepted the Phase 1 visual result.
3. `08-29-terrain3d-snapshot-lifecycle-fallback` — incremental/full lifecycle,
   transactional fallback, one visible surface, and Test Grid restoration.
4. `08-29-terrain3d-authority-collider-regression` — SY205/SY135 native-vs-
   fallback terrain/ledger/payload/Jolt equivalence and project query provenance;
   native collision mode/layer remain zero.
5. `08-29-terrain3d-product-cutover-export-validation` — native product default,
   Advanced diagnostics, explicit rollback, real Windows export/package, and
   editor/export parity.

## Final product contract

- `TerrainWorld.terrain_backend` defaults to `terrain3d`; `soil_shader` is the
  explicit and automatic synchronized fallback.
- TerrainState, the selected soil ledger, TerrainCommitScheduler, Jolt, and the
  identity-matched project TerrainCollider remain authoritative. Terrain3D is
  copied-snapshot presentation only and native collision is disabled.
- Native and fallback use the approved project-owned procedural soil; no native
  grass, rocks, trees, foliage, demo background, navigation, or reverse mutation
  path was introduced.
- Test Grid remains a presentation-only black/white fallback override and
  transactionally restores the configured backend.

## Final evidence and gates

- Rendered probe: `output/terrain3d_phase4/forwardplus-final/run-summary.json`.
- Space-safe source/export/package/rollback parity:
  `output/terrain3d_phase4/release final spaced/run-summary.json`.
- Phase 4 details and package manifest:
  `.trellis/tasks/archive/2026-08/08-29-terrain3d-product-cutover-export-validation/evidence.md`.
- Focused terrain, adapter, authority, visual, and release tests passed. Full
  standalone progressed through all pre-Gateway Jolt/authority/telemetry gates
  and stopped at the pre-existing Gateway heartbeat failure.
- Ruff, Mypy, and all 182 backend tests passed. The aggregate verify command then
  hit the existing Windows pytest-temp symlink cleanup permission error.
  Provenance and standalone-path gates passed independently.
- Backend smoke could not start because the unrelated user-owned tracked
  `godot/dist/index.html` remains deleted; this task preserved that dirty state.
- Two independent final audits reported no blocking product defect. Their
  release-runner findings were fixed and the final spaced-path export rerun
  passed with no fatal log matches.

The documented baseline/environment exceptions do not intersect Terrain3D,
terrain authority, soil, Jolt, visual material, or exported-build behavior and
were not hidden or converted into passing assertions.
