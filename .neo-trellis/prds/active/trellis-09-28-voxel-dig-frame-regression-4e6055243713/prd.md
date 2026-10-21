# Voxel digging frame regression

User reports digging stalls in all three voxel maps in both editor and exports. Confirm retained 09-24 optimizations, reproduce common runtime path, identify measured regression and fix without changing cutting geometry, terrain authority, physics speed, or rendering quality.

Agent automated: canonical SY135 replay and focused phase measurement; relevant behavioral regression and paired performance after any fix. Human manual: repeat excavation on affected maps and assess responsiveness.

Current: clean starting HEAD c938a4c. Threaded property correctly follows script in main.tscn; authority receives 3000us budget. Prior a1206d7/31c2e1f/88c7184 present. Suspect additional solid-contact queries but not yet measured. No current game process or useful current interactive capture. Next: canonical baseline and attribute chassis vs soil time.

## 09-28 diagnostic checkpoint
User spotted first replay turning past soil. Invalid baseline must not be used: HEAD doubled locomotion parameters vs recorded input. 120FPS UI only changes render cap; physics still60Hz. Harness now checks recording physics rate and supports explicit diagnostic locomotion calibration, captured in report. Generated local traces retain all2521 inputs and pin pre-c938a4c dynamics/tracks; product resources unchanged.

Calibrated60FPS replay completed: yaw max deviation0.0602deg, cut123/dump23, all2521 ticks. 2405 complete frames/42s: median17.164ms, P95 26.459, P99 41.209, max62.692;48 frames>33.3ms,9>50ms. GPU P99 .836ms, chassis P99 4.042ms, soil P99 14.122ms (nested stages, not additive). Does not reproduce sustained severe stutter.

Same calibration uncapped: PASS gates, P99 25.827ms/max55.240,58 frames>33.3ms; yaw max .2301deg. Cannot compare percentiles directly across caps (different frame denominator). No proof solid query is primary cause; needs attribution. Existing optimized worker remains enabled.

User requests diagnosis now, not continued optimization. No product files modified. Only soak driver and this task changed. Diagnostic solid-query bypass run currently session67987, output/voxel-regression-0928/without-solid; resolve process before ending. Baseline/calibrated-uncapped artifacts in same root. Human reports all3 voxel maps/editor+exports. Current paired test uses historical default map and pre-speed-change dynamics, not full current workload.

Bypass completed, no test process remains. At60FPS without solid queries: P99 38.826ms/max55.369,6>50ms; chassis P99 2.720ms vs4.042 baseline; soil P99 13.902ms vs14.122. Cut127/dump23, yaw max .0378deg. Single paired run suggests measurable chassis overhead but does not remove stalls or establish sole cause. Stop further optimization per user's diagnosis-first steering.
