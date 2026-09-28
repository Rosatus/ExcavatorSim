# Soak optimization result — 2026-09-28

## Outcome
Initial workspace committed as **a3172ff**. New optimization changes remain uncommitted; no push/export. Reduced repeated CPU work with exact geometry/mesh parity, but **did not demonstrate better frame stability**. Do not claim a FPS gain or locked 60 FPS.

## Comparable experiment
SY135, normal soil interaction, balanced Forward+/D3D12, RX9070XT, recorded 1920×1080 viewport, VSync/FPS cap off, 5s settle then the sole accepted 2521-tick trace once. All complete capture frame rows are included except the first partial interval, regardless of focus (automated input bypasses focus). Frame intervals include scheduling/waits; CPU/GPU stages overlap and must not be summed.

Two invalid initial attempts are preserved: saved relaxed leveling intercepted input, then the newer doubled track speed drove the old recording outside the work zone. Neither cut/carried/dumped, so their fast frame times are not performance baselines. A redundant unchanged attempt after a failed text edit was interrupted, not used.

The runner now uses a fresh operator preference file including its explicit ground mode; the map's startup reader uses that same path. Production defaults remain `user://operator_ui.cfg`. Canonical trace gained only locomotion calibration metadata copied from accepted revision 88c7184; all old fields/commands/observed positions remain identical. Product rig resources and work speed unchanged. No collision bypass, input-loop change, geometry simplification or quality reduction. Trace SHA256: `12658fa3ea4934cb090fbfbd0db1b30aaf34b99f87f12e4e140569278eee3e28`.

## Final comparison
Each column is one representative run, not a repeated-run mean. Raw reports/captures/logs are in `output/soak-main-0928/calibrated-baseline` and `final`. Full numbers/source hashes are in comparison.json.

| Metric | Baseline | Final |
|---|---:|---:|
| Frame interval P95 | 11.635 ms | 11.989 ms |
| Frame interval P99 | 18.732 ms | 19.459 ms |
| Maximum frame interval | 35.726 ms | 38.292 ms |
| Frames >33.3 ms | 3 | 4 |
| Frames >50 ms | 0 | 0 |
| Automatic interaction cumulative | 3762.476 ms | 3507.387 ms |
| Soil main-thread cumulative | 4640.008 ms | 4444.365 ms |
| Publication peak | 13.149 ms | 12.881 ms |
| GPU P99 | 1.691 ms | 1.697 ms |
| Memory growth after settle/capture start | 8.295% | 8.332% |

Automatic interaction fell 6.8%, soil CPU total 4.2%; frame tails worsened slightly. Async completion/merging changes transaction counts (last sampled commits 204→205), so whole-scene runs are not asserted to have identical terrain trajectories. Frozen deterministic regressions establish algorithm equivalence.

## Changes and attribution
- BucketSoilTool caches private configured local sample points, transforms and maximum radius; computes each swept bucket pose once for all regions. Reset/model/attachment changes invalidate caches, returned containers remain detached. 2000-call isolated benchmark: 353451→131535 usec (~63% reduction).
- Diagnostic-only subclasses in `output/soak-main-0928/probes` split listeners: effects callback max9.36ms, fill rebuild max9.13ms; UI max0.365ms. This supports optimizing mesh generation rather than altering signal/event cadence. These probes are not installed in production.
- BucketFillSurface reuses grid samples and per-build x/z appearance computations, retaining per-face underside normals and exact arrays. Cache clears each build; mesh density and refresh cadence unchanged. 50-build isolated benchmark: 427138→332951 usec (~22% reduction).
- Cache-only intermediate run passed; diagnostic probed run failed memory ratio at10.093%. This is retained rather than hidden. Final normal driver passed all current gates; the 42s test does not prove leak freedom.

## Verification
Agent automated PASS (exit0; logs under `output/soak-main-0928`):
- bucket_snapshot_cache_test: 640 exact old/new snapshots across SY135/SY80U/GB12, stationary/rotating/translated/discontinuous sweeps, caller mutation isolation, tool switches, failed configuration/history/identity.
- bucket_fill_cache_test: exact vertex/normal/color/index arrays at empty/tiny/quantized/arbitrary/reverse/refill levels across SY135/SY205/SY80U/GB12 and tool switches.
- bucket_soil_tool_test; relaxed_surface_assist_test; bucket_fill_surface_test; sy80u_bucket_soil_test; gb12_soil_test.
- menu_preferences_test: persisted controls survive model/map/theme changes using an isolated file; real user preference existence/bytes unchanged. Initial failure exposed main_map's separate hard-coded path, fixed and passed.
- Backend soak evaluator: 8 pytest tests passed; git diff --check clean.
- Read-only peer review: no actionable findings; frozen changed methods match prior source, trace original fields unchanged, calibration matches historical rig.

Final replay consumed2521 inputs, no loop/model mismatch, active cut/carry/dump, max stock1056kg. At4Hz observation, queue max2/oldest4ticks, conservation error always0, no queue_full, tail preparation idle. Worker maximum latency41.1ms. Main-side preparation observed maximum3.285ms; configured3ms budget is not a hard wall-time guarantee.

Human manual: no subjective visual/control-feel acceptance claimed; exact output-array checks cover this optimization's geometry preservation. No visual screenshot/export matrix run.

## Remaining limits
Readiness timeout count1→2; final4 pending readiness records and27 visual/collision pending blocks with fallback retained. Existing derived collision lag is unresolved. No engine errors in valid baseline/final logs; existing Terrain3D deprecation and external CAN port warning remain. Unexplained frame interval outside the measured stages remains the next profiling target. Further work should split engine/harness wall time and collision readiness; these results do not justify a broad C++ migration or lowering physics/sample quality.
