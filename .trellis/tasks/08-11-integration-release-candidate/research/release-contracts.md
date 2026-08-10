# M7 research notes

- `MotionClient` already has fake transport, hello/view injection, reconnect,
  pose-clear and stale generation seams. M7 adds only a scene-level composition
  test around those seams.
- `ExcavationWorld` now resets local inventory/contact on `pose_cleared` and
  authority-generation changes; `SoilEffects` uses the combined local/authority
  generation and clears particles on changes.
- Backend motion-only WebSocket tests cover capability negotiation and reject
  terrain/playback routes with stable `capability_unavailable` errors; the
  default legacy profile remains available for compatibility.
- The release candidate must not claim a hardware benchmark from headless
  viewport measurements; target FPS remains a human 1920×1080 review gate.
