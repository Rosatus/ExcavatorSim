# Godot Client Boundary

The future client owns Godot scene composition, GLB visual transforms, desktop Forward+ rendering, camera/UI, derived terrain mesh, particles, and optional local static colliders/contact probes.

The client consumes Python pose/state and lifecycle messages. In legacy Python
terrain/replay compatibility mode it may also consume terrain views, snapshots, patches and
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

### Terrain3D derived-backend contract

`Terrain3DAdapter` is an optional presentation/collision backend, not a second
authority. Its public seam is:

```text
queue_snapshot(snapshot: Dictionary) -> bool
apply_pending() -> bool
get_status_snapshot() -> Dictionary
```

The snapshot must contain `terrain_epoch`, `terrain_revision`,
`world_generation`, `rows`, `columns`, `spacing_m`, `origin_xz`, `surface`, and
`surface_bytes`. The adapter deep-copies `surface` and `surface_bytes`, rejects
older `(epoch, generation, revision)` work, and only marks `available=true`
after `Terrain3DData.import_images` successfully materializes the accepted
height map. `TerrainState.surface_bytes` and its digest remain the parity oracle;
Terrain3D's internal maps never replace them.

Terrain3D can create static collision shapes, while the project-selected Jolt
backend answers Godot raycasts and contacts. Collision is disabled/fail-open by
default (`terrain3d/collision_mode=0`); enabling it must not change logical
excavation or motion behavior. A missing GDExtension, failed map update, or
failed collision setup keeps `TerrainRenderer`/`TerrainCollider` usable.

#### Validation & error matrix

| Condition | Required behavior |
|---|---|
| Native class unavailable | `available=false`; retain custom renderer |
| Invalid dimensions/bytes | reject snapshot without mutating authority |
| Stale epoch/generation/revision | reject queue; preserve newer pending work |
| Map import succeeds | hide custom mesh only after native snapshot is applied |
| Collision disabled or fails | `collision_available=false`; excavation/motion continue |

#### Wrong vs correct

```text
Wrong: bucket contact -> Terrain3D editor sculpt -> infer bucket volume later
Correct: bucket command -> BucketSoilState/TerrainState -> copied snapshot -> Terrain3D
```

The M6 visual layer (`VisualEnvironment`, `CameraRig`, `VisualQualityController`
and bounded `SoilEffects`) is presentation-only. Quality changes may adjust
lighting, camera range, shadow flags and particle budgets, but may not change
simulation cadence, pose transforms, terrain bytes or bucket inventory.

The M7 release candidate retains the legacy Python terrain/recording/replay
profile for compatibility; removal or deprecation requires a separate approved
migration decision and client inventory.

Reference: `docs/godot-integration.md`, `protocol/`, and `.trellis/tasks/08-06-excavator-sim-bootstrap/design.md`.
