# Simulation Truth Shadow Contract

## 1. Scope / Trigger

Use this contract whenever Godot publishes fixed-tick motion/physics observations
to Python during the Jolt authority migration. Phase 0 is observational only:
`python_kinematic` remains the product pose writer and `jolt_shadow` must not feed
`Simulator`, `AuthoritativeViewState`, `MotionPresentation`, `TerrainState`, or
`BucketSoilState`. Phase 1 `jolt_authoritative` may produce the same versioned
truth shape locally, but it is not a valid shadow transport profile.

## 2. Signatures

- Optional capability: `simulation_truth_shadow_v1`.
- Client WebSocket envelope:

```json
{"type":"simulation_truth_shadow","protocol_version":"godot-pinocchio-v3","snapshot":{}}
```

- Godot producer: `MotionClient.queue_simulation_truth_shadow(snapshot: Dictionary) -> bool`.
- Python boundary: `decode_shadow_truth(snapshot, expected_identity) -> ShadowTruthSample`.
- Latest-value store: `RuntimeController.submit_shadow_truth(session_id, sample)` and
  `RuntimeController.latest_shadow_truth()`.
- Diagnostic response: `/health.simulation_truth_shadow`, or `null` when missing,
  disconnected, stopped, or older than 0.5 s.

## 3. Contracts

The independent `simulation-truth-v1` schema requires profile/authority epoch,
strictly increasing sequence and physics tick, monotonic nanoseconds, canonical
right-handed Z-up coordinates, current session/simulation/model/rig/calibration
identity, terrain generation/revision, exactly the five named body transforms
and four named joints, track, payload, contact, and quality data.

Godot stays right-handed Y-up internally. `MotionProtocol` owns the only export
conversion: `T_zup = inverse(C) * T_yup * C`; vectors map `(x,y,z)` to
`(x,-z,y)`. Every body matrix must be finite, right-handed, orthonormal, and end
with `[0,0,0,1]`.

Rig identity comes from `simulation-authority-v1.json` and the model-specific
`physics-rig-v1` descriptor. Descriptor physical values must declare provenance;
the current SY205 and SY135 values are provisional and may enable only the
bounded Phase 1 chassis profile. They cannot validate articulated equipment,
excavation coupling, final mass properties, or production cutover.

## 4. Validation & Error Matrix

| Condition | Error / behavior |
|---|---|
| Capability not negotiated | `capability_unavailable` |
| Outer envelope unknown/oversized/non-finite | Existing v3 protocol error; 64 KiB maximum |
| Unknown truth version or field/shape violation | `shadow_schema_validation_failed` |
| Snapshot profile is not exactly `jolt_shadow` | `shadow_schema_validation_failed`; do not store it |
| Missing/duplicate/unknown five-body or four-joint identity | `shadow_schema_validation_failed` |
| Session, simulation, model, rig, or calibration mismatch | `shadow_identity_mismatch` |
| Authority epoch changes inside one simulation epoch | `stale_shadow_epoch` |
| Sequence or physics tick does not strictly increase | `stale_shadow_tick` |
| Monotonic clock moves backwards | `stale_shadow_clock` |
| Terrain generation moves backwards, or epoch/revision regresses within a generation | `stale_shadow_terrain` |
| Non-rigid or left-handed body matrix | `invalid_shadow_transform` |
| More than 60 messages in one second | `rate_limited` |
| Disconnect/runtime stop/model switch | Clear the per-session latest slot |

Every rejection leaves product simulation and view state unchanged. Three WebSocket
violations retain the existing v3 close policy.

Terrain identity is Godot-local observational identity in this phase. Python does
not compare it to Python terrain state; it only enforces monotonicity within the
shadow stream so the diagnostic cannot silently splice two terrain histories.

## 5. Good / Base / Bad Cases

- Good: `jolt_shadow` publishes the latest SY205/SY135 snapshot at 30 Hz; Python
  validates and exposes it only as health diagnostics.
- Base: `python_kinematic` publishes no shadow traffic and behaves exactly as the
  pre-migration product.
- Bad: copying shadow body transforms into `Simulator`, `_motion_view`, or
  `MotionPresentation`, sending `jolt_authoritative` through this transport, or
  silently substituting another model's rig.

## 6. Tests Required

- JSON Schema validation for both rig descriptors and truth snapshots.
- Coordinate translation, swing/hinge axes, vector, determinant, and round-trip.
- Immutable copy-in/copy-out snapshot behavior and latest-value overwrite.
- Negotiation, wrong identity, stale tick/epoch/clock, malformed matrix, size/rate,
  TTL, disconnect, stop, reset, and model-switch cleanup.
- Explicit assertion that accepted shadow does not change Python joint/frame state.
- Explicit assertion that an otherwise valid `jolt_authoritative` snapshot is
  rejected before entering the latest-value slot.
- Godot 4.7.1 Jolt API/contact/direct-state/cleanup probe and live Godot MCP smoke
  for both model identities.

## 7. Wrong vs Correct

Wrong:

```python
runtime.simulator.restore(shadow.snapshot)  # creates a second pose writer
```

Correct:

```python
sample = decode_shadow_truth(message.snapshot, expected_identity)
runtime.submit_shadow_truth(session_id, sample)  # isolated diagnostic slot only
```

## Design Decision

The truth schema/version family is independent from `view_state`, while its
transport uses one negotiated optional v3 envelope. This preserves the existing
Python pose schema and lifecycle while allowing strict shadow validation and a
one-capability rollback. Jolt authority may be enabled only in bounded phases
after their single-writer and contact exit gates pass. Phase 1 has passed that
gate for chassis/tracks only; it does not widen this transport.
