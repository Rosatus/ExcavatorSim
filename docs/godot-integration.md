# Godot Integration Boundary

## Implemented client baseline

The current client targets Windows desktop with Godot Forward+. It loads the
combined SY205 excavator GLB visual skin and applies the authoritative
named-frame transforms received from Python through the Godot-Pinocchio motion
transport.

## Transport

The Godot client consumes the existing Godot-Pinocchio HTTP/WebSocket contracts
rather than inventing a second authority protocol. The implemented motion slice
covers:

- the realtime state handshake and authoritative motion snapshots;
- input sequence safety, command validation, acknowledgements, and lifecycle
  state;
- session, simulation-epoch, view-revision, reconnect, and stale-state guards.

The Godot-first client owns its local terrain and bucket-soil state, so it does
not mirror legacy Python terrain packets or recording/replay cursors. Those
terrain, recording, replay, and Return-to-Live contracts remain available only
where the legacy Python runtime profile is selected.

### Frame coordinate conversion

The Python Pinocchio/URDF authority publishes right-handed Z-up frame matrices,
while the supplied glTF scene is already exported for Godot's right-handed
Y-up space. The client converts each complete matrix once at the protocol
boundary:

```text
p_godot = (x_python, z_python, -y_python)
T_godot = C * T_python * inverse(C)
```

This maps Python +Z slew to Godot +Y and keeps the Python +X work-equipment
hinges on Godot +X. The SY205 import guide is the asset-side reference for this
mapping; do not add a second global ±90-degree scene rotation or per-pivot axis
swap. The imported GLB parent-local pivot origins are retained; adjacent
converted frame relations provide only the local single-axis joint rotations.

## Authority boundary

Godot remains authoritative for lifecycle and input safety in the standalone
product. The optional Python `gateway-only` runtime validates observational
input/telemetry and does not reconstruct pose. Python is authoritative for chassis/joint pose only
in the explicit `python_kinematic` and `jolt_shadow` compatibility profiles.
The `legacy` Python runtime profile remains authoritative for
terrain layers, bucket inventory, events, recording and replay. The
`motion-only` backend profile supplies the motion/input contract to the
Godot-first local-world client, which keeps deterministic-enough terrain/world
and convenience bucket state in Godot; it does not mirror Python terrain
packets or publish local terrain, physics transforms or replay cursors back to
Python. The two profiles coexist until the integration release-candidate
review selects one runtime contract.

Crawler travel keeps four Godot-local track actions and never extends the Python
four-axis articulation vector. In Python compatibility/shadow profiles,
`TrackedChassisController` retains the legacy local locomotion layer while
Python provides the base/joint pose below `PresentationRoot`. In the default
`jolt_authoritative`, a model-specific `JoltChassisTrackRuntime` owns one dynamic
chassis body and distributed track forces. `KinematicArticulationState` owns the
four bounded work-equipment axes and accepted FK; it creates no boom, arm,
bucket, hinge, hydraulic, or cylinder physics bodies. The controller applies the
captured chassis transform to `ChassisMotionRoot`; `MotionPresentation` rejects
Python pose writes and consumes the same hybrid post-step snapshot used by local
truth. Reset,
reconnect, model activation, world reset, focus loss, invalid rig/terrain, or
profile teardown stops forces and clears or rebuilds the complete dynamic rig.
SY205 and SY135 use separate hash-bound rig and track descriptors with no
cross-model fallback.

The product keyboard maps left-track forward/reverse to `R/F` and right-track
forward/reverse to `Y/H`. XInput-compatible controllers feed the same actions:
LT/LB control the left track forward/reverse and RT/RB control the right track
forward/reverse. Work equipment follows the ISO excavator pattern without
changing the four-axis command order: left stick X/Y controls swing/arm and
right stick Y/X controls boom/bucket. MotionClient replaces the owned key and
joy-axis events with independent active-model direction profiles. The keyboard
profile reverses swing/arm/bucket for SY205 and swing/boom for SY135; the
gamepad profile still reverses all four stick channels for SY205 and only swing
for SY135. ProductSession refreshes both profiles on offline model activation.
The physical keyboard keeps the intended operator outcomes: `W/S` arm out/in,
`A/D` swing left/right, `I/K` boom down/up, and `J/L` bucket curl/dump. Protocol
order, physical joint axes, and joint limits remain unchanged. Jolt does not
assume every visual asset faces local
`-Z`: the optional rig field `tracks.local_forward_axis` defaults to `-Z`, while
SY205 explicitly declares `+Z`. Forward, vehicle right, probe placement,
traction, signed speed, stop cleanup, and pitch telemetry derive from that same
field, so the 180-degree SY205 spawn heading does not turn physical right-front
into visual left-rear.

