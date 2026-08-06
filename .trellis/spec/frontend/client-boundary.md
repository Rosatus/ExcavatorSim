# Godot Client Boundary

The future client owns Godot scene composition, GLB visual transforms, desktop Forward+ rendering, camera/UI, derived terrain mesh, particles, and optional local static colliders/contact probes.

It consumes Python pose/state, terrain views, snapshots, patches, epoch/revision identity, and replay lifecycle messages. It must treat missing physics, stale patches, reconnect, historical seek, reset, and Return Live as explicit state transitions.

Godot physics is local presentation in the first release. It must never become the source of excavator joint state, terrain deformation, bucket inventory, or replay authority. Physics resources require an explicit adapter/lifecycle boundary and must be disposed on authority generation changes.

Reference: `docs/godot-integration.md`, `protocol/`, and `.trellis/tasks/08-06-excavator-sim-bootstrap/design.md`.

