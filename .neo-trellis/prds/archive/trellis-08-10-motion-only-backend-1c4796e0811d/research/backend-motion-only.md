# M3 research: existing runtime and wire contract

## Existing composition

- `backend/src/babylon_sim/runtime.py` constructs `Simulator`, `InputRouter`,
  `ChunkedRecordingBuffer`, `TerrainController`, `ReplayWorker` and
  `RecordingExchange` in `RuntimeController.__init__`. `_publish` appends every
  state to recording and periodically submits terrain edits; `start`/`stop`
  control the fixed-rate thread plus replay/exchange/terrain lifecycle.
- `backend/src/babylon_sim/web.py` uses `runtime.replay.latest` as the aligned
  view source and sends terrain views/patches beside each view state. Recording
  and terrain HTTP routes are mounted unconditionally. The current hello
  capability set is the full six-capability set.

## Compatibility constraints

- `protocol/babylon-sim-v3.schema.json` requires `recording_epoch`, playback
  metadata, and version fields even for `view_state`; the motion-only adapter
  must populate these fields without implying recording authority.
- M2 Godot advertises only `input_snapshot` and `commands`, consumes
  `hello_ack`/`view_state`/acks/errors, and ignores terrain messages. Therefore
  capability intersection plus an unchanged `view_state` shape is sufficient
  for both profiles.
- `pixi run verify` is the backend quality gate and must remain green.
