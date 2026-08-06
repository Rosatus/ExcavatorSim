# Authoritative Terrain API V1

`protocol/terrain-spec-v1.schema.json` owns deterministic Flat, Slope, Trench, and Profile inputs.
`protocol/terrain-http-v1.schema.json` owns preview requests and metadata. The backend is the only
generator and terrain-history authority; the browser must not regenerate a heightfield from a spec.

## Preview lifecycle

- `POST /api/terrain/preview` requires `X-BabylonSim-Session` and the current
  `expected_recording_epoch`, `expected_terrain_epoch`, and strict TerrainSpec. It returns a
  session-bound token that expires after five minutes. A session holds at most four previews.
- `GET /api/terrain/preview/{token}/snapshot` returns that session's candidate as
  `application/vnd.babylon-sim.terrain-f32le`.
- `DELETE /api/terrain/preview/{token}` consumes staging without mutating active terrain.
- WebSocket `terrain_command` action `apply_preview` consumes the token under recording/terrain
  epoch compare-and-swap. It creates a new terrain epoch at revision zero and preserves the motion
  recording epoch. `reset_terrain` preserves the terrain epoch and increments the revision.

Disconnect, cancel, expiry, invalid input, stale identity, and failed snapshot verification do not
mutate active terrain. Imported RRD v1 replay exposes a read-only default flat terrain.

## Visual excavation and history

`terrain-algorithm-v2` evaluates immutable authoritative `tooth_left`, `tooth_center`, and
`tooth_right` world-frame points every fourth 100 Hz motion publication. The newest-input worker is
single-slot and cannot block the runtime thread. Cutting is enabled only in the calibrated closed
bucket posture near the surface; opening above the surface deposits a normalized kernel. Internally,
the canonical state is a Float32 stable-height layer plus a non-negative Float32 loose-depth layer;
the public surface remains their Float32 sum. Cut/fill is bounded to 3 m from the applied baseline,
one edit changes at most 4,096 cells, and bucket capacity is 0.35 m³. The algorithm is deterministic
visual deformation, not soil physics.

Cutting removes loose depth before lowering stable substrate, so a cut surface is not automatically
collapsed. Dumping adds only to loose depth and runs a bounded synchronous four-neighbor relaxation
with a 34-degree repose angle. Stable heights never move during relaxation. Work is limited to a
fixed dirty halo, 64 passes, and a fixed cell-visit budget. A converged capacity-limited result may
leave residual material in the bucket when capacity is unavailable; an unconverged tentative dump
is discarded in full, leaving terrain and bucket state unchanged.

Each changed revision records its motion sample, sweep, operation, bounds, cut/deposit volume,
remaining bucket volume, public surface digest, and versioned layered-state digest. Compressed
checkpoints retain both canonical arrays. They are created at epoch/reset boundaries and after at
most ten seconds or 250 events. Historical materialization starts at the nearest checkpoint, verifies
both digests, and replays at most 250 events. Retained reconstructible history is capped at 128 MiB
and is pruned only with the corresponding retained motion window.

Deposit events also retain deterministic relaxation pass, touched-cell, cell-visit, convergence, and
bucket-residual diagnostics. They are internal replay/benchmark evidence and do not change the
WebSocket or snapshot contract.

Simulation Reset keeps the terrain epoch/heights and clears the bucket. Terrain Reset restores the
current baseline and advances the revision. Applying a preview creates a terrain epoch at revision
zero. RRD v1 import discards live terrain and installs a flat read-only epoch; Return to Live creates
new recording and terrain epochs with an empty bucket.

## Snapshot contract

`GET /api/terrain/snapshot` requires the current session plus recording epoch, terrain epoch,
terrain revision, and a request id. Response headers repeat those identities, rows, columns, and
SHA-256. Payload is the derived surface only, row-major Float32 little-endian, exactly
`rows * columns * 4` bytes, finite, and bounded to 50,000 points / 200,000 bytes. Canonical layer
arrays never cross this API. The client rejects stale identities, media type, length, digest, or
non-finite values before replacing the Babylon mesh.

`terrain_view` is sent immediately after its aligned `view_state`; it identifies the terrain active
at `selected_sample_sequence`. Terrain state is separate from the RRD v1 motion entities.

Sequential live changes may add a `terrain_patch` after that pair. A patch is accepted only when its
recording/terrain epochs, target revision/digest, and `base_revision + 1 == new_revision` match the
current authority; its originating sample may be earlier when later motion samples still select the
same terrain revision. Cell indexes are strictly increasing, bounded by the grid, and encoded
messages are limited to 256 KiB. Any gap, seek, reconnect, epoch change, or stale completion causes a
generation-gated full snapshot request instead of speculative repair. The frontend cache is bounded
to 32 MiB and Babylon updates only dirty positions plus the one-cell-expanded normal region.

`pixi run benchmark` records maximum-grid snapshot/apply latency, continuous visible edit latency,
25 Hz edit input rate, patch sizes, history use, and runtime rates under edit/snapshot/seek workloads
in `artifacts/benchmark/terrain.json`.
