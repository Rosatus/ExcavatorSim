# Terrain3D product cutover and export validation

## Goal

Make the approved native Terrain3D presentation the product default, retain the
explicit synchronized fallback, and produce release-grade editor/export evidence.

## Dependencies

All Phase 0–3 child tasks must be completed and archived with passing exit
evidence. This phase may not waive a previous stop gate.

## Requirements

- Change the product default to the approved visible Terrain3D backend while
  retaining an explicit `soil_shader` fallback/configuration path.
- Preserve automatic fail-open selection and actionable backend/material/
  identity/fallback diagnostics in product UI or existing advanced diagnostics.
- Verify Test Grid disables native presentation/dressing and restores the
  configured backend after exit.
- Validate Windows editor and exported build on the declared Godot 4.7
  Forward+/D3D12 target: startup, non-black material, cut/deposit deformation,
  reset/model switch, forced fallback/recovery, Test Grid, and shutdown.
- Run full standalone, backend/repository, provenance, standalone-path, packaging,
  and release-candidate gates; document existing unrelated baseline failures
  without suppressing new regressions.
- Update integration docs, frontend spec, packaging/provenance, and operator
  diagnostics to describe the final native/fallback contract.
- Preserve a low-risk rollback that restores `soil_shader` as default without
  data migration or authority change.

## Acceptance Criteria

- [x] Main product startup selects native Terrain3D and renders a non-black
  project-soil surface with no demo vegetation/dressing/background.
- [x] Editor and exported Windows build agree on backend/material/applied identity
  and pass deformation, reset, model-switch, failure/recovery, and shutdown smoke.
- [x] Forced native failure automatically exposes the synchronized fallback and
  reports a bounded actionable reason while simulation continues.
- [x] Test Grid is presentation-only and restores native after successful resync.
- [x] Full deterministic, Jolt, terrain, soil, visual, offline, model, telemetry,
  release, packaging, and repository verification gates pass.
- [x] Focused human review accepts current visual composition/material continuity.
- [x] Documentation and specs state Terrain3D is visible presentation only,
  project collision/authority remain unchanged, and fallback is supported.
- [x] Parent integration acceptance has complete linked evidence.

## Out of Scope

- New Terrain3D collision authority, editor sculpt gameplay, vegetation system,
  new art direction, Linux release certification, or terrain data migration.