The excavation path selects one generation-scoped local material owner. The
product default is `active_patch`: `SoilInteractionAuthority` owns the complete
stable/loose -> active -> bucket -> released -> settled ledger and borrows the
product `TerrainState` only through its `TerrainCommitScheduler`. `legacy` keeps
`BucketSoilState` plus parcel transport as an explicit compatibility fallback;
`shadow` runs the conservative chain against an isolated clone while legacy
remains selected.
In authoritative hybrid mode, query-only cutting/opening/cavity/shell/rear
proxies sweep previous-to-candidate bucket FK against the exact applied terrain
collider revision. They own no scene body and cannot inject an uncapped impulse.
The accepted result carries authority/tick/terrain/motion identity and reduces
to one idempotent soil batch: `dump -> spill -> cutting -> carry`, at most one
existing bucket/terrain transaction, and at most one capped next-tick chassis
wrench from shell/rear support. Visible fill, Jolt payload, response shaping,
and truth aggregates come from the selected bounded cellular occupancy. Direct
legacy cut/deposit queues are rejected in active mode and remain compatibility
test/debug seams only.

The per-model soil contract also carries a hash-bound
`bucket-soil-tool-v1` semantic description of the complete bucket: teeth/main
edge, both side cutters, floor/wear plate, outer back/sides, inner shell, and
opening. `SoilContractDescriptor` is the shared presentation/Jolt loader.
`BucketSoilTool` composes bounded previous-to-current swept regions from the
accepted `bucket_link` frame and publishes candidates for cut, side cut, scrape,
push, grade, containment, entry, spill, and dump. Inner/opening regions have no
stable-terrain role. The classifier remains read-only; the generation-selected
authority alone may turn candidates into material transactions.

`legacy`, `shadow`, and `active_patch` requests never hot-switch a live bucket.
Reset, model activation, or an authority/material-generation boundary applies
the requested mode. Active initialization failure may select legacy only before
the clean generation begins; runtime failure pauses material writes and requests
legacy for the next reset. In active mode all legacy parcel material callbacks
are disabled and patch representatives are presentation plus conservative
transport, not a second owner.

The canonical authoritative truth keeps that bucket-query identity structured
as `authority_epoch`, `physics_tick`, terrain generation/revision, and motion
sequence alongside previous/candidate/accepted transforms. Support is limited
to upward shell/rear contact while the bucket moves into the surface, with
180 kN/320 kNm absolute caps, 30 kN/60 kNm per-tick rate caps, a 45-tick
continuous-contact limit, and heave/tilt-rate guards. The duration lock is
released only after contact loss. SY205/SY135 activation atomically replaces
the bucket cell grid; a transient read mismatch fails closed instead of exposing
partial fill data.

The optional `bucket_load_feedback_v1` path is default-disabled. When enabled,
Godot preflights and negotiates it with Python, then sends bounded latest-value
mass, center-of-mass, fill, and resistance observations. It is observational
only and never becomes terrain, replay, or articulation authority.

### Authority migration shadow profile

The project setting `simulation/authority_profile` defaults to
`jolt_authoritative`. Phase 0 also implements opt-in `jolt_shadow`: Python remains
the only product pose writer, while the root-level `SimulationTruthPublisher`
reads post-physics state and queues a negotiated `simulation_truth_shadow_v1`
observation at no more than 30 Hz. The default `jolt_authoritative` profile uses
a dynamic chassis plus kinematic work equipment. It creates local
`simulation-truth-v1` diagnostics from one chassis body, four kinematic frames,
four logical joints, bucket query/support wrench and track/payload state, but
does not queue shadow traffic; Python explicitly rejects authoritative-profile
snapshots at the shadow boundary.

The independent `simulation-truth-v1` payload carries authority epoch, physics
tick, monotonic time, session/model/rig/calibration and terrain identity, body,
kinematic-frame, joint/track/payload/contact fields, and quality flags. Its
schema requires five bodies/zero kinematic frames for `jolt_shadow`, and one
chassis/four named kinematic frames for local `jolt_authoritative`. Godot
converts complete transforms and vectors from internal right-handed Y-up to
canonical right-handed Z-up once in `MotionProtocol`. Python validates schema,
identity, ordering, right-handed rigidity, size, and rate before storing only the
latest sample. The slot expires after 0.5 seconds and clears on disconnect, stop,
or model switch; `/health` is its only Phase 0 consumer.

