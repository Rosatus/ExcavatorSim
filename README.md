# ExcavatorSim

ExcavatorSim is a Windows desktop excavator simulator built around a Godot
Forward+ client and a Python motion/input authority migrated from BabylonSim.

## Current state

The repository contains the completed M1–M7 Godot vertical slice: a real SY205
GLB presentation, Godot-Pinocchio WebSocket motion transport, a Godot-owned
deterministic-enough terrain and excavation loop, visual presentation systems,
and standalone release-candidate checks. Trellis remains the source of project
plans, implementation decisions, and session history.

Python remains authoritative for:

- Pinocchio excavator kinematics and input safety;
- lifecycle state and the Godot-Pinocchio HTTP/WebSocket motion contract;
- the legacy terrain, bucket-volume, recording, and replay services exposed by
  the legacy runtime profile.

In the Godot-first profile, Godot owns desktop rendering, GLB scene assembly,
UI, local terrain and excavation state, and bucket-soil convenience state. The
bounded particles and optional local collision/contact layer are derived
presentation state. None of these client-owned systems may write authoritative
transforms, terrain heights, bucket inventory, or replay cursors back to Python.

## Repository map

- `.trellis/` — project knowledge and active implementation tasks.
- `.codegraph/` — CodeGraph index metadata.
- `backend/` — migrated Python authority (created during migration execution).
- `protocol/` — shared JSON schemas and version manifest.
- `assets/` — visual GLBs, calibration, provenance, and notices.
- `docs/` — concept/engineering architecture, integration, release-candidate, migration, and asset notes.
- `godot/` — the current Godot Forward+ client, scripts, assets, addons, and
  standalone contract tests.

Architecture reading order:

1. [Conceptual architecture](docs/architecture/conceptual.md) — one-page
   explanation for non-technical collaborators.
2. [Engineering architecture](docs/architecture/engineering.md) — components,
   interfaces, authority, signals, timing, assets, tests, and planned hardware.
3. [Specialized contracts](docs/godot-integration.md),
   [release-candidate checks](docs/release-candidate.md), protocol schemas, and
   the relevant Trellis specs.

## Verification and development direction

1. Run `pixi run verify` for the backend lint, type, test, provenance, and
   standalone-path gates.
2. Run `pixi run backend-smoke` and the Godot standalone matrix when changing
   transport, terrain, or client behavior.
3. Keep the legacy and Godot-first runtime profiles compatible until an
   approved integration release-candidate decision selects a migration path.
4. Treat production-grade hydraulics, dynamic rigid-body authority, contact
   calibration, and per-grain soil as deferred model work; evaluate C++ only
   after profiling identifies a measured Python bottleneck.

See `.trellis/` for the current task history and project specifications. Start
with the [conceptual architecture](docs/architecture/conceptual.md), then the
[engineering architecture](docs/architecture/engineering.md), before reading
the specialized client boundary and release-candidate contracts.
