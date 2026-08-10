# Godot-first release-candidate boundary

The release candidate keeps two explicit runtime profiles:

- `motion-only`: Python owns kinematics, input safety and lifecycle; Godot owns
  its local deterministic terrain, bucket convenience state and presentation.
- `legacy`: the existing Python terrain, recording and replay services remain
  available for compatibility and protocol regression coverage.

The legacy terrain/recording/replay implementation is intentionally retained in
this milestone. It will only be deprecated or archived after an independently
approved migration plan identifies all clients, telemetry and rollback needs.
No Godot local terrain, bucket volume, particles or physics transforms are sent
back to Python.

Release-candidate checks include the Godot standalone matrix in
`godot/client/tests/README.md`, Godot MCP scene/runtime smoke, and `pixi run
verify` for the backend/provenance/standalone gates.
