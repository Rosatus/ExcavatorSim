# Implementation Plan

- [x] Finalize truth/sensor schemas, rates, clocks, coordinate/unit semantics,
      quality, uncertainty, gaps, and size/rate limits.
- [x] Implement Godot post-physics truth sampling and a bounded sensor scheduler.
- [x] Implement encoder, four-IMU, GNSS, track/contact, and payload/load producers.
- [x] Implement negotiated batching/transport and Python shared decoders/validators.
- [x] Implement gateway freshness/health and bounded telemetry export/subscriber
      seam without extending legacy RRD columns.
- [x] Reuse the existing external input command ingress with sequence/lease
      diagnostics and fail-safe zero/disarm semantics; production hardware
      drivers remain out of scope.
- [x] Ensure Jolt profile bypasses Python Simulator/Pinocchio pose reconstruction.
- [ ] Add cross-language fixtures and stationary/motion/load/noise/rate/drop/gap/
      malformed/lifecycle/both-model tests.
- [ ] Run verify, backend smoke, standalone matrix, live MCP telemetry inspection,
      soak/rate tests, and memory/queue bounds.
- [x] Update protocol, runtime-profile, sensor, and architecture docs.

## Current Slice

The initial telemetry slice is implemented: fixed-tick Godot batches contain
four encoders, four declared frame-tagged IMUs with explicit rotation/
angular-velocity/specific-force layout, GNSS position/velocity, track/contact,
and payload/load samples with raw values and zero-noise metadata. Python
negotiates, validates kind layouts, orders, rate-limits, stores, expires, and
reports the latest batch without touching product simulation or legacy RRD
columns. Remaining work is the full motion/noise/drop/soak acceptance matrix
and additional both-model lifecycle fixtures.

## Rollback Point

Sensor/telemetry capabilities are optional to local physics until Phase 5. Removing
the gateway must not create a second local pose or disable keyboard simulation.
