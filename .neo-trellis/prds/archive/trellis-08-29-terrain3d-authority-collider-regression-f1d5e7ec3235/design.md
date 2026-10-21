# Design — Native/fallback authority equivalence

Create one deterministic scenario harness whose only variable is presentation
backend. Capture structured checkpoints after startup, each material phase,
locomotion, failure, reset, and model switch. Compare domain truth directly;
exclude renderer node IDs, GPU counters, and pixels from authority equality.

Instrument collision provenance so every accepted terrain ray/query identifies
the project collider or logical heightfield fallback. Assert no Terrain3D
collision owner exists on active query layers when production mode is zero.
