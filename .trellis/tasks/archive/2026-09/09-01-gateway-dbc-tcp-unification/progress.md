# Progress

## 2026-09-01 — development and Windows-first package

Completed product implementation:

- approved CAN3/CAN4 DBC bytes, fixed hashes and provenance;
- 30 DBC rows plus native `0x18FFF100` and `0x256`;
- DBC-owned `0x18FFF000` and little-endian A800;
- shared `ch0|ch2|ch3` projection through Web, CSV and PC001 i32;
- Windows/Linux default TCP and Godot cross-platform TCP argv;
- explicit SocketCAN-only low-latency mode;
- timed row off/custom/simulation authority and raw-only Web editing;
- atomic all-off/all-custom/all-simulation owner command and Web controls;
- console schema 4 / portable schema 2 with compatible schema 3/1 migration;
- updated React production bundle and executable code-specs.

Windows Gateway package:

- `dist/can_gateway/gateway.exe`
- executable SHA-256: `b6b2c39042e721e2f008daed801add6350ac1d0258608bf19753dad572c5e5dd`
- adjacent DBC hashes match the approved source hashes;
- `build-manifest.json` refreshed after the final build;
- packaged smoke emitted 53 rows with `ch0`, `ch2`, and `ch3` present.

Fast gates completed:

- Python `py_compile` for changed Gateway modules;
- Ruff for changed Gateway modules and Windows builder;
- React TypeScript/Vite production build;
- packaged `gateway.exe --help` and CSV smoke.

Explicitly deferred at the user's request:

- full Gateway Python test suite;
- React test suite;
- focused Godot CAN Gateway headless E2E;
- full project verification/provenance gate;
- Linux Gateway/Godot packaging and real Linux/SocketCAN validation.

The Trellis task remains active until those deferred gates and final acceptance are complete.

## 2026-09-01 — acceptance fix: realtime runtime summary

- The runtime summary no longer waits for discrete transport/configuration events or an
  HTTP snapshot refresh. Changed Gateway status counters now share the typed,
  sequence/gap-aware `can_console_runtime` WebSocket batch used by row runtime data.
- The backend publishes changed status and/or row projections at most once per 50 ms
  (approximately 20 Hz), including status-only updates such as PC001 offline drops; an
  unchanged state produces no event.
- React validates the status projection at the event boundary and merges it into the
  existing status snapshot without high-frequency HTTP polling.
- Fixed the exact-50-ms coalescing boundary to compare absolute deadlines, avoiding a
  floating-point subtraction edge where a due batch could be deferred by one loop.

Focused evidence:

- Gateway runtime unit tests: 13 passed;
- React App tests: 9 passed;
- ESLint and TypeScript/Vite production build passed;
- Python `py_compile` passed; Ruff installation was unavailable due a stalled tool
  download, with no Ruff failure observed;
- rebuilt packaged Gateway started successfully as `tcp:ready` and exposed all 32 CAN
  console rows through its Web API.

Updated Windows Gateway package:

- `dist/can_gateway/gateway.exe`
- executable SHA-256: `56f811d42c7860fec0a2b04e597a511438ef9706f4924f8d614943c45bfae423`
- `build-manifest.json` refreshed after the final build.

## 2026-09-01 — deferred automated gates and Linux release

Completed the previously deferred automated validation:

- Gateway Python suite: 190 passed, 2 skipped;
- React console: 9 tests passed, ESLint passed, TypeScript passed, Vite production build passed;
- focused Godot CAN Gateway headless E2E passed, including shared Windows/Linux TCP argv,
  runtime heartbeat, recording, timed CAN, PC001 handshake/disconnect/reconnect and restart;
- `pixi run verify` passed, including backend Ruff/mypy and 185 backend tests;
- Godot toolchain tests: 16 passed, 1 skipped because Windows did not grant symlink permission;
- provenance and standalone-path gates passed.

