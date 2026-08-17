# Godot Client Boundary

The client owns Godot scene composition, GLB visual transforms, desktop Forward+ rendering, camera/UI, derived terrain mesh, particles, and profile-selected local physics.

The client consumes Python pose/state and lifecycle messages. In legacy Python
terrain/replay compatibility mode it may also consume terrain views, snapshots, patches and
replay lifecycle messages. In the approved Godot-first local-world profile,
`TerrainState` is the sole local terrain authority and the client must not mirror
Python terrain messages into a second store. It must treat missing physics, stale
derived work, reconnect, reset, historical seek, and Return Live as explicit
state transitions.

In `python_kinematic` and `jolt_shadow`, Godot physics is derived presentation
and cannot write product pose. In opt-in `jolt_authoritative`, the Phase 2 Jolt
rig is the sole five-body pose/velocity and four-joint writer. Terrain
deformation, bucket inventory, and replay authority remain outside Jolt.
Physics resources require an explicit adapter/lifecycle boundary and must be
disposed on authority generation changes.

Phase 0 adds an explicit `jolt_shadow` observer without changing the current
writer. `SimulationTruthPublisher` is a root sibling observer and its shadow
output may only enter Python's negotiated diagnostic slot. Phase 2 makes
`jolt_authoritative` a complete articulated, opt-in mode; it produces local
truth but must not send that truth through the shadow transport.

## Godot-first local-world profile

For the first realistic Godot product slice, Python owns motion kinematics,
input safety and lifecycle while Godot owns deterministic-enough terrain/world
state, bucket convenience state and presentation. `TerrainState` keeps stable and
loose Float32 layers; `TerrainRenderer` only consumes copied snapshots and is
generation-gated. This profile is opt-in and coexists with the legacy Python
terrain/replay service until the integration release candidate is reviewed.

`BucketSoilState` is the single local bucket-inventory owner in this profile. In
production, `ExcavationWorld` derives cut, carry, spill, and dump from swept
articulated bucket proxies; direct monotonic cut/deposit queues are test/debug
seams only. The cellular occupancy derives volume, mass, fill, and center of
mass, while `TerrainCommitScheduler` is the sole runtime owner of coarse
`TerrainState` deltas and derived mesh/collider updates. The client may publish
only the optional, latest-value `bucket_load_feedback_v1` observation after
positive capability negotiation; it never publishes terrain edits or replay
authority to Python. `TerrainCollider` is an optional generation-gated static
derivative, disabled/fail-open by default. Missing or failed local physics
cannot block terrain edits or motion presentation.

## Scenario: Legacy Godot-local tracked chassis locomotion

### 1. Scope / Trigger

Use this contract when adding or changing crawler travel without extending the
Python four-axis articulation protocol.

### 2. Signatures

```text
TrackedLocomotionState.configure(parameters: Dictionary) -> bool
TrackedLocomotionState.step_fixed(delta: float, height_sampler: Callable) -> bool
TrackedChassisController.set_controller_enabled(value: bool) -> void
TrackedChassisController.submit_bucket_support_contact(contact: Dictionary) -> void
TrackedChassisController.raw_world_transform(world_transform: Transform3D) -> Transform3D
TrackedChassisController.get_status_snapshot() -> Dictionary
```

The local actions are `track_left_forward`, `track_left_reverse`,
`track_right_forward`, and `track_right_reverse`. They never enter the Python
`Vector4` articulation snapshot.

### 3. Contracts

- `ChassisMotionRoot` is the only writer of the Godot-local chassis transform.
  `PresentationRoot`, the active GLB, and all named articulation frames remain
  below it.
- Bucket ground support is a bounded presentation offset owned by the same
  controller. It composes after `TrackedLocomotionState.chassis_transform` and
  before visual children; no second node may write the chassis root.
- `ExcavationWorld` classifies rear/shell support from the model proxy and
  authoritative heightfield, then submits an identity-tagged contact sample.
  It must convert proxy transforms through `raw_world_transform()` before
  measuring penetration so the prior support offset cannot feed itself.
- The support response is limited to local heave/pitch/roll. It cannot edit
  `TerrainState`, `BucketSoilState`, Python joint pose, or replay state. Missing
  or stale Jolt data degrades to the coarse heightfield; feature disablement and
  lifecycle resets decay/clear the offset without changing locomotion state.
- `MotionPresentation` composes the Python base delta as
  `ChassisMotionRoot * base_delta * rest_presentation_local`; it must not write
  a global base transform that cancels the moving parent.
- The controller is disabled by default. Disabling it restores
  `ChassisMotionRoot` to identity and clears track commands and velocities.
