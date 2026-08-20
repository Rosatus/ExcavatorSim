# Design: Godot standalone product and optional Python gateway

## 1. Boundary Decision

The product process is Godot. Python is never its launcher, parent process, or required control plane.

```
operator input + UI
        |
        v
Godot ProductSession  ---- optional observations ----> Python Gateway
        |                                           (separate process)
        +--> lifecycle / model / local identity
        +--> Jolt chassis + bounded articulation
        +--> TerrainState / BucketSoilState
        +--> presentation + local truth

Explicit compatibility only:
Godot ProductSession <---- view_state / lifecycle ---- Python Pinocchio runtime
```

`ProductSession` is a local facade selected by `simulation/authority_profile`:
- `jolt_authoritative`: owns lifecycle, model, input, epoch and generation.
- `python_kinematic` / `jolt_shadow`: projects explicitly enabled `MotionClient` compatibility session while preserving wire guards.

The optional Gateway transport is not a local authority implementation and no local `hello_ack` is fabricated.

## 2. Godot Control Plane

Introduce a root sibling such as `ProductSession` with:
```
signal lifecycle_changed(lifecycle, authority_epoch, generation)
signal authority_changed(session_id, authority_epoch, generation)
signal model_changed(model_id)
signal status_changed(snapshot)

request_start() -> bool
request_pause() -> bool
request_reset() -> bool
request_model_switch(model_id) -> bool
get_equipment_input_axes() -> Vector4
get_status_snapshot() -> Dictionary
```

For local authority, the session publishes a stable local `session_id`, creates an opaque authority epoch at startup, increments generation on invalidating transitions, and rotates epoch on reset/model replacement. Lifecycle commands apply at a fixed-step boundary. Reset ends `stopped`; the operator must issue Start again.

Input registration/reading moves behind this facade. The Jolt controller accepts commands only when lifecycle is `running` and focus is valid. Test setters remain explicit and test-only.

## 3. Consumer Migration

- `OperatorUI` invokes `ProductSession`, renders local authority/lifecycle/model, and renders Gateway as a separate diagnostic.
- `TrackedChassisController` gets equipment input and lifecycle gates from `ProductSession`; it no longer treats MotionClient readiness as local authority.
- `MotionPresentation` receives model activation from ProductSession; Python pose frames remain only in explicit compatibility profiles and Jolt snapshots remain default.
- `ExcavationWorld`, soil effects, and reset consumers use local authority/world invalidation rather than transport reconnect/pose-clear events.
- `SimulationTruthPublisher` uses ProductSession identity for local truth; transport fields are added only at the Gateway adapter boundary.

Signals connect before initial model activation. Model switching validates local catalog/manifest/rig/soil contracts before committing, then tears down the old Jolt runtime and clears derived interaction state.

## 4. Transport Modes

Add:
```
gateway/enabled = false
gateway/endpoint = ws://127.0.0.1:8765/ws
gateway/auto_reconnect = false
```

Disabled startup performs no preflight, socket construction, polling, or retry. Enabling it is explicit. Disconnect affects only diagnostics and pending observations.

`MotionClient` remains the protocol adapter name to preserve explicit compatibility. Its default authority responsibilities move to `ProductSession`.

## 5. Python Packaging And Launchers

- Remove ambiguous Pixi `start` product launcher.
- Add `start-gateway` for `--runtime-profile gateway-only`.
- Keep `start-python-kinematic`, `start-motion-only`, and `start-legacy`.
- Define lightweight Gateway and compatibility Pixi features/environments. Gateway contains aiohttp/JSON validation and imported dependencies, not Pinocchio/Rerun compatibility packages.
- Gateway continues health/model/telemetry APIs; in `jolt_authoritative` it cannot send pose or lifecycle into ProductSession.

## 6. Compatibility And Rollback

Protocol schema/version stays unchanged. Explicit Python profiles retain handshake, `view_state`, generation, and input safety. Local session can be reverted independently, Gateway opt-in can be enabled without changing pose authority, and environment separation can be reverted without source deletion. No automatic network fallback; local contract failure reports error and remains stopped.

## 7. Validation Strategy

### Godot
- New `offline_product_test.gd` runs the real main scene with no listener, proving zero transport attempts plus valid local model/Jolt/truth status.
- Exercise stopped -> running -> paused -> reset, focus loss, SY205 -> SY135 -> SY205, one runtime/visible model, truth identity and derived-state clearing.
- Disconnect an explicitly enabled fake Gateway transport and assert local state unchanged.

### Python and packaging
- Gateway tests fail if it imports/constructs Pinocchio or publishes `view_state`.
- Launcher/environment tests assert gateway and compatibility commands select intended profiles and Gateway has no explicit Pinocchio dependency.
- Existing fake WebSocket compatibility tests continue.

### Release
- Run standalone matrix and rendered offline smoke first.
- Run Gateway smoke and full compatibility verification as separately named backend evidence.
- Inspect exported artifact/manifest for no backend, URDF, Python, or Pixi runtime input.

