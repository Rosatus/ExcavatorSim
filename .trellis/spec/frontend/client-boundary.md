# Godot Client Boundary

The future client owns Godot scene composition, GLB visual transforms, desktop Forward+ rendering, camera/UI, derived terrain mesh, particles, and optional local static colliders/contact probes.

The client consumes Python pose/state and lifecycle messages. In legacy BabylonSim
compatibility mode it may also consume terrain views, snapshots, patches and
replay lifecycle messages. In the approved Godot-first local-world profile,
`TerrainState` is the sole local terrain authority and the client must not mirror
Python terrain messages into a second store. It must treat missing physics, stale
derived work, reconnect, reset, historical seek, and Return Live as explicit
state transitions.

Godot physics is local presentation in the first release. It must never become the source of excavator joint state, terrain deformation, bucket inventory, or replay authority. Physics resources require an explicit adapter/lifecycle boundary and must be disposed on authority generation changes.

## Godot-first local-world profile

For the first realistic Godot product slice, Python owns motion kinematics,
input safety and lifecycle while Godot owns deterministic-enough terrain/world
state, bucket convenience state and presentation. `TerrainState` keeps stable and
loose Float32 layers; `TerrainRenderer` only consumes copied snapshots and is
generation-gated. This profile is opt-in and coexists with the legacy Python
terrain/replay service until the integration release candidate is reviewed.

`BucketSoilState` is the single local bucket-inventory owner in this profile. It
applies explicit, monotonic cut/deposit commands at fixed steps and accounts for
the exact grid-cell volume changed by `TerrainState`; it never publishes that
inventory or local terrain edits to Python. `TerrainCollider` is an optional
generation-gated static derivative, disabled/fail-open by default. Missing or
failed local physics cannot block terrain edits or motion presentation.

Reference: `docs/godot-integration.md`, `protocol/`, and `.trellis/tasks/08-06-excavator-sim-bootstrap/design.md`.
