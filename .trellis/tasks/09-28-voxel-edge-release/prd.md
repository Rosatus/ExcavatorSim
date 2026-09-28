# Voxel edge cutting and outside release

Remove whole-sweep admission against inset editable bounds. Clip cut processing
to the actual finite voxel volume, including native synchronous and prepared
paths. Mesh collision/terrain ownership is unchanged. Permit normal gated
unloading outside the receiving region: debit bucket into an explicit exported
mass sink, without a voxel pile. Preserve exact accounting, stale identity and
simple-digging gates. Preserve unrelated map/HUD edits in this workspace.

Agent automated: focused cutter and authority edge/release tests, ledger checks,
and prepared-cut equivalence. Human manual: urban roadside excavation and dump
outside the strip, confirming intuitive reach and disappearing released soil.

Progress: implementation complete. Cutter intersects semantic voxel volume;
native sync edge edits and both prepared executors clip buffers, leaving the
interior native fast path intact. Support cleanup also respects the integer
ownership window for non-grid-aligned urban bounds. Outside the existing
editable receiving region, confirmed unloading directly exports at the usual
rate, cancels queued deposits, updates contained fill through release_changed,
and creates no terrain/stable-deposit VFX event. Explicit exported_dump_mass_q
balances the debit; in-zone deposit behavior is unchanged.

Agent automated PASS using pinned C:/apps/godot_voxel engine:
voxel_bucket_cutter_test; voxel_excavation_authority_test;
voxel_cut_preparation_test (failures=0); voxel_edge_release_test (failures=0).
The latter uses Urban's translated 15.8 x 5.55 m region and verifies roadside
cut, sync/sliced/threaded full sampled SDF + mass parity, untouched outside
apron, outside unload, exact sink balance, final residual draining and simple
digging inhibition. It was repeated after tightening cleanup ownership.
git diff --check passes. Logs: TEMP/voxel-edge-{cutter,authority,preparation,final}.log.

Human manual pending: restart Urban, cut its roadside soil in first person,
then swing over the road and dump. Expect reachable soil to cut and bucket fill
to drain without road piles. No commit/export requested; unrelated changes
were preserved. Next: user visual/control review, not more automatic matrices.

2026-09-28 repository housekeeping: user authorized grouped commits of current workspace changes. Implementation and existing validation records are retained; pending human review or unreproduced symptoms remain pending. Build outputs/caches stay under existing ignore rules.