- Each model descriptor must provide track/contact dimensions, independent
  front/rear/left/right support offsets, speed/acceleration/brake/coast values,
  pivot scale, slope limits, slip coefficients, minimum traction, and support
  response rate. An incomplete descriptor rejects that model without fallback.
- `TerrainState.sample_surface_bilinear_at()` is the support-height authority.
  A `TerrainCollider` ray hit may refine the same height only when its applied
  `(world_generation, terrain_revision)` exactly matches `TerrainState` and the
  hit belongs to that derived collider. A miss, stale identity, unavailable
  physics, or excessive height mismatch returns the authoritative heightfield.
- Focus loss, transport pose clear/reconnect, model activation, world reset,
  controller disable, or invalid terrain stops both tracks. Model/world changes
  also restore the local chassis transform to identity.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Missing/invalid model field | Reject model; no cross-model parameter fallback |
| Height sample outside logical grid | Reject fixed step and stop both tracks |
| Jolt collider disabled/unavailable | Continue from bilinear heightfield |
| Collider identity is stale | Ignore raycast and continue from heightfield |
| Matching derived ray hit | Accept only a bounded height-compatible hint |
| Focus/reconnect/model/world reset | Clear commands and velocities; reset pose where required |

### 5. Good / Base / Bad Cases

- Good: independent track actions -> fixed-step skid steer -> one chassis root ->
  composed Python articulation.
- Base: local physics disabled -> identical heightfield-driven locomotion.
- Bad: track input is added to the Python articulation vector, or a raycast
  mutates/invents terrain state.

### 6. Tests Required

- Fixed-step tests assert straight, arc, pivot, coast, braking, reversal, slope,
  out-of-grid stop, and separately validated SY205/SY135 parameters.
- Scene tests assert the single chassis root and Python base composition.
- A real Jolt collider test asserts matching-hit use plus disabled and stale
  identity fallback.
- Lifecycle tests assert reconnect, model activation, world reset, focus loss,
  and controller disable clearing behavior.
- Godot MCP must drive the four actions and switch both production models in a
  live backend session.

### 7. Wrong vs Correct

```text
Wrong: MotionPresentation writes base_link.global_transform and cancels chassis travel
Correct: ChassisMotionRoot owns travel; MotionPresentation composes below it
```

## Scenario: Jolt-authoritative articulated equipment and tracks

### 1. Scope / Trigger

Use this contract only when `simulation/authority_profile` is explicitly
`jolt_authoritative`. The default remains `python_kinematic`; this profile moves
the chassis, slew, boom, arm, and bucket together under one Jolt runtime.

### 2. Signatures

```text
JoltChassisTrackRuntime.configure(descriptor, terrain_world, terrain_collider, spawn_global_transform) -> bool
JoltChassisTrackRuntime.set_commands(left: float, right: float) -> void
JoltChassisTrackRuntime.set_equipment_commands(commands: Vector4, identity: int = -1) -> void
JoltChassisTrackRuntime.set_bucket_payload(mass_kg: float, center_of_mass_local: Vector3, identity: int) -> bool
JoltChassisTrackRuntime.stop_motion() -> void
JoltChassisTrackRuntime.reset(spawn_global_transform: Transform3D) -> void
JoltChassisTrackRuntime.teardown() -> void
JoltChassisTrackRuntime.get_post_step_snapshot() -> Dictionary
JoltChassisTrackRuntime.get_status_snapshot() -> Dictionary
MotionPresentation.apply_physics_snapshot(snapshot: Dictionary) -> bool
PhysicsRigDescriptor.is_valid_for(model_id: String, model_version: String) -> bool
```

`TrackedChassisController` selects this runtime by profile and remains the only
adapter allowed to copy its body transform onto `ChassisMotionRoot`.

### 3. Contracts

- `JoltChassisTrackRuntime` owns exactly five `RigidBody3D` nodes and four
  `HingeJoint3D` nodes as one open chain. The controller applies the captured
  chassis transform to `ChassisMotionRoot`; no presentation or Python frame may
  write a physics body or the same root in this profile.
- Each model must pass its own hash-bound `physics-rig-v1` descriptor. It
  requires explicit rigid rest transforms, parent/child anchors, unit axes,
  finite limits, actuator torque/velocity/acceleration/jerk/damping, payload COM,
  collision layers and an explicit self-collision mode. Current provisional box
  proxies require `disabled_provisional`; do not silently enable overlapping
  non-adjacent machine collisions.
