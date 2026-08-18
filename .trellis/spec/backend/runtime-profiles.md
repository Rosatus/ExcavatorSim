# Runtime Profiles

## 1. Scope / Trigger

This contract applies when the standalone service is started for the Godot
motion vertical slice. The product default is a gateway-only process because
Godot/Jolt owns product pose, contact, terrain and payload; Python kinematic
profiles remain explicit compatibility launchers.

## 2. Signatures

```python
RuntimeController(model, calibration, *, profile: Literal["legacy", "motion-only"] = "legacy")
GatewayRuntimeController(descriptor, *, profile: Literal["gateway-only"] = "gateway-only")
create_runtime(model, calibration, *, profile: RuntimeProfile = "legacy")
```

The CLI accepts `--runtime-profile {gateway-only,legacy,motion-only}`.
`pixi run start` selects `gateway-only`; `pixi run start-legacy` selects the
full Python compatibility service and `pixi run start-python-kinematic` selects
the explicit motion-only Pinocchio service. `start-motion-only` remains an
alias.

## 3. Contracts

- Gateway-only constructs no `Simulator`, Pinocchio model, recording, terrain,
  replay or exchange service. It owns only lifecycle, input lease validation,
  model identity and bounded observational telemetry stores. It advertises
  `input_snapshot`, `commands`, `bucket_load_feedback_v1`, and
  `sensor_telemetry_v1`; it never emits `view_state`.
- Legacy constructs recording, terrain, replay and exchange services and
  advertises `input_snapshot`, `commands`, `latency`, `playback`, `recording`,
  and `terrain` after hello capability intersection.
- Motion-only constructs only `Simulator`, `InputRouter`, the fixed-rate thread,
  and a local view projection. It advertises exactly `input_snapshot` and
  `commands` when requested.
- Both profiles keep the existing `hello_ack` and `view_state` identifiers and
  required fields. Motion-only projects schema-required recording/playback
  metadata as diagnostics (`source_mode=live`, `playback_state=following`);
  those fields are not a recording authority.
- Motion-only emits `view_state` only. It must not emit `terrain_view`,
  `terrain_patch`, or `recording_status`.

## 4. Validation & Error Matrix

| Condition | Required response |
|---|---|
| Unknown `RuntimeController.profile` | Raise `ValueError` before starting workers. |
| Motion-only HTTP recording/terrain route | Return HTTP conflict with `capability_unavailable`; do not mutate motion state. |
| Motion-only WebSocket playback/terrain command | Send recoverable `error` with code `capability_unavailable` and request ID. |
| Motion-only reset | Publish a new `simulation_epoch` and monotonic view revision. |
| Motion-only stop/disconnect | Stop the fixed-rate thread, clear pending lifecycle futures/input lease/cache, and leave no optional worker. |
| Legacy profile | Preserve existing route/message behavior and full capability set. |

## 5. Good / Base / Bad Cases

- Good: start with `--runtime-profile motion-only`, negotiate only the two
  implemented capabilities, and consume the unchanged `view_state` reducer.
- Base: a client that asks for terrain/recording/playback receives only the
  negotiated motion capabilities and remains usable for motion.
- Bad: instantiate a `TerrainController` or `ReplayWorker` in motion-only just
  to satisfy a route; that reintroduces the worker lifecycle this profile is
  intended to remove.

## 6. Tests Required

- Runtime: assert optional services are `None`, fixed-rate snapshots contain all
  required frames, reset changes epoch/revision, and stop/disconnect are safe.
- WebSocket: assert exact capability intersection, valid view-state metadata,
  no terrain/recording status, and `capability_unavailable` correlation for
  unsupported commands.
- HTTP: assert disabled recording/terrain endpoints fail before authentication
  or service mutation.
- Compatibility: run the full backend suite and the Godot M2 headless/import
  smoke against unchanged protocol/version identifiers.

## 7. Wrong vs Correct

### Wrong

```python
if profile == "motion-only":
    self.terrain = TerrainController(self.recording)
    self.replay = ReplayWorker(...)
```

This creates hidden workers merely because the web layer has legacy routes.

### Correct

```python
if profile == "motion-only":
    self.recording = None
    self.terrain = None
    self.replay = None
    self.exchange = None
```

The web boundary gates optional routes by negotiated capability and the runtime
publishes a schema-compatible live view directly from the authoritative
`RuntimeSnapshot`.

## Authority Migration Profiles

Authority selection is separate from backend service composition:

| Authority profile | Product pose writer | Shadow publisher | Current status |
|---|---|---|---|
| `python_kinematic` | Python `Simulator`/Pinocchio | off | Explicit compatibility |
| `jolt_shadow` | Python `Simulator`/Pinocchio | Godot observational | Implemented opt-in |
| `jolt_authoritative` | Godot hybrid: one Jolt chassis plus kinematic work equipment | off; local truth only | Product default |

Both backend runtime profiles may advertise `simulation_truth_shadow_v1` and
`sensor_telemetry_v1` as optional capabilities. Negotiation only enables the isolated slots in
[shadow-truth.md](./shadow-truth.md); it never changes the runtime's pose writer.
The existing required capability intersection and `view_state` behavior remain
unchanged. Python must reject a `simulation_truth_shadow` payload whose
`authority_profile` is `jolt_authoritative`; authoritative truth is a local
Godot product snapshot, not a second inbound pose stream.

The independent local truth schema distinguishes these shapes by profile:
`jolt_shadow` remains exactly five observational bodies and zero
`kinematic_frames`; `jolt_authoritative` is exactly one `chassis` body and four
named kinematic frames. This conditional shape is a local diagnostic contract
only and does not widen backend runtime composition or WebSocket capabilities.

`sensor_telemetry_v1` is separate from shadow truth: it accepts only
`jolt_authoritative` batches produced by Godot's fixed tick, validates the
session/model/rig/calibration identity and per-stream sequence, and exposes
only bounded latest-value health. It cannot mutate simulator state and is not
part of `view_state` or the legacy RRD schema.