Both model rig descriptors are validated, versioned, and hash-bound, but their
physical properties remain provisional. Shadow mode marks unavailable body
velocity/contact fields through quality flags rather than inventing values;
authoritative mode reports the chassis body, accepted kinematic FK, joint
targets/positions/velocities, payload load factor, bucket query, queued/applied
support wrench, distributed track contact, slip, saturation, and terrain
identity. No shadow
path calls product transform, terrain, bucket, or lifecycle setters.

When `jolt_authoritative` is selected, the same accepted truth snapshot also
feeds the optional `sensor_telemetry_v1` gateway. Godot publishes four joint
encoders, four declared IMU frames, GNSS, combined track/contact state, and
bucket payload/load at a bounded 30 Hz transport cadence. Each batch retains
the fixed-tick authority epoch/physics tick, model/rig/calibration identity,
per-stream sample sequence, canonical Z-up units, raw value, validity, quality,
and explicit noise metadata. Python only validates and stores the latest batch
with freshness diagnostics; it does not reconstruct pose or write sensor values
into `view_state` or the legacy RRD columns. Local keyboard and Jolt physics
continue when the gateway is absent.

The sample layouts are explicit rather than concatenated ad-hoc values: encoder
is `[position_rad, velocity_rad_s, effort_n]`; each IMU is a 15-value
`[rotation_matrix_3x3, angular_velocity_rad_s, specific_force_m_s2]` vector;
GNSS is `[position_xyz_m, velocity_xyz_m_s]`; track/contact and payload retain
their six- and four-value layouts from the protocol schema. The four IMU stream
IDs are the model-declared `swing_imu_link`, `boom_imu_link`, `arm_imu_link`, and
`bucket_imu_link`; their current Jolt frame sources are the corresponding
upper, boom, arm, and bucket kinematic frames.

For diagnostics, Python exposes a bounded `/api/telemetry?limit=N` export of
accepted batches. This is a telemetry stream, not a replacement for recording
or replay, and it is cleared with the owning session/runtime.

The realistic visual pass uses Sky3D 2.1 behind the project-owned
`VisualEnvironment` seam, plus a generation-gated soil particle emitter and a
bounded camera/quality controller. The root node keeps the stable
`WorldEnvironment` path while Sky3D owns the actual sky shader, SunLight,
SkyDome, fog, and cloud resources. The scene is fixed at 10:30 using Sky3D's
SIMPLE celestial mode (19.5-degree polar angle, approximately 70.5-degree solar
elevation) with editor/game time progression, system synchronization, moon/deep
space calculations, and cloud wind disabled. The legacy root
`KeyLight` remains present but inactive so Sky3D's SunLight is the only daytime
directional light. Low disables clouds/fog/shadows, balanced restores restrained
atmosphere, and high raises the same visual features without altering the 60 Hz
simulation/transport contracts. These are disposable presentation resources;
changing their profile cannot alter motion cadence, terrain snapshots, bucket
volume, replay state, or any Python message. Profile-application failure is
propagated through `VisualQualityController`. The simulation viewport has no
permanent attribution overlay; the complete ESO/S. Brunier Milky Way credit and
license links remain in the packaged NOTICE and adjacent third-party files.

The operator HUD also exposes `Test Grid`. This presentation-only profile reuses
low sky/audio/material-simulation budgets, disables soil particles and all
shared/native site dressing, deactivates Terrain3D textured presentation, and
renders the current authoritative fallback surface with an untextured
black/white one-metre grid. TerrainState, TerrainCollider, Jolt, and soil ledgers
remain unchanged, and disabling the toggle restores the prior product profile.

Terrain3D's optional infinite world background is disabled in this composition;
its generated cliff shell would otherwise cover the Sky3D horizon. The bounded
64 m site terrain, official surface assets, rocks, grass, and logical excavation
contracts remain unchanged.

The camera workflow also provides a model-specific cab first-person preset on
key 5. It follows `upper_structure_link` directly and applies reversible,
per-instance transparency only to the manifest-declared upper-body shell; work
equipment and undercarriage visuals are not modified.

### SY205 passive four-bar linkage

