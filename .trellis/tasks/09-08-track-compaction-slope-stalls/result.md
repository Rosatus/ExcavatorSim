# Result

The retained SY135 live run (run token 3, Godot 4.7.2 custom build) improved from 4 FPS to 60 FPS. Initial physics readings were 67.6–70.8 ms and track script cost 0.42 ms. Temporarily pausing only ExcavationWorld physics yielded 60 FPS / 9.64 ms, confirming the soil path. Processing was restored.

Six of eight track footprints passed the old padded-AABB admission even though applying their complete merged removal mask changed zero SDF samples. This repeatedly staged a large window and failed `no_loose_material` while the vehicle stood still. New admission tests actual removable samples, preserves the exact stable-neighbor protection, and caches only revision-bound eligibility. Failed transaction costs now have a separate diagnostic timing window.

## Verification

- `voxel_compaction_admission_test.gd`: PASS. Real captured fixture reproduces six false legacy admissions; new gate rejects all eight. Cold evaluation 11.08 ms, repeated eight-probe evaluation 31.55 us. No repeated stencil reconstruction. Material/SDF/generation invalidation, protected/air/halo cases, positive eligibility and cache bounds pass.
- `voxel_track_compaction_test.gd`: PASS, exit 0. Existing cut/deposit/track/re-cut cycle plus a pure-mobile positive control. Real receipt admission and dedupe work; compaction changes quantized SDF and density while conserving mobile mass. Final comparison reads native values both before and after, avoiding quantization-only false evidence.
- Independent read-only review: no actionable false-negative, invalidation or production memory-bound findings.
- Scoped `git diff --check` and task context validation: PASS.
- Broad authority suite exposed two unrelated deep-cut path-count/overburden assertions. Replaying the HEAD test with the HEAD admission method reproduces both failures. They are not claimed as passing; focused compaction gates isolate this change. Logs: `output/track-compaction-stalls/baseline.err`.

Final retained-scene sample: all twelve FPS observations were 60; monitor physics readings were 10.898–15.578 ms. These are repeated monitor samples, not a per-frame p95 benchmark. `no_loose_material` stays at 11142; soil processing is active and diagnostics restored off. Generation 0, data revision 332, bucket mass 3083 q and material digest `2695673431ab5ec50196bf3abab7533779e4725d32c1b86e78ad90ffe480751b` are unchanged. The captured 34×12×34 native SDF window is byte/value-identical. Evidence: `output/track-compaction-stalls/live-before.var`, `live-after.json`, and focused test logs.

The game was not restarted/reset. Runtime hot reload preserves existing members but leaves newly added RefCounted fields null; these were explicitly initialized before final sampling. Temporary sampling/initialization debugger breaks were recovered and the error-breakpoint preference restored. Fresh process initialization is covered by headless tests.

## Retrospective

Root category: admission/execution contract mismatch plus a test gap. Previous empty-mobile admission optimized untouched ground, but did not cover compactable material adjacent to protected SDF. A test explicitly allowed expensive rejection after staging; it now permits early rejection and a separate positive control prevents accidentally disabling compaction. Successful-only timings hid rejected work, so failed duration is separately observable. The frontend contract and recorded live fixture preserve this case.

Human manual: drive across the retained slope and confirm responsiveness. Code remains uncommitted; unrelated addon/config/worldbuilding changes remain untouched.
