# Implementation plan

1. [x] Replace the single orbit state with four named, model-specific semantic-
       anchor presets and bounded transitions.
2. [x] Add read-only terrain/machine occlusion shortening, recovery, near-clip
       safety, quality clamping, and deterministic state/query seams.
3. [x] Add keyboard/gamepad camera actions, reset behavior, and generation/model
       transient cleanup without retaining freed anchors.
4. [x] Integrate active mode, selector, reset action, and centralized discovery
       copy into the operator HUD.
5. [x] Add a focused double-model camera workflow contract and retain offline/
       visual state compatibility.
6. [x] Run one completion verification gate, update the frontend boundary,
       commit, and archive. Defer subjective framing approval to final human
       product-experience validation.

## Risk and rollback

- Camera queries are read-only and must never change collision layers, masks,
  bodies, or terrain identity.
- Model activation invalidates every cached semantic frame before re-resolution.
- Collision-query absence fails open; preset and minimum-distance bounds remain
  valid without Terrain3D or a current terrain collider.