- The accepted four-axis command is sampled once per fixed tick. Stale command
  identity is ignored, invalid input disarms, and every rebuild requires a
  neutral sample before effort. Godot's positive hinge-motor parameter is
  inverted exactly once at the Jolt adapter because the descriptor, GLB and
  truth contracts use right-handed declared-axis signs.
- Joint target velocity is jerk/acceleration shaped, target position is
  limit-anticipated, and damping-derived effort is clamped to `max_torque_nm`.
  The snapshot reports target, actual position/velocity and applied effort.
- `BucketSoilState` remains payload authority. The controller submits mass,
  local COM and monotonic material identity; the runtime applies them only at a
  tick boundary and truth reports the applied, not merely requested, payload.
- Each track uses four distributed ray contact points. Longitudinal drive,
  braking, coast, lateral resistance, slip, and differential yaw torque are
  bounded before forces are applied to the body.
- Track raycasts may hit only the project `TerrainCollider`, and forces activate
  only when its applied `(world_generation, terrain_revision)` matches the
  current `TerrainState`. The heightfield remains the logical terrain authority.
- `TrackedChassisController` may materialize the collider only during initial
  rig activation and world reset. `TerrainCommitScheduler` remains the sole
  normal terrain-revision writer for render/collider derivatives; the Jolt
  runtime stops forces during any identity gap rather than rebuilding a second
  collider path.
- Focus loss, reconnect/pose clear, reset, model switch, invalid rig, invalid
  terrain identity, profile exit, and tree teardown stop commands/forces and
  clear or rebuild the complete rig without a same-frame writer handoff.
- The runtime captures one post-step snapshot. `MotionPresentation` derives GLB
  local pivot twists from its five body transforms, and
  `SimulationTruthPublisher` serializes those same five body/four joint values
  directly. Neither consumer may re-read live physics nodes. SY205's passive
  four-bar runs after physical arm/bucket pivots and remains visual-only.
- Ray probes and `get_colliding_bodies()` do not expose a Jolt contact
  manifold, so zero impulse/penetration fields require
  `jolt_contact_manifold_unavailable`. `transport_publishing` must remain false.
- The legacy `BucketGroundLiftReaction` must be disabled in authoritative mode;
  physical body/terrain reaction is the only lift path. Terrain mutation still
  remains Phase 3 work.
- SY205/SY135 mass, inertia and collision proxy values remain provisional tuning
  evidence. Phase 2 validates finite articulated behavior, not production
  hydraulic fidelity, contact calibration or cutover readiness.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Default/unknown profile | Keep Python path, or fail closed for unknown value; never auto-select Jolt |
| Missing/hash-mismatched/invalid rig | Reject model and destroy any old dynamic runtime; no cross-model fallback |
| Collider unavailable or identity stale | Stop track force activation and report quality/identity failure |
| Python pose arrives in authoritative mode | Reject the pose write; retain the latest Jolt snapshot |
| Non-neutral first command after rebuild | Hold zero effort until a neutral sample arrives |
| Stale equipment command identity | Ignore without changing current command state |
| Invalid payload mass/COM/identity | Reject without changing the applied bucket mass properties |
| Track command outside `[-1,1]` | Clamp before force calculation |
| Speed/angular limit reached | Clamp body velocity and report a quality flag |
| Disconnect/reset/model switch/profile exit | Zero commands and teardown or rebuild the body and contact state |
| Authoritative truth offered to Python shadow decoder | Reject with `shadow_schema_validation_failed` |

### 5. Good / Base / Bad Cases

- Good: explicit profile -> validated model rig -> matching terrain collider ->
  five-body/four-joint post-step snapshot -> visual pivots and local truth.
- Base: default profile -> unchanged Python pose writer and no dynamic chassis rig.
- Bad: apply Python base transform after the Jolt step, accept a stale terrain
  collider, or relabel authoritative truth as a shadow message.

### 6. Tests Required

- Real Godot 4.7.1/Jolt tests cover both models settling, straight travel,
  braking, reversing, pivoting, bounded slope/mound traversal, speed/energy
  bounds, stale terrain rejection, model switch, and teardown.
- Articulation tests assert five bodies/four joints, both command directions,
  limits, target/actual/effort telemetry, neutral re-arm, stale identity,
  payload mass/COM and zero residual bodies/joints for SY205 and SY135.
- Controller/presentation tests assert exactly one writer, Python pose rejection,
  empty pivot diagnostics and visual-only SY205 passive linkage.
- Truth tests assert five body/four joint/contact/track/terrain/payload fields,
  epoch rotation, local publishing, and `transport_publishing=false`.
- Schema/backend tests assert descriptor strictness and reject
  `jolt_authoritative` on the negotiated shadow transport.
