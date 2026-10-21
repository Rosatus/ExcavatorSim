# Gateway DBC codec and periodic scheduler

## Goal

Add a deterministic DBC catalog, validated physical-value drafts, persistent
per-message configuration, and a best-effort periodic producer that uses the
Gateway core's platform transport without creating a second authority path.

## Requirements

- Parse direct `.dbc` children from bundled resources, executable-adjacent
  `dbc/`, and repeatable `--dbc-dir`; scan at startup and explicit reload only.
- Sort sources deterministically, isolate parse failures, distinguish same-name
  different-content files, and deduplicate exact SHA-256 copies while retaining
  source locations.
- Use `cantools` strict encoding for byte order, signedness, scaling, offset,
  limits, multiplexing, DLC, and extended CAN ID.
- Maintain two catalog roles over the same parser/codec implementation: a
  hash-bound bundled protocol catalog for Godot telemetry and a mutable operator
  catalog for Web discovery. External reload/failure cannot replace or disable
  the Godot protocol catalog.
- Default each new physical signal to zero or its nearest-to-zero valid bound;
  mark generated defaults and reject any non-finite/out-of-range/unencodable
  message before enablement.
- Permit only one enabled definition per normalized CAN ID and surface explicit
  conflicts without auto-replacement.
- Persist valid drafts, enabled state, and integer per-message frequency through
  `platformdirs` and atomic schema-versioned JSON. Never persist armed state.
- Default every message to 50 Hz; accept only integer `1..100 Hz`. Use monotonic
  independent schedules, skip missed slots, and reset only the changed message.
- Require active platform readiness/handshake before start. All specified
  restart/reload/reconfigure/disconnect/terminal-error paths disarm and never
  auto-resume.
- Compute and expose an informational 250 kbit/s classical-CAN load estimate;
  thresholds are normal below 70%, yellow at 70–89%, red at 90%+, and sending
  is never blocked even above 100%.
- Make the approved DBC layout authoritative for Godot's complete RTK
  A000-A900 family and four IMU angle frames. Godot semantic adapters and Web
  values use one cached codec implementation while retaining independent
  source, cadence, permission, and command paths.
- Preserve Godot coordinate/antenna/velocity/status/heading derivation and IMU
  mounting/sign mapping. The IMU adapter maps reported values to DBC sensor
  slots, preserves reserved bytes, and prevents the raw all-zero invalid marker.
  Only A800 intentionally changes bytes, from the legacy big-endian exception
  to DBC little-endian.

## Acceptance Criteria

- [ ] Reference and synthetic Intel/Motorola/signed/scaled/multiplexed/extended
  fixtures encode byte-for-byte with strict validation.
- [ ] Invalid files do not hide valid files; exact duplicates collapse; same
  filenames and CAN-ID conflicts remain clearly attributable.
- [ ] Reload disarms first, revalidates persisted state, reports ignored data,
  and does not notice later disk edits until the next reload.
- [ ] A fake monotonic clock proves independent 1–100 Hz cadence, 50 Hz default,
  no catch-up burst, and isolated rate changes.
- [ ] Disabled messages never send; start fails without PC001 handshake/can0
  readiness; failure/recovery never auto-resumes.
- [ ] Load thresholds and values update from enablement/frequency but never act
  as an interlock.
- [ ] Equal A800 physical values from Godot and Web paths produce identical
  little-endian payloads across positive, negative, zero, bounds, rounding, and
  invalid cases.
- [ ] RTK A000-A700/A900 and all four IMU angle frames pass differential tests
  against their old manual encoders for representative, rounding, boundary,
  reserved-byte, mounting, and invalid-marker cases.
- [ ] External/adjacent DBC reload, replacement, or parse failure cannot change
  the protocol catalog or interrupt Godot encoding.
- [ ] Slew, travel, timed bursts, CSV, CAN packing, and all other unaffected
  simulation behavior remain byte-compatible.

## Out of Scope

- Editing/saving DBC schema, receive/decode monitoring, or replacing encoders
  for frames absent from the approved protocol DBCs.
- Emitting DBC-defined IMU acceleration/gyro, RTK A00, or other frames for which
  Godot currently has no physical-value source.
- Any scheduler hard-real-time guarantee or automatic bus-load throttling.
