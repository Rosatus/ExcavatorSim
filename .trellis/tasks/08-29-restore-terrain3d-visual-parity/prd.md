# Restore Terrain3D while preserving current visuals

## Goal

Restore Terrain3D as a supported product terrain backend without changing the
accepted terrain/soil authority or regressing the current construction-site
look. The product should retain the current procedural brown-soil appearance,
Sky3D environment, shared construction-site dressing, and soil effects instead
of restoring Terrain3D's demo grass, particles, rocks, or green ground style.

## Background

- Terrain3D is installed, its editor plugin and GDExtension are enabled, and
  `Terrain3DAdapter` remains wired into `main.tscn`. It is not the current
  product presentation path because `TerrainWorld.terrain_backend` defaults to
  `soil_shader` (`godot/client/scripts/terrain_world.gd:12-14`).
- Commit `24a1d681eff91274d34be828b37d0036e9e90cbe` made that fallback the default
  after Terrain3D 1.0.2 rendered black surfaces under Godot 4.7. The standalone
  matrix still excludes `terrain3d_adapter_test.gd` for that reason
  (`godot/client/tests/run_standalone_matrix.ps1:33-36`).
- Current logical terrain is `TerrainState` (`stable_heights + loose_depth`).
  Accepted snapshots feed the project-owned `TerrainRenderer` and chunked
  `TerrainCollider`; the selected `SoilInteractionAuthority`/`ActiveSoilPatch`
  and `TerrainCommitScheduler` remain the excavation/material writers.
- Terrain3D has always been specified as a copied-snapshot derivative, never a
  gameplay authority. Editor sculpting or native map edits must not write back
  into `TerrainState`, bucket inventory, soil ledgers, or Jolt truth.
- The current visible soil material is a project-owned procedural shader in
  `terrain_renderer.gd:227-280`. Terrain3D 1.0.2 supports a material shader
  override, but the override must preserve Terrain3D's height/clipmap vertex
  logic; the fallback shader cannot be assigned unchanged.

## Requirements

### Authority and physics preservation

- Keep `TerrainState` and the generation-selected soil ledger as the sole
  terrain/material authority. Terrain3D consumes only accepted copied snapshots
  and cannot create a reverse mutation path.
- Keep `TerrainCommitScheduler` as the sole normal terrain revision writer and
  preserve snapshot generation/revision ordering, patch coalescing, full-resync,
  and fail-open behavior.
- Keep the project `TerrainCollider` as the Jolt chassis/bucket query provider.
  Terrain3D native collision remains disabled by default to prevent duplicate
  surfaces and contact ambiguity.
- Preserve all current excavation, active-soil, payload, locomotion, reset,
  model-switch, and telemetry semantics.

### Visual parity

- Preserve the current procedural worksite-soil palette and classifications:
  compacted/loose/damp soil, disturbed/slope response, track lanes, macro
  variation, roughness, and specular response.
- Preserve Sky3D, its single-sun/horizon contract, the project-owned
  `ConstructionSiteDressing`, current soil particles/clods, camera profiles,
  and visual-quality budgets.
- Do not enable Terrain3D demo grass particles, its grass/green ground material
  zone, or Terrain3D-owned rock dressing in the product profile.
- Keep Test Grid presentation texture-free and independent from terrain,
  collider, Jolt, and soil authority.

### Terrain3D restoration

- Resolve or bypass the Terrain3D 1.0.2/Godot 4.7 black-surface regression with
  a real Forward+ rendered-frame spike before changing the product default.
- Restore `terrain3d_adapter_test.gd` to the standalone matrix and replace the
  stale exclusion comment with executable regression coverage.
- Native startup, ordinary incremental cut/deposit revisions, reset/full
  resync, model switch, test-mode transition, and native failure must keep one
  valid visible terrain surface with no native/fallback flash or stale identity.
- Missing GDExtension, shader compilation/material failure, asset failure, or
  native map update failure must automatically retain/restore the current
  project renderer and collider without affecting simulation state.

### Diagnostics and compatibility

- Expose enough backend/material/dressing status to prove which renderer is
  active, which snapshot identity is applied, and why native activation failed.
- Keep the current Terrain3D 1.0.2 adapter API compatible unless the rendering
  spike proves that a plugin upgrade/rebuild is required. Any upgrade must be
  isolated and include Windows/exported-build evidence.

## Acceptance Criteria

- [ ] Normal product startup uses the approved Terrain3D mode and renders a
  non-black terrain on the Godot 4.7 Forward+ target.
- [ ] The rendered ground retains the current procedural brown worksite-soil
  appearance within focused human visual review; Sky3D, shared dressing, soil
  effects, and camera composition remain visually unchanged.
- [ ] No Terrain3D grass particles, green/grass ground zone, native rock
  dressing, tree layer, or native infinite background appears in the product
  profile.
- [ ] `TerrainState` bytes/digest, terrain generation/revision, selected soil
  ledger totals, bucket payload, and Jolt truth are identical with native
  presentation enabled versus the fallback for the same command sequence.
- [ ] Ordinary excavation revisions use incremental Terrain3D patch updates;
  reset/generation changes use one full materialization; queued/stale work
  cannot replace a newer surface.
- [ ] Terrain3D collision remains off by default and all accepted chassis/bucket
  terrain queries continue to use the identity-matched project collider or the
  authoritative heightfield fallback.
- [ ] Native unavailable/material failure/map-update failure restores the
  current fallback renderer without a simulation stop, authority mutation, or
  stale visible surface.
- [ ] Test Grid hides native presentation and all dressing, shows the current
  authoritative black/white fallback grid, and restores the prior product
  backend afterwards.
- [ ] `terrain3d_adapter_test.gd`, construction-site, terrain-state/collider,
  excavation/soil, Jolt, visual, offline/model-switch, release-candidate, full
  standalone, and repository verification gates pass.
- [ ] A Windows exported-build smoke proves the same non-black material,
  deformation update, fallback, and shutdown behavior as the editor build.

## Out of Scope

- Making Terrain3D editor sculpting a runtime gameplay input.
- Replacing `TerrainState`, `TerrainCommitScheduler`, the selected soil ledger,
  or the project `TerrainCollider` with Terrain3D-owned state.
- Enabling Terrain3D grass, foliage, trees, native rocks, navigation, demo UI,
  demo gameplay, or infinite world background.
- Redesigning the current construction-site palette, Sky3D, site props, soil
  particles, bucket physics, or excavation material model.

## Key Decisions

- “Terrain3D online” means the native Terrain3D surface is the actual visible
  product terrain renderer. Background-only materialization is not an accepted
  final state.
- Terrain3D remains a one-way copied-snapshot derivative. `TerrainState`, the
  selected soil ledger, `TerrainCommitScheduler`, and the project
  `TerrainCollider` retain their current authority.
- The current project-owned procedural worksite-soil appearance is ported into
  a Terrain3D-compatible shader override. Terrain3D demo grass, green ground,
  particles, rocks, trees, and world background stay disabled.
- Work is delivered through five ordered child phases. No later cutover phase
  may waive an unmet earlier exit gate.