- The standalone force step must remain below the 10 ms acceptance budget in
  the bounded test scene; MCP smoke verifies live rig/contact/model identity.

### 7. Wrong vs Correct

```text
Wrong: Python view_state + Jolt body both write ChassisMotionRoot
Correct: profile gate selects one writer; Jolt-authoritative ignores Python pose writes

Wrong: presentation and truth independently sample live RigidBody3D nodes
Correct: both consume the runtime's single post-step snapshot
```

### Terrain3D derived-backend contract

`Terrain3DAdapter` is an optional presentation/collision backend, not a second
authority. Its public seam is:

```text
queue_snapshot(snapshot: Dictionary) -> bool
apply_pending() -> bool
set_collision_mode(mode: int) -> bool
get_status_snapshot() -> Dictionary
```

The snapshot must contain `terrain_epoch`, `terrain_revision`,
`world_generation`, `rows`, `columns`, `spacing_m`, `origin_xz`, `surface`, and
`surface_bytes`. The adapter deep-copies `surface` and `surface_bytes`, rejects
older `(epoch, generation, revision)` work, and only marks `available=true`
after `Terrain3DData.import_images` successfully materializes the accepted
height map. `TerrainState.surface_bytes` and its digest remain the parity oracle;
Terrain3D's internal maps never replace them.

Terrain3D initializes native rendering when the node enters the scene tree.
Configure non-null `assets` and `material` before `add_child()` so the first
Forward+ initialization never observes an incomplete resource graph. Configure
`region_size` and `collision_mask` immediately after `add_child()`: Terrain3D
1.0.2 restores those scalar defaults during enter-tree initialization, so a
pre-tree write may appear accepted and then be overwritten. The production
adapter keeps `region_size=128`; do not infer supported values from a pre-tree
readback.

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
| Map import succeeds | hide custom mesh and foundation ground only after native snapshot is applied |
| Native work becomes pending/fails | restore custom mesh and foundation ground immediately |
| Collision disabled or fails | `collision_available=false`; excavation/motion continue |

#### Wrong vs correct

```text
Wrong: bucket contact -> Terrain3D editor sculpt -> infer bucket volume later
Correct: bucket command -> BucketSoilState/TerrainState -> copied snapshot -> Terrain3D
```

## Scenario: Construction-site Terrain3D presentation

### 1. Scope / Trigger

Use this contract when a Terrain3D presentation is larger or visually richer
than the authoritative `TerrainState` grid.

### 2. Signatures

```text
ConstructionSiteTerrainProfile.build_maps(snapshot: Dictionary) -> Dictionary
ConstructionSiteTerrainProfile.create_assets() -> Object
ConstructionSiteTerrainProfile.build_dressing(maps: Dictionary) -> Dictionary
```

`Terrain3DAdapter` remains the only runtime consumer that imports these maps
into Terrain3D.

### 3. Contracts

- The default presentation is 129 × 129 samples at 0.5 m spacing (64 m × 64 m).
- Every central logical-grid sample is copied exactly from the accepted
  `TerrainState.surface`.
- Presentation-only height shaping may occur outside the logical rectangle and
  must never be written back to `TerrainState` or `BucketSoilState`.
- Temporary control-map IDs match official demo assets: 0 cliff/bare ground and
  1 grass. The central logical patch and access path use ID 0.
- The adapter may load a minimal extracted copy of the official demo
  `Terrain3DMaterial`/texture assets and reuse RockA/B/C meshes plus its particle
  scene as an explicitly reviewed temporary visual baseline; demo height data is
  never logical input.
- `godot-terrain-state-v2-flat` initializes the logical surface at zero height.
  Stable/loose edits and reset semantics remain unchanged after initialization.
- Site dressing is bounded to 18 official rocks outside the logical rectangle;
  official grass particles use a 12 m central exclusion radius. Dressing adds
  no collision objects.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Invalid/incomplete logical snapshot | Return an empty presentation; adapter stays fail-open |
| Terrain3D asset classes unavailable | Return no native assets; retain custom renderer |
| Logical grid point sampled in presentation | Height is bit-for-bit equal to the logical surface value |
| Point outside logical rectangle | May receive deterministic presentation shaping/materials only |
| Official demo visual resource unavailable | Adapter stays fail-open and keeps the custom renderer |
| Native Terrain3D backend inactive | Hide the dressing layer with the native terrain |

### 5. Good/Base/Bad Cases

- Good: accepted snapshot → exact central patch + derived spoil piles/track/grass.
- Base: native backend unavailable → unchanged custom renderer/collider path.
- Bad: editor painting or Terrain3D height queries update logical terrain or
  bucket inventory.

