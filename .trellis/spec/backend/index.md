# Backend Development Guidelines

The backend is the Python service migrated from BabylonSim. It owns input safety,
the HTTP/WebSocket contract, gateway lifecycle/input/telemetry services, and
explicit Python compatibility profiles. In the product-default
`jolt_authoritative` profile, Godot owns chassis pose locally; the backend does
not publish product pose and the shadow boundary remains observational.

## Guidelines

| Guide | Applies to |
|---|---|
| [Directory Structure](./directory-structure.md) | Where authority modules, tests, schemas, and scripts live |
| [Authority and Concurrency](./authority-and-concurrency.md) | Fixed-rate runtime, terrain workers, lifecycle, and state ownership |
| [Error Handling](./error-handling.md) | Typed validation and recoverable API failures |
| [Quality Guidelines](./quality-guidelines.md) | Formatting, typing, deterministic tests, and forbidden shortcuts |
| [Logging Guidelines](./logging-guidelines.md) | Operational diagnostics and sensitive-data boundaries |
| [Runtime Profiles](./runtime-profiles.md) | Gateway default and explicit Python compatibility service composition |
| [Simulation Truth Shadow](./shadow-truth.md) | Negotiated Godot observation schema, isolation, ordering, and diagnostics |
| [Sensor Telemetry](./sensor-telemetry.md) | Fixed-tick sensor batches, identity/order guards, freshness, and gateway isolation |
| [QML-Compatible CAN Projection](./can-qml-compatibility.md) | QML-canonical pose projection, strict profiles, CAN byte order/EFF handling, and fail-closed behavior |

Pre-development checklist:

- Read the task `prd.md`, `design.md`, and `implement.md` before changing authority behavior.
- Search for existing protocol, terrain, and lifecycle helpers before adding a new one.
- Keep wire identifiers and serialized hashes stable unless a versioned protocol task explicitly changes them.
- Run `pixi run verify` after backend changes.
