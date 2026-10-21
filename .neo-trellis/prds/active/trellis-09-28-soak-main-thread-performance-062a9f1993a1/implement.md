# Checkpoint

User request: commit current workspace then use soak to attempt optimization (2026-09-28, current conversation). Main agent implementation only.

## Completed
- Committed entire reviewed initial workspace as a3172ff. Prior relaxed-assist test evidence reused; UID sidecars included. No push.
- Initial baseline FAIL: saved relaxed level assist intercepted input, slope view triangulation errors, no cut/load/dump. `output/soak-main-0928/baseline`. First attempt at editing isolation failed due Windows text decoding; unchanged redundant run interrupted and not used (`isolated-baseline`).
- Isolated operator UI preference path in runner BEFORE scene readiness. Production defaults unchanged. Clean run still no cut: recent doubled track calibration moved old input outside work zone. `clean-baseline` retained as invalid evidence.
- Added locomotion_calibration metadata from verified accepted revision 88c7184 rig to canonical recording; all original recording fields exactly unchanged. Existing runner calibration mechanism used, no solid-query bypass or product resource change. New SHA documented in fixture README.
- Valid calibrated baseline PASS, full 2521 commands no loops, max yaw divergence .03392 deg. `output/soak-main-0928/calibrated-baseline/report.json`. Complete frame rows excluding first: P95 11.635/P99 18.732/max35.726 ms; automatic total3762.476ms, soil total4640.008ms, publish max13.149ms. GPU P99 1.691ms. All report gates pass.
- BucketSoilTool caches private static local points/transforms/radius on configure, clears on reset/reconfigure; shares interpolated sweep transforms across regions while preserving all sample order and detached snapshot containers.
- Frozen pre-cache composition/radius oracle and new bucket_snapshot_cache_test: exact parity over 640 poses across SY135/SY80U/GB12 and reconfiguration, mutation isolation, invalid config/history/identity. PASS, exit0, log `output/soak-main-0928/cache-test.log`. Microbench 2000 snapshots legacy353451/current131535 usec (not scene FPS).
- Existing menu_preferences_test updated to use isolated preference path throughout model/map/theme roundtrips and assert real user config byte preservation. Not yet run.

## Final checkpoint
- Completed two caches and isolated soak preferences. Result/report: result.md; all numerical evidence/source SHA256: comparison.json. Raw logs/captures output/soak-main-0928.
- Fill probes found rebuild max9.13ms vs UI max.365ms. Exact fill-array cache parity PASS; microbench427138→332951usec/50. Final soak PASS: P95 11.989/P99 19.459/max38.292ms vs baseline11.635/18.732/35.726. CPU automatic -6.8%, soil total -4.2%; frame stability NOT improved. 0 frames>50ms. Report readiness1→2 timeouts and final pending blocks honestly; memory8.332% PASS, diagnostic-only run10.093% FAIL retained.
- PASS cache parity, tool semantics, relaxed assist, fill surface, SY80U geometry, GB12 geometry, menu preferences (fixed main_map separate reader), 8 backend evaluator tests, diff check. Peer read-only review no findings. Exact new code paths/hashes in comparison.json. No further tests necessary without edits.
- Next: hand off accurate outcome and limitations. New changes remain uncommitted; initial user-requested workspace commit a3172ff done. No push/export. Current scoped request complete; no subjective acceptance claimed.