### 6. Tests Required

- `construction_site_terrain_test.gd` asserts 64 m dimensions, exact logical
  patch parity, demo material IDs, demo assets, and bounded dressing.
- `terrain3d_adapter_test.gd` asserts the project-owned asset source,
  presentation dimensions, dressing layers, snapshot guards, fallback, and
  Jolt collision seam.
- The full standalone matrix must keep terrain/excavation/release-candidate
  contracts green.

### 7. Wrong vs Correct

```text
Wrong: Terrain3D editor/runtime maps -> infer logical surface and bucket volume
Correct: TerrainState snapshot -> exact logical patch + disposable site context -> Terrain3D
```

The M6 visual layer (`VisualEnvironment`, `CameraRig`, `VisualQualityController`
and bounded `SoilEffects`) is presentation-only. Quality changes may adjust
lighting, camera range, shadow flags and particle budgets, but may not change
simulation cadence, pose transforms, terrain bytes or bucket inventory.

### Sky3D presentation contract

#### 1. Scope / Trigger

Use this contract for the production sky, atmosphere, fog, cloud, and daylight
configuration in the main Godot scene.

#### 2. Signatures

```text
VisualEnvironment.apply_profile(profile_name: String) -> bool
VisualEnvironment.get_visual_snapshot() -> Dictionary
VisualQualityController.apply_profile(profile_name: String) -> bool
```

#### 3. Contracts

- The root node remains named `WorldEnvironment` and uses Sky3D 2.1, a
  `WorldEnvironment` subtype. Project code must not instantiate addon demo
  scenes or replace Sky3D's shader with a second procedural sky.
- `VisualEnvironment` is the only production profile/configuration owner.
  Sky3D uses `TimeOfDay.CelestialMode.SIMPLE` at 10:30 with UTC +7, longitude
  108 degrees and latitude 16 degrees. The resulting SkyDome polar angle is
  19.5 degrees, or about 70.5 degrees solar elevation. Editor/game time,
  system sync, moon/deep-space calculations, and cloud wind remain disabled.
- Sky3D's `SunLight` is the only active daytime directional light. The root
  `KeyLight` path remains as a disabled compatibility seam and may not cast a
  second shadow or contribute energy.
- Low disables Sky3D clouds, screen-space fog, and sun shadows; balanced and
  high enable bounded atmosphere settings. All profiles preserve the existing
  camera/effect budgets and target FPS contract.
- `VisualQualityController` must return `false` and expose an explicit error if
  `VisualEnvironment` cannot apply the requested Sky3D profile. Camera/effect
  budgets may not be reported as applied after that failure.
- Missing Sky3D runtime resources are a project import/verification failure,
  not a reason to silently create a second environment implementation.
- Terrain3D's infinite world background remains disabled while Sky3D owns the
  horizon; the bounded construction terrain and authority seam are unchanged.
- The running client keeps a user-visible credit for the packaged ESO/S.
  Brunier Milky Way textures. Full source/license links remain in `NOTICE.md`
  and the adjacent third-party license file.

#### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Unknown profile | Return `false`; preserve the previous profile |
| Sky3D/environment unavailable | Return `false`; report profile failure |
| Low profile | Disable clouds, Sky3D fog, and sun shadows |
| Balanced/high profile | Enable bounded clouds/fog without time progression |
| Runtime starts | One visible sun, 10:30 SIMPLE daytime, legacy key light inactive |

#### 5. Good / Base / Bad Cases

- Good: project profile -> `VisualEnvironment` -> fixed Sky3D presentation.
- Base: missing Sky3D resource -> explicit import/test failure.
- Bad: quality controller reports success after Sky3D rejected the profile.

#### 6. Tests Required

- `visual_pass_test.gd` asserts SIMPLE 10:30 daylight, high/low profiles,
  disabled time authority, failure propagation, the single sun, horizon, and
  user-visible attribution seam.
- A real Forward+ smoke must inspect the running frame and current-run logs;
  headless state tests do not prove shader, cloud, or horizon rendering.

#### 7. Wrong vs Correct

```text
Wrong: quality profile -> silently skip missing Sky3D -> report success
Correct: quality profile -> VisualEnvironment -> Sky3D or explicit failure
```

The M7 release candidate retains the legacy Python terrain/recording/replay
profile for compatibility; removal or deprecation requires a separate approved
migration decision and client inventory.

Reference: `docs/godot-integration.md`, `protocol/`, and `.trellis/tasks/08-06-excavator-sim-bootstrap/design.md`.
