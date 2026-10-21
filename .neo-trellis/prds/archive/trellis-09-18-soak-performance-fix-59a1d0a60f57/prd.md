# 60-second recorded soak performance diagnosis

User authorizes automated 60s soak replay, added probes, bottleneck fixes and comparable verification. SY135/balanced/normal; manual-dig-sy135-balanced-normal-90s-turn180.json. Preserve soil semantics and unrelated changes. No graphics reduction or bypass modes as fixes.

Acceptance: measured hot work; correctness-preserving fix; focused regressions and same-setting rendered replay comparison; honest remaining failures. Subjective human review separate.

Progress: output/soak-bottleneck/baseline.json complete (60s total,5s warmup), FAIL render_frame_p99 (46.948ms) and memory_growth_ratio. Cutter phase clocks and support_cleanup appended to capture. Instrumented replay output/soak-bottleneck/probed.json in progress. No optimization yet. Subagent dispatch failed due model configuration.

Next: inspect phases, optimize, focused checks, compare. Commands use .pixi/envs/default/python.exe with PYTHONPATH=backend/src, non-login PowerShell. Sidecars output/soak-bottleneck/performance-captures.


Completed this scoped latency fix (uncommitted): cutter contact combines duplicate contiguous rounded-Y column intervals, preserves first-eight early exit and deep32 sparse samples; cleanup bulk reads signed16 SDF and writes only deleted cells. Appended six recorder columns/analyzer labels/docs; cutter_contact probe now includes rejected no-contact cases (initial probe baseline undercounts these). Final bookkeeping clears phase sample before each world tick to prevent stale attribution when submission is skipped; replay soil was automatic and valid, so this does not change measured optimization behavior.

Evidence: output/soak-bottleneck/report.md and baseline/probed/fixed JSON plus separate capture sidecars and analysis. 60s total5s warmup. P99 47.102->32.923ms, max168.160->87.089, >100ms22->0, >50ms110->48. P95 regressed8.889->11.436; FPS effectively same. Cleanup1298.6->261.2ms; totalsoil10595.1->9086.7ms. Baseline357 transactions(315cut42deposit), fixed355(311cut44deposit);3287->3300 measured physical steps. Same input is not identical terrain trajectory. Fixed render gates PASS; overall remains FAIL memory ratio10.0698% threshold10% (baseline11.0149%); no claim all gates pass/no leak. Short replay uses allow-incomplete-scenario. Original CAN port warning persists.

Tests PASS: voxel_lift_contact_performance_test (scalar probe-set equivalence at two scales, rotations/depths including capped columns;421recorded frames); voxel_support_cleanup_test; performance_capture_test (including added phase accumulator/drain assertions); analyzer4tests5subtests. No further full suites needed. Human subjective play review not performed. No commit requested. Remaining investigation if requested: memory growth and residual coverage/native-edit cost; no extra soak merely to chase a green aggregate.