The supplied SY205 import guide defines a Godot-only passive linkage because
the GLB intentionally contains no Blender drivers or animation tracks. After
the authoritative base delta and adjacent local pivots are updated, the client solves in
`PIVOT_ARM_JOINT` local Y-Z space using D=`PIVOT_BUCKET_JOINT`,
B=`PIVOT_LINKAGE_B_ARM`, A=`PIVOT_LINKAGE_A_COMMON` and
C=`PIVOT_LINKAGE_C_BUCKET`. AB and AC are captured from the imported zero pose;
the continuous circle-intersection branch gives A, B rotates around +X, and
`CTRL_LINKAGE_SIDE_LINKS` is positioned/rotated along A-C. A and C are never
written directly. Unreachable poses retain the last valid passive pose and
remain a visual diagnostic; no linkage result is sent back to Python. Nested
pivots must not be updated by independent calibrated world transforms because
that changes the parent-local pin positions and detaches boom/arm/bucket joints.

## Terrain and physics seam

Godot builds a derived render mesh from its selected local surface snapshot.
`TerrainCollider` provides the optional chunked static-collider/contact seam and
is generation-gated, stale-safe, and disabled/fail-open by default. A disabled
or failed physics backend must leave the Python service and visual state usable.

The optional `Terrain3DAdapter` is another derived backend. It receives copied
`TerrainState.surface_snapshot()` data only after the fixed-step logical edit has
been accepted. `TerrainState` keeps the stable/loose Float32 layers, revision
and generation guards, while the selected `SoilInteractionAuthority` or legacy
`BucketSoilState` is responsible for bucket capacity and grid-cell volume
accounting. Terrain3D is therefore a rendering,
heightmap materialization, and optional collision provider; editor sculpting or
direct native height edits are not gameplay mutation paths. If its GDExtension,
map import, or collision mode is unavailable, the custom mesh/collider path
continues to provide the fail-open fallback.

Terrain3D 1.0.2 performs native setup on enter-tree. The adapter assigns
non-null assets/material before adding the node, then assigns `region_size=128`
and collision mask after it enters the tree because native initialization
restores those scalar defaults. Native activation hides both the custom terrain
mesh and `FoundationGround`; queued or failed native work restores both fallback
layers immediately.

The current temporary Terrain3D visual baseline intentionally reuses a minimal
production extraction of the official Terrain3D demo assets and material
configuration. A project-owned
`ConstructionSiteTerrainProfile` still builds the 64 m × 64 m derived
height/control map around the accepted 20 m logical patch, but its two material
IDs select the demo cliff/bare-ground and grass slots. The adapter loads the
extracted demo `Terrain3DMaterial`, including projection, dual scaling, macro
variation, auto-shader, and world-background parameters.

`TerrainState` algorithm `godot-terrain-state-v3-construction-site` covers the
complete 64 m visible site at 0.5 m spacing. Its central 20 m work pad is a true
zero-height plane while the deterministic outer grades and spoil contours are
part of the same authoritative heightfield, so rendered ground, Jolt support,
and excavation sampling cannot diverge when the machine leaves the spawn area.
Official RockA/B/C meshes are placed outside that patch through bounded
`MultiMeshInstance3D` layers. The official grass particle scene is retained
outside a 12 m central exclusion radius. Demo height maps are never imported as
logical state, and these presentation objects add no collision authority.

When enabled, Terrain3D may generate static collision shapes. In default and
shadow profiles, Jolt only queries/solves against derived shapes and does not
own excavator motion. In `jolt_authoritative`, the project `TerrainCollider`
with matching generation/revision supports the dynamic chassis, while
`TerrainState` remains the deformation authority. Bucket query contacts provide
evidence but do not directly edit terrain; `TerrainCommitScheduler` remains the
sole revision writer. Jolt never owns bucket inventory, replay, or Python state.
The terrain data flow remains one-way:

```text
fixed-step command -> bucket query -> selected soil ledger/TerrainState transaction
                   -> copied snapshot -> Terrain3D/TerrainCollider -> later query
```

Tracked support follows the same one-way rule. The bilinear `TerrainState`
surface is authoritative. Optional `TerrainCollider` ray hits are accepted only
when the collider's applied `(world_generation, terrain_revision)` equals the
current TerrainState identity and the hit height remains within the configured
tolerance; every miss, stale collider, or unavailable physics path fails open
to the heightfield.

The first soil presentation is not a per-grain rigid-body simulation. It combines the authoritative stable/loose heightfield and bucket volume with bounded visual particles or clumps. Those effects are disposable presentation state and must clear on historical seek, reset, reconnect, and authority-generation changes.

## Deferred model decisions

The GLBs remain visual assets. The authoritative hybrid uses explicit
rest/anchor contracts, one provisional chassis compound, four bounded
kinematic axes, query-only bucket proxies, and tick-boundary payload slowdown.
Validated production chassis collision/mass properties, hydraulic force curves,
material contact calibration, volumetric continuum soil, and per-grain dynamics
remain deferred.
