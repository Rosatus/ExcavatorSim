# Parent implementation plan — Terrain3D restoration program

## Ordered child execution

1. Complete and archive `08-29-terrain3d-forwardplus-render-spike`.
2. Complete and archive `08-29-terrain3d-material-visual-parity`.
3. Complete and archive `08-29-terrain3d-snapshot-lifecycle-fallback`.
4. Complete and archive `08-29-terrain3d-authority-collider-regression`.
5. Complete and archive `08-29-terrain3d-product-cutover-export-validation`.

Each child owns its code, focused checks, work commit, archive commit, and
journal record. Later children may consume earlier output but must not amend or
silently weaken an earlier accepted contract.

## Parent integration gate

- Confirm all five children are completed and their exit evidence is linked.
- Compare the final diff against this parent PRD and architecture.
- Re-run the final full Godot standalone matrix, repository verification,
  provenance/standalone checks, Windows editor rendered smoke, and Windows
  exported-build smoke.
- Perform focused human review of the same checkpoint/model/camera/profile under
  native and fallback rendering. Pixel identity is not required; recognizable
  worksite-soil palette and composition are.
- Verify no Terrain3D collision, native grass/rock/tree dressing, demo gameplay,
  navigation, or reverse authority path entered the product.
- Update `docs/godot-integration.md` and frontend client-boundary spec with the
  final supported renderer/fallback contract.
- Commit parent integration documentation, archive the parent, and record the
  session only after every cross-child acceptance criterion passes.

## Stop/rollback gates

- Do not start Phase 1 if Phase 0 cannot produce a stable non-black native frame.
- Do not start Phase 3 if Phase 2 cannot prove one-visible-surface fallback.
- Do not cut over the default if native/fallback command sequences diverge in
  terrain bytes, ledger totals, payload, or Jolt truth.
- If Godot 4.7 compatibility requires a Terrain3D upgrade, return to Phase 0 and
  explicitly re-plan addon/API/binary/provenance scope before continuing.
