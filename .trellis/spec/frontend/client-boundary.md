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
