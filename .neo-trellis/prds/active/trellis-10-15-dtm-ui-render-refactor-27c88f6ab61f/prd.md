# DTM UI and rendering refactor

## Goal
Improve DTM dashboard readability and CPU cost without changing measurement semantics
(current SDF top surface, fixed metre color scale, cut/fill integration, cache identity,
pause ownership, P shortcut).

## Requirements
- Batched SDF column sampling with results identical to the per-point sampler.
- Map rendering: shaded 2.5D surface, opaque plan heatmap with hillshade, overlay
  for tooth markers so machine motion does not redraw the static map.
- Dashboard metric cards in both modes; drawn gradient legend; readable HUD backing.
- Additional selectable voxel/pixel chart theme, with stepped terrain, strata,
  discrete legend and persistent preference independent of application skin.

## Acceptance Criteria
- [x] dtm_test.gd and dtm_performance_test.gd pass.
- [x] Batched heights equal scalar reference on edited terrain.
- [x] Voxel theme switching, preference save, layout and cache regressions pass.
- [ ] Human visual review (floating/HUD, 1280x720 and 1920x1080) - pending.

## Progress
- Baseline: grid576 13.2 ms (23 us/point), dashboard120 25 ms, draw30 37 ms.
- Evidence: VoxelTool.copy cost jumps for buffers taller than 32 voxels; a 98x80x2
  row copy + byte decoding gives identical heights at ~2.5x speed.
- Done: sampler.heights_at, packed DtmModel row jobs, view rewrite (shaded iso surface + skirts, hillshade + contours, section soil body, overlay markers), dashboard cards + gradient legend, cached cutting contract, docs.
- After: grid576 batched 5.8 ms (scalar 12 ms), full grid 4.8 ms / 5 frames, section 0.4 ms one frame, dashboard120 13 ms. draw30 ~46 ms headless (mesh+band draw), static maps no longer redraw on tooth motion.
- Next: human visual review only.

## Recovery / voxel theme closeout (2026-10-15)
- Recovered the interrupted theme implementation in dtm_view.gd,
  dtm_dashboard.gd and operator_ui.gd; preserved earlier sampling refactor.
- Fixed Legend's Variant-derived float inference (prevented script compilation).
- Fixed pixel profile strata termination at fractional plot bottoms: clamp after
  rounding, so the fill loop always reaches the exact bottom boundary.
- Agent automated: dtm_test.gd PASS (exit 0), dtm_performance_test.gd PASS
  (exit 0), with no script errors. Added fixed-band, preference, independent UI
  skin, measurement-preservation, voxel cache/overlay and fractional-bottom checks.
- Current CPU evidence: scalar576 13.13 ms, batch576 4.36 ms, full grid 4.52 ms;
  four-chart draw30 terrain 46.89 ms / voxel 58.29 ms (headless, not GPU FPS).
- Human manual: pending subjective review of voxel theme at 1280x720 and
  1920x1080, floating/HUD, dug pit; P -> 方块风 -> HUD 模式 -> 地形风.
  Prior user praise accepts the earlier visual direction, not the new theme.
- Docs updated in docs/landxml-dtm.md. User authorized batched commits:
  1379bdc contains batch sampling and scalar parity coverage; adbd827 contains
  the model/dashboard rendering refactor, voxel theme and regression coverage.
  Documentation and task records are committed separately. No push requested.
  Do not archive as fully accepted until human review.
- Next: user visual review only; automated implementation closeout is complete.
