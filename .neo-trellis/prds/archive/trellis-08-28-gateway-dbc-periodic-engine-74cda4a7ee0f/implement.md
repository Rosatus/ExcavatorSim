# Implementation Plan — Gateway DBC codec and periodic scheduler

## 1. Dependency and catalog

- [x] Add pinned/ranged `cantools` and `platformdirs` runtime dependencies to
  source/test/PyInstaller environments.
- [x] Implement normalized discovery, SHA-256 deduplication, parse isolation,
  deterministic metadata DTOs, reload, and explicit source notices.
- [x] Build a startup-validated, hash-bound protocol catalog for Godot separately
  from the reloadable operator catalog while sharing parser/codec types.
- [x] Add reference and synthetic DBC fixtures covering all required semantics.

## 2. Draft validation and persistence

- [x] Implement generated defaults, physical validation, strict encode preview,
  stable file/message/signal keys, and normalized CAN-ID conflict checks.
- [x] Implement atomic versioned persistence, incompatible-entry notices, and
  restore-disabled conflict/armed behavior.
- [x] Expose catalog and atomic message-edit commands through core snapshots.

## 3. Periodic scheduler and load

- [x] Implement integer 1–100 Hz validation, 50 Hz defaults, independent
  monotonic deadlines, no-catch-up behavior, and per-message rate reset.
- [x] Route emissions through the core-owned active platform transport with
  explicit readiness/handshake requirements and shared aggregate logging.
- [x] Implement all disarm conditions and prove recovery never auto-resumes.
- [x] Add the documented 250 kbit/s load estimate and non-blocking thresholds.

## 4. Godot RTK and IMU migration

- [x] Add explicit RTK signal adapters for A000-A900 and route them through the
  hash-bound protocol catalog without changing physical derivation or cadence.
- [x] Remove only A800's big-endian exception; add cross-producer little-endian
  boundary/rounding/invalid fixtures.
- [x] Differential-test A000-A700/A900 DBC output against the existing manual
  encoders before retiring those runtime byte-construction branches.
- [x] Add the IMU sensor-slot semantic adapter, reserved values, mounting/sign
  mapping, and all-zero invalid-marker protection, then differential-test all
  four angle frames against existing golden payloads.
- [x] Keep slew, travel, fixed timed frames, and messages without current Godot
  value sources on their existing paths.

## 5. Verification

- [x] Run catalog/hash/conflict/default/persistence tests.
- [x] Run strict codec fixtures for endian, signed, scaling, limits, EFF, DLC,
  multiplexing, rounding, and invalid values.
- [x] Run fake-clock scheduler/load/disarm/recovery/failure tests.
- [x] Prove operator catalog reload/failure cannot alter Godot protocol encoding.
- [x] Run Gateway/timed/CSV/PC001/SocketCAN/CAN-byte regressions. Godot test
  execution still awaits an environment with a Godot binary; its affected
  GDScript and Python compatibility assertions are updated.
