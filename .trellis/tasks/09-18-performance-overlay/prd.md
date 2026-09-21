# Performance instrumentation and live overlay

User requests diagnosis of current track performance, sufficient instrumentation for
recorded-input soak, and a persistent Advanced-menu toggle for a top-right FPS,
frame-time and graph overlay. Recording provided:
backend/scripts/godot/recordings/manual-dig-sy135-balanced-normal-90s-turn180.json.

Implemented: bounded 40-bin 4 Hz FPS/peak-frame-time graphs, quarter-second average
FPS/frame time, latest engine CPU/physics and viewport GPU readings, transparent
mouse handling, pause/background label, independent capture/HUD render-timing
ownership and persistent preference. Disabled overlay stops process/draw work.
No gameplay authority changes. Recorder adds accumulated chassis_ms/tracks_ms and
step count, runtime and solver source hashes; soak invokes recorder after warmup,
links sidecar in report, disables HUD in its process. Analyzer labels new clocks.

Agent automated:
- performance_capture_test PASS (expected invalid-directory fixture error).
- performance_overlay_test PASS: bounds 720p/1080p, bounded history, mouse ignore,
  independent capture/HUD start/stop lifecycle, scene teardown.
- analyzer pytest 4 passed / 5 subtests.
- 62s SY135 balanced normal recorded-input rendered run, 5s warmup, uncapped,
  Forward+ D3D12 RX9070XT; actual measured viewport 1920x1080. Report:
  output/performance-overlay/soak.json; analysis.md and analysis.json alongside.
- Soak overall FAIL render_frame_p99 (34.249ms); do not claim all gates pass.
  Capture 14369 active frames; P95 9.636ms P99 34.832ms; 46 frames >100ms;
  max 861.456ms. Uncapped average 253.8 FPS conceals severe hitches.
  Track callback per-step aggregate average .582ms, P95 .639ms, P99 .723ms,
  max 1.109ms. Most 150-174ms hitches contain 103-119ms soil work and eight
  physics steps; track total ~5ms; GPU ~2ms. 861ms outlier remains unexplained.
  No before/after control run: cannot establish change causality or full engine
  physics cost from the script clocks. Evidence points away from track script
  as dominant cost, not proof of no regression. Existing CAN port-conflict warning
  did not prevent benchmark completion; no other processes were stopped.

Human manual pending: restart game, Esc/Advanced/显示帧率与性能曲线; confirm
readability over gameplay, enable/disable, F12 recording coexistence, theme switch
and persisted preference. No subjective screenshot approval inferred from tests.

All current changes uncommitted. Separate soil/engine hitch investigation is not
part of implementation scope; the new capture supplies evidence for that work.
