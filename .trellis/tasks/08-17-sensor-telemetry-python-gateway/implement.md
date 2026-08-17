# Implementation Plan

- [ ] Finalize truth/sensor schemas, rates, clocks, coordinate/unit semantics,
      quality, uncertainty, gaps, and size/rate limits.
- [ ] Implement Godot post-physics truth history and bounded sensor schedulers.
- [ ] Implement encoder, four-IMU, GNSS, track/contact, and payload/load producers.
- [ ] Implement negotiated batching/transport and Python shared decoders/validators.
- [ ] Implement gateway freshness/health, bounded recording, export/subscriber, and
      external command ingress interfaces.
- [ ] Ensure Jolt profile bypasses Python Simulator/Pinocchio pose reconstruction.
- [ ] Add cross-language fixtures and stationary/motion/load/noise/rate/drop/gap/
      malformed/lifecycle/both-model tests.
- [ ] Run verify, backend smoke, standalone matrix, live MCP telemetry inspection,
      soak/rate tests, and memory/queue bounds.
- [ ] Update protocol, recording, runtime-profile, sensor, and architecture docs.

## Rollback Point

Sensor/telemetry capabilities are optional to local physics until Phase 5. Removing
the gateway must not create a second local pose or disable keyboard simulation.

