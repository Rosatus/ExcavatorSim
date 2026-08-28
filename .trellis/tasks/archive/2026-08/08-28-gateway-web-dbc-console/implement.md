# Implementation Plan — Gateway Web console and DBC frame sender

## Phase 0 — Preserve baselines

- [ ] Record focused Gateway, PC001, SocketCAN/can0, ICT, timed-frame, CSV, CAN
  packing, RTK family, IMU angle, and Godot bridge baseline results.
- [ ] Record reference DBC hashes/metadata and repository provenance before
  copying any file.
- [ ] Keep the existing can0 task's physical-device validation status separate.

## Phase 1 — Runtime core and Web control plane

- [ ] Complete child task `08-28-gateway-web-runtime-core`.
- [ ] Introduce explicit modes, loopback-only startup, typed command queue,
  immutable snapshots, and mode/platform API authorization.
- [ ] Serialize PC001 writes and remove unbounded/stale clientless buffering.
- [ ] Add safe Windows rebind and Linux fixed can0 restart lifecycle.
- [ ] Add bounded live aggregates and asynchronous rotating persistent logs.

## Phase 2 — DBC codec and periodic engine

- [ ] Complete child task `08-28-gateway-dbc-periodic-engine` against the core
  command/snapshot boundary.
- [ ] Add deterministic DBC discovery, strict encoding, defaults, validation,
  conflicts, atomic persistence, and independent monotonic schedules.
- [ ] Add non-blocking bus-load estimation and all disarm/recovery rules.
- [ ] Separate the hash-bound protocol catalog from mutable Web discovery, then
  route Godot RTK A000-A900 and four IMU angle frames through shared DBC
  encoding while retaining their semantic/cadence/permission paths.

## Phase 3 — React console and distributions

- [ ] Complete child task `08-28-gateway-react-console-packaging` after the API
  and DTO contracts are stable.
- [ ] Build the React/Tailwind/shadcn status, DBC editor/sender, transport, load,
  and log views with managed-mode read-only rendering.
- [ ] Copy and provenance the two approved DBCs; bundle Web resources and place
  executable-adjacent DBC copies in Windows and Linux distributions.
- [ ] Update Godot launch arguments to pass managed mode and preserve its
  platform-specific transport arguments.

## Phase 4 — Integration and release gates

- [ ] Run all child check manifests plus cross-layer API/UI/package tests.
- [ ] Verify loopback-only binding, fixed-port failure, no default browser,
  managed API rejection, restart/reload disarming, and no auto-resume.
- [ ] Verify A800 little-endian parity between Godot and Web input; prove
  A000-A700/A900 and IMU angle differential parity with current golden bytes,
  and preserve all non-DBC-covered simulation frames.
- [ ] Build Windows and Linux artifacts; prove the Web console and reference
  DBCs work without Node.js on the target.
- [ ] Perform target Windows PC001 and Linux USB-CAN/can0 validation, recording
  hardware-dependent evidence separately.

## Rollback points

- Keep each child independently reviewable and do not start the next child
  until its ownership/contract tests pass.
- Do not switch Godot to the new managed CLI until Gateway compatibility and
  startup tests cover both old failure reporting and new mode selection.
- If target hardware validation fails, stop/revert the new distribution without
  deleting drivers, changing DBC sources, or altering physical `can0` ownership.
