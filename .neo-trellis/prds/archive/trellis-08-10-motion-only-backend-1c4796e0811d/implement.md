# Implementation Plan

1. [x] Add a typed runtime profile and optional-service composition in
   `backend/src/babylon_sim/runtime.py`; preserve the default legacy path and
   make motion-only publish schema-compatible live views without recording or
   terrain work.
2. [x] Update `backend/src/babylon_sim/web.py` to derive capabilities, guard
   unsupported HTTP/WS operations, and send only motion views/status for the
   motion-only profile while preserving legacy messages byte-for-byte where
   applicable.
3. [x] Add `--runtime-profile` and `start-motion-only` launcher support without
   changing the default desktop command.
4. [x] Add focused tests for profile service absence, hello capability
   negotiation, view-state validity, lifecycle/reset/disconnect and unsupported
   operation rejection; reuse existing model/calibration fixtures.
5. [x] Run targeted tests, Godot M2 headless/client compatibility smoke, then
   the full `pixi run verify` gate and diff/provenance checks.

## Exit gate

The motion-only profile runs the same four-joint motion behavior as legacy,
requires no terrain/replay/exchange worker, advertises only implemented
capabilities, rejects unsupported operations without mutation, and passes the
full backend verification gate. [x]
