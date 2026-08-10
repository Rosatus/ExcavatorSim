# Backend Development Guidelines

The backend is the authoritative Python service migrated from BabylonSim. It owns kinematics, input safety, layered terrain state, bucket volume, replay, and the HTTP/WebSocket contract.

## Guidelines

| Guide | Applies to |
|---|---|
| [Directory Structure](./directory-structure.md) | Where authority modules, tests, schemas, and scripts live |
| [Authority and Concurrency](./authority-and-concurrency.md) | Fixed-rate runtime, terrain workers, lifecycle, and state ownership |
| [Error Handling](./error-handling.md) | Typed validation and recoverable API failures |
| [Quality Guidelines](./quality-guidelines.md) | Formatting, typing, deterministic tests, and forbidden shortcuts |
| [Logging Guidelines](./logging-guidelines.md) | Operational diagnostics and sensitive-data boundaries |
| [Runtime Profiles](./runtime-profiles.md) | Legacy and opt-in motion-only service composition |

Pre-development checklist:

- Read the task `prd.md`, `design.md`, and `implement.md` before changing authority behavior.
- Search for existing protocol, terrain, and lifecycle helpers before adding a new one.
- Keep wire identifiers and serialized hashes stable unless a versioned protocol task explicitly changes them.
- Run `pixi run verify` after backend changes.