Completed the unified Windows/Linux release build with Godot
`4.7.2.stable.custom_build.ed1daf0bf` and Voxel Tools `v1.7`:

- Linux Gateway: `dist/can_gateway_linux/gateway`, SHA-256
  `46be47c31a1e0b1fdf2735bcc47aaa716258e86229bbafe08412d62b3f1c585b`;
- Linux can0 helper: `dist/can_gateway_linux/can0-setup-helper`, SHA-256
  `cd4b53ec5962a8b4ffd3ff79ca7151ae500c7f4eb2e7ce18bee78cc732e1a351`;
- Linux Godot package: `godot/dist/linux`;
- Linux archive: `godot/dist/ExcavatorSim-linux-x86_64.tar.gz`, SHA-256
  `188bbe9106a7d4e29d26881265ddb3e455751d203e0b13960fee8c66f55223bb`.

Artifact verification passed:

- Gateway and helper are ELF x86-64 executables;
- source distribution, expanded Godot package and tar members have identical Gateway/helper hashes;
- all three Linux manifests reproduce every declared file size and SHA-256;
- CAN3/CAN4 hashes remain
  `dc48542fda0ad369a3a30d0d13e74df1cdcc4c9bab71f01e9be3e56df99e7b58` and
  `fe7dd152c256b8c3d1999792fad66e8872d08d1053c56c51a2272f2978a5e3c1`;
- the Linux archive lists successfully and packaged `gateway --help` exits 0 in WSL;
- Windows and Linux exported Voxel module smoke tests passed.

Real USB-CAN/SocketCAN hardware validation was not run in WSL. It remains a manual
target-machine check for the explicit, temporarily unmaintained low-latency mode; the
new default TCP path is covered by automated tests and packaging smoke checks.

## 2026-09-02 — independent PC001 TCP test client

Added an isolated Windows desktop diagnostic tool under `tools/pc001_test_client`.
It is deliberately excluded from the Gateway and Godot release bundles and does not
change the production PC001 wire contract.

Implemented capabilities:

- PySide6 Widgets table UI with host/port controls, reconnect, pause, clear, ID/channel
  filters and sortable CAN identity, channel, DLC, payload, count, actual rate and
  freshness columns;
- strict fragmented `who` → `PC001` handshake and decoding of the production PC001
  little-endian batch/frame/channel layout, including SFF/EFF identity;
- bounded receiver-to-GUI queue and bounded latest-value aggregation keyed by
  `(is_extended, can_id, channel)`, with actual rate derived from the latest ten sends;
- clean generation-guarded reconnect/stop semantics, typed partial-frame timeout and
  protocol diagnostics, and non-daemon receiver shutdown;
- direct compatibility coverage against both `Pc001ClientSink` and a real Gateway
  subprocess emitting DBC-owned, timed and travel rows across channels 3, 2 and 0;
- independent `uv` environment, Windows onedir/zip builder, build metadata and
  reproducible artifact manifest.

Focused evidence:

- 21 unittest cases passed, including fragmented reads, malformed batches, timeout,
  reconnect, bounded aggregation, model filtering and the real Gateway process;
- Ruff passed;
- strict mypy passed for 14 source/test files;
- packaged-client smoke passed a real fragmented handshake plus one PC001 frame;
- packaged GUI remained alive through its startup smoke;
- packaged PySide6/Qt runtime is consistently `6.8.3`.

Windows test-client package:

- executable: `dist/pc001_test_client/PC001TestClient/PC001TestClient.exe`, SHA-256
  `6e0cf53b58a299b9f39395545d106c46a96a944453b522c1270a675ea93c56ae`;
- archive: `dist/pc001_test_client/PC001TestClient-windows-x86_64.zip`, SHA-256
  `4634979cce5d5a2e54fc1741008cccb3b82829a40854a55e0c7d070c63b32e01f`.

Manual UI acceptance is intentionally left to the user. This increment does not by
itself close or archive the wider Gateway DBC/TCP-unification task.
