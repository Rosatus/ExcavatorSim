# Godot standalone product and optional Python gateway

## Goal

Make the Godot application the complete default ExcavatorSim product: it must start, select either excavator, accept operator input, run lifecycle commands, simulate with the existing Jolt-authoritative hybrid, excavate, reset, and show truth/status without Python, Pixi, Pinocchio, or a listener on port 8765.

Python becomes an independently launched, optional gateway for telemetry, future external-device/protocol bridges, diagnostics, and explicitly selected compatibility profiles. The Pinocchio simulator remains recoverable source and test coverage, but is archived from the default product path rather than deleted.

## Background

- `godot/client/project.godot` already selects `Jolt Physics` and `simulation/authority_profile="jolt_authoritative"`.
- The Jolt chassis, bounded four-axis equipment kinematics, terrain, excavation, bucket inventory, presentation, and local truth already run in Godot. Python `gateway-only` does not construct Pinocchio or publish pose.
- The remaining default dependency is control-plane coupling: `MotionClient` automatically connects/reconnects, lifecycle and model-selection UI commands require a ready socket, several consumers use its session identity, and `pixi run start` launches the Python gateway rather than the product.
- The approved product boundary is **Godot standalone product + optional Python gateway + archived Pinocchio compatibility**. A fake local `hello_ack` or silent fallback to Python pose is not acceptable.

## Requirements

### R1. Standalone product is the default

- The supported product entry points are the Godot editor, the Godot project, and an exported ExcavatorSim executable.
- Starting the product performs no HTTP/WebSocket preflight and schedules no reconnect unless the optional gateway is explicitly enabled.
- Product startup and exported runtime require no Python, Pixi, backend static page, URDF, or Pinocchio installation.
- `pixi run start` must no longer represent or ambiguously launch the product.

### R2. Godot owns the local product session

- Add one Godot-local control-plane owner for lifecycle, authority identity, active model, generation/epoch changes, focus-safe equipment input, and status projection.
- The initial local lifecycle is `stopped`. `Start` enables operator motion; `Pause` stops track and equipment motion; `Reset` restores chassis, articulation, terrain/bucket transient state, rotates the local epoch, and remains deterministic about its resulting lifecycle.
- The local authority identity is explicit and must not be synthesized by injecting a Python `hello_ack` into `MotionClient`.
- Focus loss and lifecycle states other than `running` must zero track and equipment commands.

### R3. Local model switching

- SY205 and SY135 selection must work without a network connection by using the packaged model catalog, visual manifest, physics-rig descriptor, and soil contract.
- A switch is atomic: consumers clear stale pose/contact/bucket-derived state, exactly one visual model and one Jolt runtime remain, and truth/status identity matches the selected model.
- Contract failure must fail closed; it must not retain a visible or active cross-model fallback.

### R4. Gateway is optional and independent

- Provide an explicit `start-gateway` command for Python `gateway-only`. Its absence or disconnect cannot pause, reset, switch, or otherwise mutate the local product session.
- Gateway connection is opt-in configuration. When enabled, it may receive bounded sensor/bucket telemetry and expose diagnostics; it remains observational for the default Jolt-authoritative profile.
- UI distinguishes local product authority/lifecycle from gateway transport state. It must not say `waiting for Python` when local authority is ready.
- A gateway reconnect may rotate transport/session identity but may not rotate local simulation authority or clear valid local product pose/world state.

### R5. Pinocchio compatibility is archived, not destroyed

- `python_kinematic`, `jolt_shadow`, `motion-only`, and `legacy` remain explicitly named compatibility/diagnostic paths with existing protocol contracts and targeted regression tests.
- No product-default code path imports a Pinocchio-backed model, starts the Python simulator thread, or consumes Python `view_state`.
- Separate the lightweight gateway environment/launcher from the Pinocchio compatibility environment so installing or running the gateway does not require Pinocchio.
- Do not delete URDFs, legacy recording/replay/terrain code, or migration history.

### R6. Documentation and release semantics

- README, architecture, Godot integration, release checks, and Trellis specs must describe Godot as the product and Python as optional infrastructure.
- Release evidence must include a real offline-default Godot run. Gateway and Pinocchio checks remain separately identified and cannot be prerequisites for launching the product.

## Acceptance Criteria

- [ ] With no service on `127.0.0.1:8765`, opening `godot/client/project.godot` runs the main scene without preflight/reconnect attempts or transport errors.
- [ ] The offline product starts `stopped`; Start, Pause, Reset and F6/F7/F8 work; no motion is accepted while stopped, paused, or unfocused.
- [ ] Offline SY205 -> SY135 -> SY205 switching leaves one visible model, one Jolt chassis runtime, matching model/rig/truth identity, and no stale bucket/terrain interaction state.
- [ ] Local reset rotates local authority epoch/generation and resets chassis, articulation, terrain/bucket transient state, and effects without Python acknowledgement.
- [ ] UI reports local authority/lifecycle independently from an optional Gateway diagnostic.
- [ ] Enabling Gateway allows telemetry/diagnostics; disconnect during motion does not alter local lifecycle, model, epoch, pose, terrain, or bucket inventory.
- [ ] `pixi run start-gateway` starts only `gateway-only`; compatibility launchers are explicit and Gateway has no Pinocchio dependency.
- [ ] An exported Godot product or equivalent clean-room launch succeeds without Python/Pixi and has no backend/URDF runtime dependency.
- [ ] A new standalone offline integration test is in the Godot matrix; existing Jolt, terrain, excavation, model, transport, backend, and provenance checks pass.
- [ ] Architecture and release docs no longer identify `pixi run start` or Python as the default product launcher.

## Out of Scope

- Deleting Python backend, URDFs, schemas, recording/replay, or Pinocchio implementation.
- Redesigning telemetry or implementing real CAN/ROS/HID/remote-control input.
- Making Gateway a remote pose writer in `jolt_authoritative`.
- Replacing hybrid Jolt plus bounded kinematic equipment with hydraulic/full dynamic simulation.
- Shipping a production installer/updater beyond proving exported artifact independence.

## Risks And Deferred Items

- Compatibility profiles share `MotionClient`; local authority must not leak into explicit Python pose modes.
- Splitting Pixi environments may change command spelling and lock metadata; explicit commands are preferred over ambiguous aliases.
- External-device input belongs behind a future versioned Gateway input contract; this task only leaves the ownership seam.

