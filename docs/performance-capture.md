# Performance capture

The opt-in recorder observes the running Godot client; it does not drive the
machine or edit terrain. SY135 is the representative maintained model.

## Record a reproduction

1. Restart the game after updating scripts. Press **F12**, or open **Esc → 高级工具 →
   开始性能录制**. A small recording badge appears while recording.
2. Return to driving. Idle for about 10 seconds, then reproduce excavation,
   carrying, dumping and re-cutting for 30–90 seconds. Keep the usual camera and
   graphics settings for the first capture.
3. Press **F10** when a hitch is noticeable. Markers include a timestamp and
   sequence number; the analyzer inspects the preceding two seconds as well.
4. Press **F12** again to stop and save. The recorder automatically stops at
   180 wall-clock seconds (including menu/focus time) or 60,000 process frames,
   whichever comes first. A normal scene
   exit also attempts to save; killing the process loses buffered samples.
5. In **Esc → 高级工具**, choose **打开性能文件目录**. Share the generated
   `capture-*.json` file or its absolute path with the assistant. Recording again
   creates another file. You do not need to run the analyzer yourself.

Default output: `user://performance-captures`, normally
`%APPDATA%\Godot\app_userdata\ExcavatorSim\performance-captures` on Windows.
The menu displays the actual absolute filename. Failed saves retain buffered
data and expose a retry button; a new capture cannot silently replace unsaved data.

## Recorded data

- Every late process callback: monotonic wall-clock frame interval, engine process
  and single-physics-tick timing, number of physics ticks since the previous row,
  main-viewport CPU/GPU rendering time, render setup CPU time, draw calls,
  primitives, static memory, pause/focus flags and recorder cost.
- All voxel physics steps between rows: automatic interaction/proposal cost,
  authority step cost, status publication/subscriber cost, and total soil cost.
  Every attempted transaction carries separate commit, coverage, material,
  native-edit, diagnostic-digest and readiness-registration times with identity.
- At four Hz: selected model/generation, terrain/mesh/collision revisions, queue
  and pending-readiness counts, phase timing windows, Voxel Tools statistics and
  graphics profile. This avoids polling the general world status every frame.
- Metadata: engine version, CPU/GPU, renderer, viewport size, VSync/FPS limits,
  physics rate, relevant source hashes when available, capture bounds, units and
  measurement limitations. Source text may be unavailable in exported builds.

Schema: `excavator-performance-capture-v1`. `frame_columns` describes each numeric
row in `frames`; timing columns are milliseconds. `events` contains transactions
and markers, and `contexts` contains low-rate state. `summary` excludes the first
partial interval and paused/unfocused intervals, including state-transition rows.
`tail_stage_values` retains pending stage totals that were not consumed by another
frame callback when recording stopped; `tail_partial_interval_ms` describes that
unframed tail. `dropped_events` explicitly reports hitting the event bound.

## Analyze

Run from the repository root with Python 3.11 or later, using only the standard library:

```powershell
python tools/analyze_performance_capture.py 'C:\path\capture-....json'
```

The command creates `capture-....analysis.md` next to the capture. Optional
`--output <report.md>` and `--json-output <analysis.json>` select report locations.
The analyzer rejects incomplete headers, malformed rows and non-finite timing.
It reports P50/P95/P99/max timings, slow-frame counts, the 20 worst driving frames,
marker neighborhoods and stage correlations. It preserves the input file.

## Interpretation and overhead

Frame interval measures time between process callbacks, including pacing and
waiting. It is not GPU presentation latency. Engine/render values are their
latest reports and can lag a row. Physics monitor time is one reported tick,
not the sum of all ticks in that frame. Main-viewport CPU/GPU timings exclude
other viewports, overlap each other, and must not be summed into frame time.
The authority commit is inside `soil_step_ms`; soil stages are inside
`soil_total_ms`. The report lists nested costs without treating them as additive.

Rendering measurements use Godot's
[RenderingServer timing API](https://docs.godotengine.org/en/stable/classes/class_renderingserver.html#class-renderingserver-method-viewport-get-measured-render-time-cpu).
Unavailable headless render measurements are `-1`; zero GPU measurements are
not evidence of a free GPU workload. Actual GPU timing and visual usability
require a normal Forward+ session, not a headless test.

Recording enables lightweight stage clocks only. It does not enable full voxel
diagnostics or their additional SDF digest reads. The existing diagnostics setting
is preserved and its checkbox is locked while recording. If full diagnostics were
already enabled, metadata and analysis prominently flag that extra workload; turn
them off before a normal-load capture. `recorder_ms` measures sampling, context
polling and signal handling in the preceding interval; engine instrumentation and
pre-existing diagnostic work inside the soil authority remain outside it.
`digest_ms` identifies the latter, also included in soil/commit totals.
Capturing allocates bounded in-memory buffers (60,000 frames, 12,000 events,
1,000 contexts); serialization, sorting and writing occur only after stopping.
There is no continuous disk logging or background capture when disabled.

Use recorded correlations to select the next experiment, not to declare a cause
from one counter. Preserve the first capture with normal settings before testing
a graphics-profile or other controlled change.

Window focus-entered/exited signals invalidate the next interval even if both
transitions occurred between process callbacks. A system suspension or debugger
pause that sends no focus event cannot be distinguished from a long game frame;
avoid these during a reproduction and mention them if they occurred.
