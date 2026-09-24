# Sole accepted soak input

`sy135-deep-cut-42s.json` is the only accepted product performance soak trace as of 2026-09-24. User watched and accepted the trimmed replay. It has 2521 ticks at 60 Hz (42.016667 seconds), with the first 1032 ticks (17.2 seconds) removed from the original recording.

Run SY135, balanced quality, normal bucket-ground interaction (pass-through OFF), race mode OFF. Start from a fresh default product scene, settle for 5 seconds, then play this input exactly once. Do not replay the removed prefix to reconstruct state: the user accepted the trimmed commands from the initial scene. Do not loop the trace, replace it with the built-in scripted cycle, or compare its numbers directly against old traces. Report measured frame intervals separately from CPU/GPU timings and verify active cutting, fixed-tick progression and queue age.

The recording contains operator inputs and observed chassis positions/yaw, not a terrain snapshot. Old input recordings and generated soak reports are retired. Their requested bulk deletion was blocked by execution policy, so they may still exist locally. Diagnostic microbenchmarks and correctness fixtures remain useful but are not soak acceptance scenarios.

The generic `jolt_product_soak.py` runner defaults to this trace, SY135/normal/balanced, 42.016667 seconds, zero measured warmup and a 5-second replay settle. The Godot soak driver explicitly disables race mode. Historical scenario support remains in the tool for its tests; those scenarios are not accepted product baselines.

Playback advances once in each `SceneTree.physics_frame`, including catch-up ticks, and ends after all 2521 commands have been consumed once. It must never index input from render callbacks or wrap with modulo. Capture lasts through trace completion; wall duration can exceed nominal simulation duration under load. The report requires exact tick count, no looping, and matching model. Cut/carry/dump remain required; support-wrench, reset and reconnect phases belong to the historical scripted scenario and are not asserted by this recording. Memory growth starts at capture creation after scene startup and settling.

The capture's interactive summary excludes unfocused frames, while this automated replay explicitly bypasses focus gating. For comparisons use all complete frame rows (omit the first partial interval), regardless of window focus, and state that frame intervals include engine waits and scheduling. Do not silently compare the interactive filtered summary with unfiltered soak metrics.
