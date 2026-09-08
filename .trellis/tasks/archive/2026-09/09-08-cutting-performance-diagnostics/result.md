# Result

Implemented the accepted first optimization pass and an Advanced `切削性能诊断` CheckButton. Default off; live toggling preserves terrain, inventory, transaction IDs/events and pending collision work. Enabled diagnostics aggregate at most four times per second; toggling starts fresh timing windows. Runtime visual/audio reads no longer construct full voxel status. Native optional digest sampling is skipped when off; exact-path validation remains active.

Native coverage now uses precomputed decimal-lexical rank keys and a reusable tight SDF read buffer. The sampling stencil, admission/result caps and legacy ordering are unchanged. No voxel-scale, cadence, collision-range or quality changes were made.

## Agent automated evidence

Engine: Godot 4.7.2 custom build / Voxel Tools 1.7, verified local toolchain.

Passed:
- `voxel_cutting_performance_test.gd`: diagnostics off/on, zero off-mode native sampler calls, full edit-window SDF equality, exact ledger/queue/cadence equality, detached visual/cache state, fresh diagnostic epochs; legacy estimator parity at 0.125 and 0.20m including clipping, caps, negative bounds, duplicates, air and post-edit scratch-buffer reads.
- `voxel_excavation_world_test.gd`: main-scene switch wiring/default, owner-to-UI synchronization, unchanged state on toggle, preference retained across reset, existing voxel integration.
- `voxel_work_zone_config_test.gd`: canonical readiness and timing-window contracts.
- `voxel_cut_queue_order_test.gd`: fixed transaction order.
- Scoped `git diff --check`; native Godot script parsing through focused tests.
- Two independent read-only reviews; optional native digest observation addressed and covered by a real-commit spy assertion.
- MCP structurally created/inspected the CheckButton in main.tscn. Unrelated editor serialization drift was removed from the resulting diff.

## Performance evidence

Single representative coalesced native cut, diagnostics enabled for measurement (microseconds):

| Phase | Before | Final |
| --- | ---: | ---: |
| Commit | 9045 | 6569 |
| Coverage | 4972 | 2131 |
| Material | 2194 | 2485 |
| Native edit | 1423 | 1476 |
| Digest | 331 | 348 |

Accepted mass stayed 525937500 fixed-point units; coverage stayed 306 cells; native paths stayed 3; the same transaction post-SDF hash was retained with diagnostics on. On/off independent full-window hash: `764644d7163d6af38e36ad4c445c63a20510d6f902315f8c6f37e31a67483d33`.

Same-process 5-sample median comparison with the frozen old estimator, cap-reaching synthetic paths:
- 0.125m: 26656 -> 12329us.
- 0.20m: 24292 -> 12417us.

These are headless CPU observations, not a Forward+ FPS or subjective smoothness guarantee. Logs: `output/cutting-performance/baseline.stdout.log`, `performance-final.stdout.log`, `world-final.stdout.log`.

## Existing regression-suite failures

The broader `voxel_excavation_authority_test.gd` reports 27 failures around dump fixtures/native-deposit expectations/full-bucket rejection. All 27 identical failure messages were reproduced with the pre-change HEAD authority and test extracted into output (baseline uses the same current work-zone environment). None of these failures were introduced by this task. The current native cutting and diagnostic scenarios pass independently.

The untouched `soil_effects_visual_mound_test.gd` fails its delayed-release source assertion. Reproduced with the pre-change HEAD SoilEffects and test as well. Kept outside this optimization's implementation scope.

Logs: `output/cutting-performance/baseline-authority-test.stderr.log`, `voxel_excavation_authority_test.stderr.log`, `effects-baseline.stderr.log`, `soil_effects_visual_mound_test.stderr.log`. World integration also emits an existing Terrain3D physics-interpolation deprecation warning.

## Human manual — pending

Start the SY135 main scene. In Advanced, toggle cutting diagnostics while cutting/dumping; confirm normal bucket/terrain behavior and perceived smoothness. Reset, verify the preference remains selected, then disable diagnostics for normal use. A fresh launch defaults off.

User accepted the delivered work and authorized commit, push, and archive on 2026-09-08. Manual smoothness observations were not separately recorded. Verification results and existing baseline failures above remain the handoff record.
