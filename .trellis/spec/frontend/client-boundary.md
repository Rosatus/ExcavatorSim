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
and cannot write product pose. In the default `jolt_authoritative`, one Jolt chassis
body and one bounded kinematic articulation state jointly form the sole hybrid
pose writer. Terrain deformation, bucket inventory, and replay authority remain
outside Jolt.
Physics resources require an explicit adapter/lifecycle boundary and must be
disposed on authority generation changes.

Phase 0 adds an explicit `jolt_shadow` observer without changing the current
writer. `SimulationTruthPublisher` is a root sibling observer and its shadow
output may only enter Python's negotiated diagnostic slot. The authoritative
profile produces local hybrid truth but must not send that truth through the
shadow transport.

## Godot-first local-world profile

The product default uses Godot/Jolt for motion kinematics, contacts and local
world truth. Python's optional `gateway-only` service validates observational
input and bounded telemetry without publishing pose. The explicit
`motion-only` compatibility profile retains Python kinematics while Godot owns
deterministic-enough terrain/world state, bucket convenience state and
presentation. `TerrainState` keeps stable and loose Float32 layers;
`TerrainRenderer` only consumes copied snapshots and is generation-gated.

The generation-selected soil ledger is the single local bucket-inventory owner
in this profile. Product-default `active_patch` uses
`SoilInteractionAuthority`; explicit legacy/shadow compatibility keeps
`BucketSoilState`. `ExcavationWorld` derives cut, carry, spill, and dump from
swept articulated bucket proxies; direct monotonic legacy cut/deposit queues are
test/debug seams only. The selected cellular occupancy derives volume, mass,
fill, and center of mass, while `TerrainCommitScheduler` is the sole runtime
owner of coarse
`TerrainState` deltas and derived mesh/collider updates. The client may publish
only the optional, latest-value `bucket_load_feedback_v1` observation after
positive capability negotiation; it never publishes terrain edits or replay
authority to Python. `TerrainCollider` is an optional generation-gated static
derivative, disabled/fail-open by default. Missing or failed local physics
cannot block terrain edits or motion presentation.

Active-patch scoop transfer is spatially local: only displaced active material
overlapping a bounded teeth/opening/inner-shell intake neighborhood may enter
the bucket ledger. It may not pull arbitrary representatives from the patch.
Scoop capture stops at the selected model's spill orientation, and release uses
that same model contract's spill/dump opening thresholds. Visible bucket
outward direction and the contract opening normal must be calibrated together;
changing a joint endpoint alone is not sufficient evidence of a valid dump.

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
ProductSession.get_equipment_input_axes() -> Vector4
MotionClient.get_authoritative_input_axes() -> Vector4
```

The local actions are `track_left_forward`, `track_left_reverse`,
`track_right_forward`, and `track_right_reverse`. They never enter the Python
`Vector4` articulation snapshot.

The production keyboard mapping is left track forward/reverse `R/F` and right
track forward/reverse `Y/H`. Work equipment follows the ISO excavator layout:
left-stick `W/S` is arm out/in, `A/D` is swing left/right, right-stick `I/K` is
boom down/up, and `J/L` is bucket curl/dump. XInput-compatible controllers map
LT/LB to left forward/reverse and RT/RB to right forward/reverse; left stick
X/Y remains swing/arm and right stick Y/X remains boom/bucket. Both devices
produce the same canonical operator vector `(swing, boom, arm, bucket)`, whose
positive meanings are right, raise, extend, and curl. One validated per-model
`EquipmentCommandMapper` converts that vector to joint-coordinate signs before
local articulation; protocol v4 carries the operator vector and Python applies
the same shared profile before compatibility simulation. A rig's optional
`tracks.local_forward_axis` is `-Z` or `+Z` and
defaults to `-Z` for backward compatibility. Vehicle right is derived from
forward × up; it is never hard-coded independently from forward.

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
- Keyboard and gamepad events feed the same four track actions and the same
  `(swing, boom, arm, bucket)` equipment vector. Runtime registration replaces
  stale owned keyboard and joy events before installing exactly one canonical
  key plus the existing gamepad binding; it must not leave an older keyboard
  layout or the former trigger-driven bucket actions active. Trigger pressure
  remains analog; shoulder reverse is digital.
- `ControlInputHUD` is presentation-only. It observes all twelve semantic
  actions independently through `Input.is_action_pressed()`, never writes the
  InputMap or motion commands, and recursively uses `MOUSE_FILTER_IGNORE`.
  Therefore opposing keys may both highlight while their resolved axis remains
  zero, and orbit/zoom pointer input passes through the lower-right HUD.
- Model-specific input direction is expressed only by the generated,
  parity-checked `equipment-command-profile-v1` runtime copy consumed by
  `EquipmentCommandMapper`. ProductSession selects that profile after successful
  initial/model activation; compatibility transport publishes the unmapped
  operator vector. Do not mutate InputMap per model or invert protocol channels,
  rig joint axes, or presentation pivots.
- Each model descriptor must provide track/contact dimensions, independent
  front/rear/left/right support offsets, speed/acceleration/brake/coast values,
  pivot scale, slope limits, slip coefficients, minimum traction, and support
  response rate. An incomplete descriptor rejects that model without fallback.
- Outside the bounded voxel work-zone mask,
  `TerrainState.sample_surface_bilinear_at()` is the support-height authority.
  A `TerrainCollider` ray hit may refine the same height only when its applied
  `(world_generation, terrain_revision)` exactly matches `TerrainState` and the
  hit belongs to that derived collider. A miss, stale identity, unavailable
  physics, or excessive height mismatch returns the authoritative heightfield.
- Focus loss, transport pose clear/reconnect, model activation, world reset,
  controller disable, or invalid terrain stops both tracks. Model/world changes
  also restore the local chassis transform to identity.

### Test-only focus bypass

Automated headless runners may lose OS focus while their Godot window is still
running. A test harness that drives `set_*_for_test` commands must therefore opt
in explicitly through:

```text
TrackedChassisController.set_test_input_focus_bypass_for_test(enabled: bool) -> void
```

The bypass is test-only state and is never enabled by production startup or user
input. With it disabled, the normal focus-loss contract still zeros track and
equipment commands. With it enabled, only the existing explicit test setters may
drive commands; ordinary input remains focus-gated. Tests must cover both modes so
an unattended soak cannot accidentally weaken the product safety behavior.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Missing/invalid model field | Reject model; no cross-model parameter fallback |
| Height sample outside logical grid | Reject fixed step and stop both tracks |
| Jolt collider disabled/unavailable outside voxel mask | Continue from bilinear heightfield |
| Collider identity is stale outside voxel mask | Ignore raycast and continue from heightfield |
| Voxel collider pending/unavailable inside voxel mask | Fail closed; never synthesize heightfield support |
| Matching derived ray hit | Accept only a bounded height-compatible hint |
| Focus/reconnect/model/world reset | Clear commands and velocities; reset pose where required |
| Stale/duplicate runtime gamepad event | Replace it with exactly one canonical joy binding for that action |
| Stale/duplicate product keyboard event | Replace it with exactly one fixed semantic `WASD`/`IJKL` event or global `RF`/`YH` track event |
| Opposing semantic actions held | Resolve motion to zero while highlighting both HUD tiles |
| Pointer input over control HUD | Pass through every descendant; HUD never consumes camera input |
| Gamepad held during re-arm | Keep the corresponding track/equipment output zero until all owned controls return neutral |
| One model's final joint direction is reversed | Correct the shared semantic-to-joint profile; device bindings remain unchanged |

### 5. Good / Base / Bad Cases

- Good: keyboard or XInput -> shared independent track/equipment actions ->
  fixed-step skid steer plus four-axis articulation -> one chassis root.
- Base: local physics disabled -> identical heightfield-driven locomotion.
- Bad: gamepad creates a second command state, track input is added to the
  Python articulation vector, joystick feedback is fixed by changing keyboard
  or rig axes, or a raycast mutates/invents terrain state.

### 6. Tests Required

- Fixed-step tests assert straight, arc, pivot, coast, braking, reversal, slope,
  out-of-grid stop, and separately validated SY205/SY135 parameters.
- Scene tests assert the single chassis root and Python base composition.
- A real Jolt collider test asserts matching-hit use plus disabled and stale
  identity fallback.
- Lifecycle tests assert reconnect, model activation, world reset, focus loss,
  and controller disable clearing behavior.
- Input tests assert the exact fixed ISO joy axis/sign and semantic keyboard key
  for all eight equipment actions, exact `R/F` and `Y/H` track keys, exact
  LT/LB/RT/RB track bindings, idempotent runtime registration, and
  current-device prompt switching without weakening neutral re-arm.
- Input tests select both model profiles, assert identical keyboard key and
  JoypadMotion axis/sign pairs, reject unknown profiles, and prove offline model
  switching changes only the active semantic-to-joint adapter.
- The standalone HUD test binds every semantic action to its exact physical
  key, named tile and copy; it also asserts 1280x720/1920x1080 containment,
  translucent styling, recursive mouse-ignore, independent highlights and
  opposing-axis zero.
- Godot MCP must drive the four actions and switch both production models in a
  live backend session.

### 7. Wrong vs Correct

```text
Wrong: MotionPresentation writes base_link.global_transform and cancels chassis travel
Correct: ChassisMotionRoot owns travel; MotionPresentation composes below it

Wrong: bucket remains on LT/RT while separate callbacks drive tracks
Correct: canonical InputMap events put bucket on right-stick X and feed LT/LB/RT/RB into the existing track actions

Wrong: a model's direction is reversed -> swap its keyboard/gamepad actions
Correct: retain fixed operator actions and correct the one shared model semantic-to-joint profile

Wrong: keep the old Q/A, W/S track keys beside the new joystick layout and let both fire
Correct: erase owned runtime key/joy events, then install one canonical RF/YH track and WASD/IJKL equipment layout

Wrong: resolve each axis first and highlight only the winning HUD direction
Correct: resolve motion in the controller, but render each held semantic action independently
```

## Scenario: Jolt-authoritative hybrid chassis and work equipment

### 1. Scope / Trigger

Use this contract when `simulation/authority_profile` is
`jolt_authoritative`, the product default. The compatibility profiles remain
explicit. This profile uses
Jolt for the dynamic chassis/tracks, bounded kinematics for slew/boom/arm/bucket,
and Jolt space queries for bucket/terrain evidence.

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
KinematicArticulationState.propose_step(delta: float, chassis_transform: Transform3D) -> Dictionary
KinematicArticulationState.accept_step(proposal: Dictionary, accepted_fraction: float) -> void
BucketProxySweeper.sweep(space_owner: Node3D, previous_bucket: Transform3D, candidate_bucket: Transform3D, terrain_identity: Vector2i, physics_tick: int, authority_epoch: String, motion_sequence: int) -> Dictionary
MotionPresentation.apply_physics_snapshot(snapshot: Dictionary) -> bool
PhysicsRigDescriptor.is_valid_for(model_id: String, model_version: String) -> bool
BucketSoilState.queue_parcel_deposit_volume(sequence: int, center: Vector3, requested_volume_m3: float) -> bool
SoilParcelPool.configure_barrier_extents(extents: Vector3) -> bool
SoilParcelPool.notify_deposit_results(results: Variant) -> void
SoilParcelPool.notify_deposit_commits(committed_ids: Variant, rejected_ids: Variant) -> void
```

`TrackedChassisController` selects this runtime by profile and remains the only
adapter allowed to copy its body transform onto `ChassisMotionRoot`.

### 3. Contracts

- `JoltChassisTrackRuntime` owns exactly one dynamic chassis `RigidBody3D` and no
  work-equipment body or `HingeJoint3D`. The controller applies its captured
  transform to `ChassisMotionRoot`; no presentation or Python frame may write
  that root in this profile.
- Each model must pass its own hash-bound `physics-rig-v1` descriptor. It
  requires explicit rest transforms, parent/child anchors, unit axes, finite
  limits, bounded velocity/acceleration/jerk/braking, chassis compound shapes,
  track contacts, and evidence provenance. Dynamic upper/boom/arm/bucket mass,
  inertia, motors, hydraulics, and self-collision are not product authority.
  The v1 wire schema remains backward-compatible: model-specific response
  shaping fields (`drive_effort_slew_n_per_tick`, `brake_effort_slew_n_per_tick`,
  `acceleration_window_s`, `brake_stop_window_s`) are optional extensions and
  must have bounded runtime defaults when absent.
- The accepted four-axis command is sampled once per fixed tick. Stale command
  identity is ignored, invalid input disarms, and every rebuild requires a
  neutral sample before movement. `KinematicArticulationState` shapes joint
  target velocity, acceleration and jerk, anticipates limits, computes candidate
  FK, and accepts one common motion fraction before recomputing accepted FK.
- The selected soil ledger remains payload authority. The controller submits mass,
  local COM and monotonic material identity; the runtime converts them at a tick
  boundary into bounded joint motion-load multipliers. Payload never mutates a
  bucket physics body because no such body exists.
- Each track uses four distributed ray contact points. Longitudinal drive,
  braking, coast, lateral resistance, slip, and differential yaw torque are
  bounded before forces are applied to the body. Effort shaping is updated once
  per side per fixed tick, independent of how many probes currently have
  support; partial contact changes the force budget, not the slew rate.
- Track side/heading semantics derive from one descriptor field. `-Z` forward
  places vehicle right on local `+X`; `+Z` forward places vehicle right on
  local `-X`. The same derived forward drives probes, traction, signed speed,
  residual stop cleanup, pitch telemetry, and left/right contact identity.
- Spawn and reset posture are calibrated from the same descriptor compound
  shapes and the authoritative `TerrainState` surface. The initial transform
  must establish a level/upright chassis relative to the sampled terrain
  normal; changing only the vertical clearance is insufficient when provisional
  center-of-mass or hull/contact geometry creates a pitch moment. Model-specific
  heading/posture corrections must be explicit descriptor data or a bounded
  calibration step, never an untracked per-frame pose writer. Optional
  `chassis_dynamics.spawn_yaw_rad` is applied before terrain-normal alignment so
  Jolt, local track sides, presentation, cameras, and soil proxies rotate as one
  authority transform.
- Longitudinal response is evaluated as a measured speed curve, not only by the
  final speed clamp. Drive, coast and braking forces remain bounded by actual
  support load, and brake effort must be slew-limited or otherwise bounded per
  fixed tick so command release cannot create a one-tick pitch impulse. A
  reverse command first brakes toward a bounded zero-crossing and may not apply
  the opposite drive target while meaningful opposite momentum remains. The
  runtime snapshot should expose enough telemetry to measure acceleration,
  stop time/distance, peak pitch rate and realized slip for each model.
- Reset clearance is solved against the sampled `TerrainState` height at every
  rotated compound-shape corner, not only the body origin. The configured
  clearance is measured after this corner-wise solve and after bounded support
  settling; tests must check both no penetration and proximity to the descriptor
  clearance.
- Track raycasts may hit only the project `TerrainCollider`, and forces activate
  only when its applied `(world_generation, terrain_revision)` matches the
  current `TerrainState`. The heightfield remains the logical terrain authority.
- `BucketProxySweeper` owns no scene body. It segments previous-to-candidate
  bucket motion, uses `cast_motion` plus endpoint overlap/rest queries, and
  accepts hits only from the exact applied `TerrainCollider`. Cutting edge,
  opening, cavity, shell, and rear-support proxies come from the selected model
  soil contract; only cutting/shell/rear can block motion.
- One query result is immutable and carries authority epoch, physics tick,
  terrain generation/revision, bucket motion sequence, proxy version, accepted
  fraction, contact IDs/roles and quality. Queries arbitrate rigid-body
  semantics only: shell/rear support evidence and obstacle blocking. Soil
  cutting is an analytic material-removal loop that never depends on query
  records — every fixed tick `ExcavationWorld` samples the authoritative
  heightfield bilinearly under the kinematic tooth line (center plus both
  width ends of the cutting edge), and penetration = surface − tooth Y drives
  everything: cuts queue when penetration > ~1 mm AND dig intent is active
  (any work-equipment command including swing, or the movement criteria), with
  depth = min(penetration, `maximum_cut_depth_m`) — pure penetration, never
  padded by the contact tolerance. Cuts are unconditional: bucket capacity,
  payload state, and transfer ledgers never gate or scale them. Removed soil
  enters the bounded parcel transport stage: each accepted cut reports a
  `cut_event` (tooth position + volume) in the `step_fixed` result and
  `SoilParcelPool` spawns a volume carrier at the tooth with inherited
  velocity; decorative GPU clods (`flow_volume_m3`) remain a separate fines
  layer. Parcels never gate or modify cutting. A parcel captured by the
  bucket cavity credits occupancy up to remaining capacity via
  `credit_captured_volume`, restoring fill presentation and payload mass;
  overflow parcels keep flying past the bucket. Dump/spill hand ledger
  volume to parcels at the lip (`release_poured_volume` + guarded spawn)
  instead of writing terrain directly; poured parcels carry a recapture
  guard. Grounded slow parcels settle back into the loose heightfield through
  the explicit `queue_parcel_deposit_volume` path, so spoil piles are real
  terrain the machine can re-dig. That path is distinct from
  `queue_deposit_volume`: parcel volume has already left the bucket ledger (or
  came straight from a cut), so settling may add terrain but may never require
  or remove bucket occupancy. Each result carries its parcel sequence and
  transfer ID; the pool freezes the matching body until that exact terrain
  transfer commits, retries an explicit rejection without destroying material,
  and consumes only the accepted portion. Missing/delayed results retain the
  frozen sequence identity; a local timeout must never infer cancellation of a
  transfer that may commit later. Aggregate per-tick deposit volume is not
  parcel identity. The body pool is budget-capped; accepted cut volume that
  exceeds its free carriers enters one bounded aggregate backlog and is spawned
  into the next free carriers instead of stealing material. The pool and backlog
  are cleared on every generation/reset path. An
  open-mouthed kinematic barrier (floor/back/sides from the cavity contract,
  machine layer only) mirrors the cavity frame so parcels rest against the
  shell instead of passing through work-equipment transforms; capture is a
  ~0.18 s progressive absorption whose remainder stays physical when
  capacity stalls, and cut spray inherits tooth velocity with an upward
  bias. `SoilParcelPool.setup()` must reapply the configured collision layer
  and mask to already-created pooled bodies because `_ready()` can build them
  before the production owner calls setup. Model activation must reconfigure
  all four barrier planes from the newly active cavity extents. Cut transfers
  still retire on terrain commit without adding occupancy;
  a validated in-band query
  contact point remains a supplementary trigger for mesh contacts the samples
  cannot see, and such cuts land on the validated contact point. Query
  failures, stale terrain identity, or initial overlap can never disarm or
  block cutting — they only gate support transactions. Only
  `shell`/`rear_support` are motion-blocking proxies; terrain contact never
  reduces the accepted fraction of the cutting edge. Digging resistance is a
  saturating speed load computed analytically as well: the runtime low-passes
  cutting-edge penetration below grade into an engagement value that scales
  dig-direction work-equipment command velocity toward `MIN_CUT_SPEED_SCALE`
  — resistance only ever slows a stroke, never stalls it — and is independent
  of collider availability; retraction keeps full authority. Cut brushes
  commit to TerrainState in the same fixed tick they are queued (the
  scheduler force-flushes): the analytic loop samples TerrainState as its
  authority, so latency batching here would starve the yield-equals-press
  invariant and stall downward strokes. Presentation coalescing lives
  downstream in the dirty-rect patchers. Cut brushes enqueue with
  center-exact normalization: the four cells around
  the brush center receive bilinear-weight-compensated amounts so the sampled
  surface drops exactly the requested depth — rasterized falloff alone would
  yield a fraction of it and break the yield-equals-press invariant.
  Support may use
  a non-initial shell/rear contact from the same segmented sweep when that
  load-bearing proxy has an upward normal, bounded accepted fraction, and motion
  into the surface; initial overlap on the load-bearing proxy still disarms that
  contact. Invalid results retain current identity; canonical truth is published
  only when the query epoch/tick exactly equals the enclosing post-step snapshot.
- `ExcavationWorld` reduces one query result to one idempotent interaction key
  `(authority_epoch, physics_tick, terrain_generation, terrain_revision,
  bucket_motion_sequence)`. Precedence remains `dump -> spill -> cutting ->
  carry`; the accepted batch queues at most one existing
  `BucketSoilState`/`TerrainCommitScheduler` transaction.
- Valid shell/rear evidence may queue one chassis support request for
  `source_tick + 1`. The runtime validates model/authority/terrain identity and
  expiry, clamps force to 180 kN and torque to 320 kNm, limits per-tick changes
  to 30 kN/60 kNm, and applies one Jolt wrench. Support also requires an
  upward-facing normal and bucket motion into the surface, stops after 45
  continuous ticks, and stays duration-locked until contact loss. Heave and
  tilt-rate guards prevent sustained support from accelerating without bound.
  Work-equipment free motion and bucket payload do not react on the chassis.
- `TrackedChassisController` may materialize the collider only during initial
  rig activation and world reset. `TerrainCommitScheduler` remains the sole
  normal terrain-revision writer for render/collider derivatives; the Jolt
  runtime stops forces during any identity gap rather than rebuilding a second
  collider path.
- Focus loss, reconnect/pose clear, reset, model switch, invalid rig, invalid
  terrain identity, profile exit, and tree teardown stop commands/forces and
  clear or rebuild the complete rig without a same-frame writer handoff.
- In authoritative mode the Jolt runtime epoch owns local truth ordering.
  Python `authority_changed` is observational and cannot reset that epoch or
  sequence; a Jolt reset/model rebuild rotates the runtime epoch and restarts
  the truth sequence at zero.
- The runtime captures one post-step snapshot with one dynamic body, four
  kinematic frames, four logical joints, track state, payload/load factor,
  bucket query, and queued/applied wrench. Presentation and local truth consume
  that snapshot and never sample live physics/query nodes independently.
  Canonical `bucket_query` preserves authority epoch, physics tick, terrain
  generation/revision and motion sequence in addition to previous/candidate/
  accepted transforms. SY205's passive four-bar remains visual-only.
- Model activation replaces bucket cell-grid dimensions and storage as one
  coherent state change. Fill-profile consumers read a stable local snapshot
  and return an empty profile rather than indexing mismatched transient state.
- `transport_publishing` must remain false. The Python shadow decoder accepts
  only the five-body `jolt_shadow` observation shape and rejects authoritative
  hybrid truth before schema admission.
- The legacy `BucketGroundLiftReaction` must be disabled in authoritative mode;
  query-derived later-tick chassis wrench is the only lift path.
- SY205/SY135 mass, inertia and collision proxy values remain provisional tuning
  evidence. The hybrid profile validates bounded gameplay behavior, not
  production hydraulic fidelity, force transmission or per-grain soil.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Product default / unknown profile | Select Jolt only from the declared default; fail closed for unknown values and never fall back to Python pose |
| Missing/hash-mismatched/invalid rig | Reject model and destroy any old dynamic runtime; no cross-model fallback |
| Collider unavailable or identity stale | Stop track force activation and report quality/identity failure |
| Python pose arrives in authoritative mode | Reject the pose write; retain the latest Jolt snapshot |
| Non-neutral first command after rebuild | Hold zero effort until a neutral sample arrives |
| Stale equipment command identity | Ignore without changing current command state |
| Invalid payload mass/COM/identity | Reject without changing the applied motion-load factor |
| Bucket query initial overlap/failure | Accept bounded recovery motion; support requires independent non-initial shell/rear evidence; cutting is unaffected (analytic) |
| Shallow cutting-edge/opening start overlap | Query stays valid; contacts carry `shallow_overlap` quality; cutting never depended on it |
| Cutting-edge terrain contact during a stroke | Never blocks motion; analytic penetration drives cuts and the saturating resistance load (swing included), stalling at `maximum_cut_depth_m`; retraction unaffected |
| Slow micro-trim or swing-drag stroke below the per-tick sweep threshold | Engaged tooth plus an active work-equipment command queues a cut every tick; no query needed |
| Stale collider identity during an engaged stroke | Analytic cutting continues; only support transactions wait for fresh identity |
| Duplicate interaction key | Report duplicate and queue no second soil transaction or wrench |
| Parcel settles after a full bucket pour | Queue terrain deposit with parcel provenance; bucket occupancy remains zero |
| Parcel deposit is partially accepted | Consume only the committed portion; resize and retry the physical remainder |
| Parcel terrain transfer is rejected/stale | Keep the parcel physical and retry; never debit bucket occupancy or silently recycle it |
| Parcel result/commit is delayed | Preserve the frozen sequence/transfer identity until an explicit commit or rejection; never timer-retry it |
| Cut arrives while the parcel body pool is full | Add its volume to the bounded aggregate cut backlog and drain into the next free carrier; never steal an authoritative parcel |
| Model activation changes cavity dimensions | Retarget floor/back/side barrier shapes before the new model can transport parcels |
| Early/late/stale support request | Drop it without applying force or changing chassis transform |
| Track command outside `[-1,1]` | Clamp before force calculation |
| Missing `tracks.local_forward_axis` | Use backward-compatible `-Z` |
| Axis outside `-Z` / `+Z` | Reject the descriptor before building a rig |
| Speed/angular limit reached | Clamp body velocity and report a quality flag |
| Disconnect/reset/model switch/profile exit | Zero commands and teardown or rebuild the body and contact state |
| Authoritative truth offered to Python shadow decoder | Reject with `shadow_schema_validation_failed` |

### 5. Good / Base / Bad Cases

- Good: model-declared vehicle axis -> derived forward/right track space ->
  product-default Jolt profile -> one dynamic chassis + accepted kinematic FK ->
  identity-bound bucket query -> one interaction batch -> local hybrid truth.
- Base: explicit Python compatibility profile -> Python pose writer and no dynamic chassis rig.
- Bad: swap keyboard commands or GLB nodes to compensate for an undeclared
  model-forward mismatch; apply Python base transform after the Jolt step, accept a stale terrain
  collider, create dynamic work-equipment bodies, or relabel authoritative truth
  as a shadow message.

### 6. Tests Required

- Real pinned Godot 4.7.2 custom-build/Jolt tests cover both models settling, straight travel,
  braking, reversing, pivoting, bounded slope/mound traversal, speed/energy
  bounds, stale terrain rejection, model switch, and teardown.
- Contact tests assert left/right probe points lie on the corresponding visual
  vehicle side for both declared forward-axis conventions; straight travel is
  measured along the declared vehicle forward rather than a fixed `-basis.z`.
- Reset/model-switch tests assert the lowest chassis point remains within the
  configured clearance of `TerrainState`, the chassis up axis is within the
  posture tolerance of the sampled terrain normal, and the first movement
  still requires the neutral re-arm contract.
- Braking tests sample the fixed-tick response and assert monotonic speed
  reduction, bounded peak pitch angle/rate, bounded stop time and distance,
  and no sign reversal or yaw snap. Acceleration tests compare time-to-target
  and realized speed against per-model descriptor targets without relying on
  the global velocity clamp as the primary behavior.
- Articulation tests assert one body/four kinematic frames/four joints, both
  command directions, limits, target/actual telemetry, neutral re-arm, stale
  identity, payload slowdown and zero residual runtime nodes for both models.
- Query/gameplay tests assert actual Jolt terrain hits, segmented motion,
  accepted fraction, stale/initial-overlap failure, duplicate batch rejection,
  one soil transaction, and next-tick bounded chassis wrench.
- Parcel tests throw real rigid bodies against floor/back/side plates and out
  the open mouth, assert progressive absorption at an intermediate tick,
  preserve `ledger + visible remainder`, retarget model-specific extents, and
  prove a full pour settles with released volume equal to committed terrain
  volume while bucket occupancy stays zero throughout.
- Controller/presentation tests assert exactly one writer, Python pose rejection,
  empty pivot diagnostics and visual-only SY205 passive linkage.
- Truth tests assert one body/four kinematic frames/four joints plus
  query/wrench/track/terrain/payload fields, epoch rotation, local publishing,
  and `transport_publishing=false`.
- Schema/backend tests assert descriptor strictness and reject
  `jolt_authoritative` on the negotiated shadow transport.
- The standalone force step must remain below the 10 ms acceptance budget in
  the bounded test scene; MCP smoke verifies live rig/contact/model identity.
- The rendered product soak runs SY205 and SY135 against a fresh `gateway-only`
  process. Quick mode is 90 seconds/model and release mode is 15 minutes/model;
  it gates fixed-step/render percentiles, zero telemetry drops, 256-batch history,
  bounded process-memory growth, cut/dump/support/tracks, reset/reconnect, model
  identity, and one runtime. The benchmark process disables VSync so render
  percentiles measure throughput rather than display wait time.

### 7. Wrong vs Correct

```text
Wrong: Python view_state + Jolt body both write ChassisMotionRoot
Correct: profile gate selects one writer; Jolt-authoritative ignores Python pose writes

Wrong: presentation and truth independently sample live physics/query nodes
Correct: both consume the runtime's single post-step snapshot

Wrong: kinematic bucket RigidBody3D pushes the chassis with uncapped impulse
Correct: query evidence queues one identity-checked, capped next-tick chassis wrench

Wrong: poured parcel settles through queue_deposit_volume and debits the bucket twice
Correct: parcel sequence -> queue_parcel_deposit_volume -> matching terrain transfer commit -> recycle only that parcel volume

Wrong: SY205 looks reversed -> swap left/right commands or rotate only the GLB
Correct: physics rig declares local_forward_axis=+Z -> Jolt derives forward and both sides
```

### Terrain3D derived-backend contract

`Terrain3DAdapter` is the product-default presentation backend, not a second
authority. `soil_shader` remains an explicit and automatic synchronized
fallback. Its public seam is:

```text
queue_snapshot(snapshot: Dictionary) -> bool
queue_full_resync(snapshot: Dictionary) -> bool
apply_pending() -> bool
set_collision_mode(mode: int) -> bool
set_test_mode(value: bool) -> bool
get_status_snapshot() -> Dictionary
```

The snapshot must contain `terrain_epoch`, `terrain_revision`,
`world_generation`, `rows`, `columns`, `spacing_m`, `origin_xz`, `surface`, and
`surface_bytes`. The adapter deep-copies `surface` and `surface_bytes`, rejects
older `(epoch, generation, revision)` work, and only marks `available=true`
after the accepted height map is materialized. `TerrainState.surface_bytes` and
its digest remain the parity oracle; Terrain3D's internal maps never replace
them.

#### Product cutover and Windows export contract

##### 1. Scope / Trigger

Apply this contract whenever the default terrain backend, product diagnostics,
Godot export preset, Terrain3D/Sky3D packaging, or release validation changes.

##### 2. Signatures

```text
TerrainWorld.terrain_backend: "terrain3d" | "soil_shader" = "terrain3d"
TerrainWorld.get_status_snapshot() -> Dictionary
tests/run_terrain3d_release_validation.ps1 [-GodotExe <path>] [-OutputDir <path>]
```

##### 3. Contracts

- Main-scene startup configures `terrain3d`; `soil_shader` remains a supported
  explicit rollback that requires no terrain-data migration.
- Advanced operator diagnostics consume the existing `ExcavationWorld` status
  and show configured/active backend, material identity, and a bounded fallback
  reason. Diagnostics never select a backend or mutate authority.
- Windows release validation runs the same dedicated smoke scene once from the
  source project and once as the entry scene of an isolated temporary export.
  The real project entry remains `res://scenes/main.tscn`.
- The packaged Windows directory contains the executable, Terrain3D release
  DLL, root `LICENSE`/`NOTICE.md`, and adjacent Terrain3D/Sky3D license and Sky3D
  provenance files.

##### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Native startup succeeds | One native surface, project soil material, no native demo dressing |
| Native startup/update fails | One synchronized fallback surface plus bounded reason; simulation continues |
| Explicit `soil_shader` rollback | Custom renderer starts directly; logical bytes/collider/soil/Jolt contracts stay unchanged |
| Export omits Terrain3D DLL or notice files | Packaging gate fails |
| Source/export checkpoint differs | Parity gate fails and retains both JSON/log sets |

##### 5. Good / Base / Bad Cases

- Good: default native startup -> cut/deposit -> Test Grid -> recovery -> model
  switch/reset, with matching source/export checkpoints.
- Base: set `terrain_backend="soil_shader"` and keep the same authority data and
  project collider without migration.
- Bad: change `main.tscn` to a test entry or add a production-only hidden test
  hook merely to exercise an exported build.

##### 6. Tests Required

- `visual_pass_test.gd` asserts the native product default, approved project-soil
  identity, single visible surface, and no native demo dressing.
- `operator_ui_test.gd` asserts backend/material identity appears only behind
  Advanced diagnostics; its documented legacy model-switch failures remain
  separate from this assertion.
- `terrain3d_export_smoke.tscn` covers cut/deposit, Test Grid, forced
  fallback/recovery, explicit `soil_shader` rollback/restoration, SY135 switch,
  reset, and a successful test-process exit.
- `run_terrain3d_release_validation.ps1` compares source/export checkpoints and
  hashes the packaged artifacts.

##### 7. Wrong vs Correct

```text
Wrong: exported test requires changing the production main scene or adding a runtime test backdoor
Correct: copy to an isolated temp project -> select smoke entry there -> export/run -> compare JSON

Wrong: native visual default -> infer Terrain3D owns terrain collision or soil state
Correct: native visual default -> TerrainState/soil/Jolt/TerrainCollider remain authoritative -> synchronized fallback remains available
```

#### Incremental revision contract

`TerrainState` publishes `full_refresh`, `dirty_rect_cells`, and
`dirty_rect_with_halo` (one-cell normal/seam halo, clamped to the grid) with
every snapshot; a rectangle is trustworthy only when its `dirty_revision`
equals the snapshot's `terrain_revision`. Startup, reset, generation change,
stale recovery, and explicit resync take the full `build_maps`/`import_images`
path. Ordinary contiguous revisions (`revision == applied + 1`) patch in place:
the adapter first validates every affected region and height map without any
writes, then edits existing region height-map images for the mapped dirty
pixels plus halo, marks those regions edited/modified with refreshed height
bounds, and calls `Terrain3DData.update_maps(TYPE_HEIGHT, false, false)` so
only edited regions refresh. Dressing nodes are rebuilt only on the full path.
Counters expose `full_import_count` versus `patch_count`; ordinary revisions
increment only the patch counter.

No-flicker invariant: there is always one visible valid surface — previous
native, new native, or fallback. Queued or applying work (patch or full) never
hides the active native terrain; visibility changes only after a real success
or a hard failure. A failed patch leaves the previous surface visible,
schedules a full resync, and retries the same snapshot through the full path;
a failed full materialization first fully synchronizes the custom renderer from
the retained latest accepted snapshot and only then commits the visibility
switch. While native Terrain3D owns presentation, ordinary patches skip
fallback mesh rebuilds; on native deactivation the fallback catches up in one
full rebuild from the latest accepted snapshot.

#### Transactional full materialization lifecycle

##### 1. Scope / Trigger

This contract applies to startup, reset, generation/model change, skipped
revision, material replacement, patch recovery, explicit resync, and Test Grid
exit. Terrain3D 1.0.2 `import_images()` is not an in-place transactional
replacement for already-active regions.

##### 2. Signatures

```text
Terrain3DAdapter.queue_full_resync(snapshot: Dictionary) -> bool
Terrain3DAdapter.apply_pending() -> bool
TerrainWorld.set_test_mode(value: bool) -> bool
TerrainWorld.get_status_snapshot() -> Dictionary
```

##### 3. Contracts

- `TerrainWorld` owns the deep-copied latest accepted
  `(terrain_epoch, world_generation, terrain_revision)` and the explicit
  `configured_backend`, `active_backend`, `presentation_override`, and typed
  `fallback_reason` state.
- After an initial native surface exists, a full path creates a hidden staging
  Terrain3D node, assigns the cached non-null assets/material before enter-tree,
  imports the complete presentation maps, overlays the exact logical grid via
  region height maps, and swaps nodes only after all steps succeed.
- A failed staged import or overlay frees the staging node and preserves the
  previous native node. `TerrainWorld` synchronizes the retained accepted
  snapshot into fallback before hiding native.
- Test Grid first full-synchronizes fallback, then commits the grid override.
  Exit does not re-show cached native state: it full-resyncs the configured
  native backend and swaps only on success. Failure leaves synchronized fallback
  visible without changing the configured backend.
- `TerrainRenderer` and `Terrain3DAdapter` both gate complete epoch/generation/
  revision identities; retired lineage and stale work cannot overwrite applied
  state. Their full/patch/failure counters are diagnostics only.

##### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Same applied identity explicitly resynced | Allow one forced full path; do not reject it as an ordinary duplicate |
| Patch fails | Preserve native, count failure, retry same copied snapshot once through staging full |
| Staged import/overlay fails | Discard staging; synchronize fallback; expose typed reason |
| Fallback synchronization fails | Keep current valid surface; report `fallback_sync_failed`; do not commit visibility |
| Test Grid enters | Full-sync fallback, apply grid, then hide native |
| Test Grid exits | Full-sync configured native; failure retains latest fallback |

##### 5. Good / Base / Bad Cases

- Good: contiguous revision -> dirty+halo native patch -> native identity advances.
- Base: missing native material -> latest fallback becomes active -> same accepted
  identity succeeds after material repair.
- Bad: clear live native regions and call `import_images()` in place; a failure
  destroys the last valid surface and a success may leave stale region samples.

##### 6. Tests Required

- Adapter matrix covers two contiguous patches, skipped revision full, stale and
  retired rejection, patch failure/full retry, hard full failure/recovery, and
  full-resync sample equality.
- World lifecycle coverage asserts fallback applied identity equals latest
  accepted identity before every hard-failure/Test Grid visibility commit,
  `visible_surface_count == 1`, and configured backend remains unchanged.
- Test Grid receives a live terrain revision, exits via one full native resync,
  and retains fallback when that resync is forced to fail.

##### 7. Wrong vs Correct

```text
Wrong: clear visible regions -> import_images() -> show fallback only if import fails
Correct: import hidden staging -> overlay logical grid -> swap on success; otherwise retain old native until fallback is synchronized

Wrong: Test Grid off -> immediately show last cached native node
Correct: Test Grid off -> full-resync latest accepted snapshot -> commit configured backend
```

`TerrainCollider` partitions the logical grid into stable chunks under one
static body. Ordinary revisions build replacement shapes before touching
nodes, swap only chunks overlapped by the dirty halo rectangle (which already
includes the shared-edge ring), and advance the applied identity only after
all dirty chunks are installed; unchanged chunks keep their shape identity. A
failed install retains the old chunks, reports unavailable/stale, and lags the
applied identity so bucket queries and tracked support fail closed until a
full rebuild succeeds. A skipped (non-contiguous) revision forces a safe full
chunk rebuild.

Terrain3D initializes native rendering when the node enters the scene tree.
Configure non-null `assets` and `material` before `add_child()` so the first
Forward+ initialization never observes an incomplete resource graph. Configure
`region_size` and `collision_mask` immediately after `add_child()`: Terrain3D
1.0.2 restores those scalar defaults during enter-tree initialization, so a
pre-tree write may appear accepted and then be overwritten. The production
adapter keeps `region_size=128`; do not infer supported values from a pre-tree
readback.

#### Native material resource lifecycle

##### 1. Scope / Trigger

This contract applies whenever `Terrain3DAdapter` creates, retries, or
reconfigures the native Terrain3D node under Godot 4.7 Forward+/D3D12.

##### 2. Signatures

```text
Terrain3DAdapter.material_path: String
Terrain3DAdapter.apply_pending() -> bool
Terrain3DAdapter.get_status_snapshot() -> Dictionary
```

##### 3. Contracts

- Load and cache one exact `Terrain3DMaterial` resource before the native node
  enters the tree. The pre-tree and post-tree assignments must use that same
  object identity; do not deep-duplicate or replace it after Terrain3D has
  initialized its rendering resources.
- Reuse the cached resource while `material_path` is unchanged. A path change
  must load and validate a new resource before replacing the cached identity.
- Material setup failure leaves the native node unready and outside the scene
  tree, preserves the pending snapshot, and keeps the fallback renderer and
  foundation visible. A later valid material must recover by applying that same
  pending snapshot without requiring a new terrain revision.
- Test Grid and backend comparison hide the native node without clearing or
  replacing its live material. The fallback renderer owns the black/white grid;
  leaving test mode uses the cached material on a transactional full resync.
- `get_status_snapshot()` exposes the requested material path, loaded resource
  path, native readiness, renderer/method/driver, and stable `last_error`.

##### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Material path cannot be loaded | Return `false`; `last_error="Terrain3D material is unavailable: <path>"`; retain fallback |
| Loaded object is not accepted by Terrain3D | Return `false`; `last_error="Terrain3D material could not be assigned: <path>"`; retain fallback |
| Same path is retried | Reuse the cached resource object; do not duplicate or replace it |
| Missing material is corrected | Configure and enter tree, consume the preserved pending snapshot, clear the error |
| Test Grid enters/exits | Synchronize the target surface before visibility commit; never assign native `material=null` |

##### 5. Good / Base / Bad Cases

- Good: load once -> assign the same object before/after enter-tree -> import
  maps -> native visible.
- Base: material unavailable -> stable diagnostic plus visible fallback -> fix
  path -> retry the same pending snapshot successfully.
- Bad: deep-duplicate or replace the material after enter-tree; Godot 4.7
  D3D12 may retain stale/null material RIDs even when some pixels remain visible.

##### 6. Tests Required

- `terrain3d_adapter_test.gd` must assert the stable missing-material error,
  fallback visibility, same-snapshot recovery, and native material object
  identity after recovery.
- The real non-headless Forward+/D3D12 probe must require native visibility,
  brown/nonblack pixels for native and fallback variants, visible deformation
  in both derivatives, unchanged post-deformation authority identity during
  capture toggles, and no current-run Terrain3D/shader/GDExtension/material/
  texture-array/map-import errors.

##### 7. Wrong vs Correct

```text
Wrong: load -> duplicate before add_child -> duplicate again after add_child
Correct: load once -> cache exact resource -> assign same object across enter-tree

Wrong: missing material -> discard pending revision and require a new snapshot
Correct: missing material -> fallback + stable error -> fix path -> apply same pending snapshot

Wrong: Test Grid -> native material=null -> later create new RenderingServer RIDs
Correct: Test Grid -> synchronized fallback grid -> full-resync native with cached material
```

Terrain3D can create static collision shapes, while the project-selected Jolt
backend answers Godot raycasts and contacts. Collision is disabled/fail-open by
default (`terrain3d/collision_mode=0`); enabling it must not change logical
excavation or motion behavior. A missing GDExtension, failed map update, or
failed collision setup keeps `TerrainRenderer`/`TerrainCollider` usable.

#### Physical query provenance contract

##### 1. Scope / Trigger

Apply this contract whenever Terrain3D presentation, Jolt track support, bucket
shape queries, or their diagnostics change. Native Terrain3D is never product
physics authority while `terrain3d/collision_mode=0`.

##### 2. Signatures

```text
Terrain3DAdapter.get_status_snapshot() -> {
  native_collision_mode_configured: int,
  native_collision_mode_actual: int,
  native_collision_layer_actual: int,
  ...
}
JoltChassisTrackRuntime.get_post_step_snapshot() -> {
  track_support_source_counts: Dictionary[String, int],
  contacts: Array[Dictionary],
  ...
}
BucketProxySweeper.sweep(...) -> {
  contacts: Array[{query_source: "terrain_collider", ...}],
  ...
}
```

##### 3. Contracts

- Production native presentation requires configured and actual collision mode
  `0` and actual native collision layer `0`. `collision_available` remains
  `false`; Terrain3D rendering success does not imply a physics source.
- Outside the voxel work-zone mask, every accepted track ray records
  `support_source` as `terrain_collider` when
  the matching collider answers, or `terrain_state_fallback` when that same
  identity-valid collider ray misses/is rejected and the logical heightfield
  supplies the support sample. Per-tick counts are observational diagnostics
  and never select authority.
- Every accepted bucket shape-query record carries
  `query_source="terrain_collider"`. The sweeper still verifies that the hit is
  a descendant of the configured, identity-matched `TerrainCollider`; collider
  names, instance IDs, or Terrain3D nodes are not sufficient evidence.
- Terrain/collider `(world_generation, terrain_revision)` must match before a
  physics tick or bucket hit is accepted. Outside the voxel mask, a
  matching-collider ray miss may use the logical heightfield for track support;
  stale, unavailable, or disabled
  collider identity disarms Jolt track forces and bucket evidence until the
  project collider catches up.

##### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Native mode/layer reads back nonzero in product mode | Fail authority regression; do not cut over |
| Track ray hits matching project collider | Record `terrain_collider` |
| Matching track collider ray misses or is rejected | Use logical heightfield and record `terrain_state_fallback` |
| Track collider identity is stale/unavailable | Disarm Jolt track forces and report collider unavailable |
| Bucket hit is not under configured `TerrainCollider` | Ignore it; never publish accepted evidence |
| Bucket collider identity is stale | Return invalid query with `bucket_query_terrain_identity_mismatch` |
| Presentation backend changes or fails | Preserve terrain bytes, Jolt accepted outcome, and query sources |

##### 5. Good / Base / Bad Cases

- Good: native visual surface + disabled native collision + matching project
  collider -> identical terrain/Jolt result with explicit project provenance.
- Base: matching collider ray misses -> tracks sample `TerrainState`; a stale
  collider disarms Jolt track/bucket work until it catches up.
- Bad: accept a Terrain3D collision hit because its node name or layer looks
  like terrain, or enable native collision to repair a visual issue.

##### 6. Tests Required

- `terrain3d_authority_equivalence_test.gd` runs the same fixed soil and Jolt
  sequence for SY205/SY135 under native and fallback presentation. It compares
  stable/loose bytes, digests, ledger/payload, accepted chassis/articulation
  transforms, reset/Test Grid/failure identities, and actual native mode/layer.
- `jolt_chassis_track_test.gd` asserts settled support provenance contains only
  project collider/logical heightfield sources.
- `jolt_bucket_query_spike.gd` and `bucket_shallow_overlap_test.gd` require
  `query_source="terrain_collider"` on real accepted contacts and retain stale
  identity rejection.

##### 7. Wrong vs Correct

```text
Wrong: visible Terrain3D -> enable its collision -> let Jolt accept whichever terrain body hits first
Correct: visible Terrain3D with mode/layer 0 -> identity-matched TerrainCollider or logical TerrainState only

Wrong: contact collider_name says "terrain" -> treat it as authoritative
Correct: configured TerrainCollider ancestry + matching identity -> publish explicit query_source
```

Test graphics mode deliberately deactivates native Terrain3D presentation while
retaining its material and latest accepted copied snapshot. `TerrainWorld`
coordinates the transition; callers must not toggle the two renderers
independently. The fallback `TerrainRenderer.set_test_mode(true)` uses a
procedural, texture-free black/white one-metre grid. TerrainState and
TerrainCollider identities remain untouched.

#### Validation & error matrix

| Condition | Required behavior |
|---|---|
| Native class unavailable | `available=false`; retain custom renderer |
| Invalid dimensions/bytes | reject snapshot without mutating authority |
| Stale epoch/generation/revision | reject queue; preserve newer pending work |
| Map import succeeds | native stays/becomes visible; custom mesh and foundation ground hide only then |
| Native work pending | active native terrain remains visible; no fallback flash |
| Patch fails | previous surface stays visible; schedule full resync and retry fully |
| Full materialization fails | restore custom mesh and foundation ground immediately |
| Collision disabled or fails | `collision_available=false`; excavation/motion continue |
| Test graphics enabled | Native textures/grass/rocks hidden; current fallback grid visible; authority unchanged |
| Collider chunk install fails | retain old chunks; applied identity lags so queries fail closed |
| Skipped/non-contiguous revision | derived consumers take the safe full path |

#### Wrong vs correct

```text
Wrong: bucket contact -> Terrain3D editor sculpt -> infer bucket volume later
Correct: bucket command -> BucketSoilState/TerrainState -> copied snapshot -> Terrain3D
```

## Scenario: Full-bucket semantic soil tool shadow

### 1. Scope / Trigger

Use this contract when code needs to describe or observe how the complete
bucket surface cuts, side-cuts, scrapes, pushes, back-drags, grades, compacts,
contains, admits, spills, or dumps material. This first stage is diagnostic
only; the legacy analytic/parcel chain remains the material authority.

### 2. Signatures

```text
SoilContractDescriptor.load_for_model(model_id: String) -> SoilContractDescriptor
SoilContractDescriptor.is_valid_for(model_id: String) -> bool
BucketSoilTool.configure(contract: Dictionary) -> bool
BucketSoilTool.compose_snapshot(previous_bucket_frame: Transform3D,
  current_bucket_frame: Transform3D, has_previous: bool,
  identity: String) -> Dictionary
BucketSoilTool.classify(snapshot: Dictionary, terrain_state: TerrainState,
  fill_ratio: float, interaction: Dictionary) -> Dictionary
ExcavationWorld.set_soil_tool_shadow_enabled(value: bool) -> void
```

### 3. Contracts

- `excavator-soil-contract-v1` is hash-bound through `model_catalog.json` and
  validated once by `SoilContractDescriptor`. Both `MotionPresentation` and
  `JoltChassisTrackRuntime` use that loader; runtime path conventions are not a
  second loader.
- `bucket_tool.schema_version` is `bucket-soil-tool-v1`, its semantic frame is
  `bucket_link`, and regions appear in canonical order: teeth/main edge, left
  and right side cutters, floor/wear plate, outer back, outer left/right sides,
  inner shell, and opening.
- Every region has finite local center, unit outward normal, a bounded segment,
  box, or plane shape, and separate stable/active soil roles. `inner_shell` and
  `opening` have no stable-soil role; enclosed overlap can never authorize a
  stable-terrain erase.
- Tool nominal/heaped capacities exactly match the existing inventory values;
  inner-shell dimensions match the cavity proxy and opening dimensions/normal
  match the opening proxy.
- `MotionPresentation` composes from the accepted fixed-step `bucket_link`
  frame. Previous/current identity includes model, session, simulation epoch,
  world generation, and authority generation. Translation/rotation are sampled
  at descriptor-bounded intervals and capped at 24 samples.
- `BucketSoilTool` is a pure observer. It has no access to terrain brushes,
  bucket credit/debit, parcels, support wrench, or articulation acceptance.
  Candidates are canonical-order data, not transactions.
- `soil_tool_shadow_enabled` defaults false. When enabled, compact telemetry is
  attached to the existing interaction batch and optional
  `simulation-truth-v1` field. Disable, model switch, pose clear, reset, or
  generation change drops prior pose/debug observation state.
- Debug shapes are hidden, non-colliding `MeshInstance3D` children. They never
  enter Jolt layers or terrain/support queries.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Catalog hash, schema, model ID, region set/order, finite geometry, role, capacity, or cavity/opening consistency invalid | Reject the new contract; do not approximate another model |
| First pose, generation/model change, discontinuity, or non-finite transform | Publish unavailable/history reason; classify no candidate |
| Resting or separating stable-soil region | Emit `none`; never cut |
| Inner/opening overlaps stable terrain | May report overlap evidence but cannot acquire a stable role or transaction authority |
| Shadow flag disabled | Omit shadow telemetry; preserve legacy behavior |
| Terrain sampler unavailable | Preserve composed geometry, mark classification quality unavailable, and perform no mutation |

### 5. Good / Base / Bad Cases

- Good: catalog entry -> strict shared loader -> accepted bucket frame -> bounded
  swept regions -> immutable candidate telemetry.
- Base: invalid/missing semantic tool -> feature unavailable while the explicit
  legacy soil path remains usable.
- Bad: copy an entire bucket-shell overlap into a terrain brush, or feed a
  semantic candidate into Jolt accepted fraction during the shadow phase.

### 6. Tests Required

- Validate both model contracts plus invalid inner-shell stable role and
  capacity/cavity mismatch.
- Prove long translation/rotation sweep, canonical ordering, forward cut,
  side-cut, floor scrape/grade, outer push/back-drag/compact, containment,
  opening entry/spill/dump, and resting/separating `none` candidates.
- Compare terrain revision/digest and bucket inventory before/after pure shadow
  classification; existing parcel/motion tests remain unchanged.
- Keep model-switch history cleanup, strict simulation-truth schema, standalone
  matrix, and backend verification green.

### 7. Wrong vs Correct

```text
Wrong: raw mesh triangles or one tooth origin -> infer the whole bucket's soil role
Correct: model bucket_tool regions -> accepted-frame bounded sweep -> read-only candidates

Wrong: Jolt runtime guesses res://resources/models/<id>_soil_contract.json
Correct: model catalog path + SHA-256 -> one SoilContractDescriptor validator
```

## Scenario: Bounded active-soil patch shadow

### 1. Scope / Trigger

Use this contract when cut material needs local gravity, bucket contact,
containment, flow, pile, sleep, and settlement. `configure()` remains an
optional visual shadow over legacy; `configure_product()` is reserved for a
generation where `active_patch` has already been selected as product owner.

### 2. Signatures

```text
TerrainState.from_surface_snapshot(snapshot: Dictionary) -> TerrainState
ActiveSoilPersistentField.configure(source_snapshot: Dictionary,
  preset: String = "loose") -> bool
ActiveSoilPersistentField.configure_product(state: TerrainState,
  scheduler: TerrainCommitScheduler, preset: String = "loose") -> bool
ActiveSoilPersistentField.activate_volume(center_xz: Vector2,
  requested_volume_m3: float, radius_m: float,
  transfer_hint: String = "") -> Dictionary
ActiveSoilPersistentField.settle_volume(center_xz: Vector2,
  requested_volume_m3: float, radius_m: float,
  transfer_hint: String = "") -> Dictionary
ActiveSoilPatch.configure(source_snapshot: Dictionary,
  quality: String = "balanced", material: String = "loose") -> bool
ActiveSoilPatch.configure_product(state: TerrainState,
  scheduler: TerrainCommitScheduler, quality: String = "balanced",
  material: String = "loose") -> bool
ActiveSoilPatch.inject_cut_event(event: Dictionary,
  aggregate_hint: String = "") -> Dictionary
ActiveSoilPatch.step_fixed(delta: float, focus_world: Vector3,
  soil_tool_snapshot: Dictionary = {}) -> Dictionary
ExcavationWorld.set_active_soil_patch_prototype_enabled(value: bool) -> void
```

### 3. Contracts

- `active_soil_patch_prototype_enabled` defaults false. Enabling the prototype
  clones the current immutable product surface into an isolated `TerrainState`;
  only an already-selected `active_patch` generation may borrow product state
  and its sole scheduler through the explicit product configuration entrypoint.
- Accepted legacy `cut_events` are copied into generation-scoped aggregate IDs.
  The copy may debit the shadow field and create representatives, but it cannot
  credit/debit `BucketSoilState`, spawn authoritative parcels, mutate accepted
  equipment state, or write the product `TerrainState`.
- The local window is 3/4/5 metres for low/balanced/high. Logical aggregates
  own exact mobile volume independently of disposable visual representatives.
  Each profile fixes only visual density, substep, neighbor, settlement,
  memory, and tick-time budgets; a quality change rebuilds visual samples and
  cannot merge, split, debit, or settle logical material.
- `loose`, `compact`, `sand`, and `damp` are game-feel presets with distinct
  friction, cohesion, damping, sleep, compaction, and repose values. They are
  not calibrated geotechnical material claims.
- Representatives use gravity, the shadow terrain floor, full-bucket semantic
  proxy contact, spatially bounded neighbor displacement, inner-shell
  containment, and opening-oriented release. Sleeping or window-evicted volume
  settles through `ActiveSoilPersistentField.settle_volume()` and its scheduler.
- `ActiveSoilPatchPresenter` is a disposable `MultiMeshInstance3D` derivative.
  Its instance count, transforms, visibility, or loss never changes volume.
- A shadow model/pose/generation boundary may drop the isolated clone. A product
  model or pose boundary must first settle active/released aggregates and drain
  bucket cells into persistent loose terrain; only an explicit world reset is
  destructive. Default-off product snapshots remain byte-identical.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Invalid snapshot dimensions/surface length, quality, or material preset | Reject configuration; allocate no patch authority |
| Empty/non-finite/out-of-grid activation or settlement | Reject transaction and report rejected volume |
| Duplicate aggregate ID or exhausted representative budget | Reject before shadow terrain debit; never lose volume |
| Shadow scheduler rejects a brush | Retain representative/source state and report rejection |
| Generation or material changes | Clear prior representatives and re-clone current product truth |
| Missing/invalid bucket semantic snapshot | Keep terrain/gravity motion; skip bucket collision for that tick |
| Presenter missing or hidden | Continue fixed-step material behavior unchanged |

### 5. Good / Base / Bad Cases

- Good: accepted cut copy -> shadow scheduler debit -> bounded active
  representatives -> bucket push/contain -> sleep -> shadow scheduler settle.
- Base: flag disabled or prototype unavailable -> unchanged legacy analytic and
  parcel behavior with no active-soil allocation.
- Bad: share the product `TerrainState` with the prototype/shadow, delete an aggregate
  when a budget is full, or treat representative count as physical volume.

### 6. Tests Required

- Assert product terrain digest/revision invariance while each material preset
  activates, moves, and settles shadow volume.
- Assert injected volume equals active plus settled volume within tolerance,
  including flush, quality merge, window eviction, and generation cleanup.
- Exercise full-bucket inner-shell containment plus floor/outer proxy collision;
  missing proxy data must fail open without mutation.
- Benchmark low/balanced/high against 2/4/6 ms p95 and 96/256/512 MiB memory
  gates with representative counts never exceeding their fixed caps.
- Keep legacy excavation, bucket-tool, model-switch, offline-product, and
  backend verification green with the prototype default false.

### 7. Wrong vs Correct

```text
Wrong: accepted cut -> same TerrainState is debited again by active particles
Correct: accepted cut event copy -> isolated shadow TerrainState debit

Wrong: overflow particles are silently dropped to hold frame time
Correct: reject before debit, or merge representatives while preserving volume
```

## Scenario: Conservative soil material lifecycle shadow

### 1. Scope / Trigger

Use this contract when stable/loose terrain, active soil, bucket payload, and
released/settling soil must participate in one generation-scoped transaction
ledger. `shadow` observes the same chain while legacy remains selected;
`active_patch` uses the migration contract below.

### 2. Signatures

```text
SoilInteractionAuthority.configure(contract: Dictionary,
  generation: int, material: String = "loose",
  mode: String = "shadow") -> bool
SoilInteractionAuthority.step_fixed(delta: float, tick: int,
  tool_snapshot: Dictionary, tool_classification: Dictionary,
  patch: ActiveSoilPatch, focus_world: Vector3,
  surface_sweep_result: Dictionary = {},
  terrain_scheduler: TerrainCommitScheduler = null,
  solver_mode: String = "point_brush_v1") -> Dictionary
SoilInteractionAuthority.get_status_snapshot() -> Dictionary
SoilInteractionAuthority.get_journal_snapshot() -> Array[Dictionary]
ActiveSoilPatch.extract_contained_volume(maximum_volume_m3: float) -> Dictionary
ActiveSoilPatch.inject_released_volume(event: Dictionary,
  aggregate_hint: String = "") -> Dictionary
ActiveSoilPatch.consume_settlement_events() -> Array[Dictionary]
ExcavationWorld.set_soil_material_lifecycle_mode(value: String) -> bool
ExcavationWorld.get_selected_soil_payload_snapshot() -> Dictionary
```

Canonical journal rows conform to
`protocol/soil-material-transaction-v1.schema.json`; optional compact truth
telemetry conforms to `simulation-truth-v1.soil_lifecycle_shadow`.

### 3. Contracts

- One `SoilInteractionAuthority` owns ordering, residuals, bucket cells,
  compartment deltas, transaction IDs, journal rows, and ledger snapshots for
  one model/world generation. IDs are `<generation>:<sequence>` and rows carry
  a SHA-256 over their core immutable fields and resulting compartments.
- Compartments are `persistent_stable`, `persistent_loose`, `active`, `bucket`,
  and `released`. Every accepted row writes equal/opposite source/destination
  deltas. Stable excavation becomes active; all settlement becomes loose.
- `TerrainState.surface_snapshot()` includes copied stable/loose layers. A
  shadow clone preserves those layers, and each activation reports the actual
  loose/stable split removed by its scheduler transaction.
- Full-tool stable candidates are deterministic canonical-order input. Primary
  displacement prefers cut, then side-cut, scrape, and grade; region shape,
  penetration, and bounded swept motion determine volume. Push/back-drag and
  shell contact move existing active representatives rather than mint volume.
- Active representatives crossing into a valid inner shell are removed from
  the patch and credited directly to the cell ledger in one fixed tick. Bucket
  capacity is hard; excess remains active/contained and is exposed as overflow,
  never deleted.
- Opening orientation controls spill/dump. Destination capacity is checked
  before bucket debit, released representatives inherit opening point motion,
  and their settlement event writes `released -> persistent_loose`.
- Representative merging is allowed only inside the same ledger compartment.
  Quality count changes may not combine active and released provenance.
- In `shadow`, `ExcavationWorld.get_selected_soil_payload_snapshot()` explicitly
  returns `source=legacy`; Jolt, top-level truth payload, HUD, and existing VFX
  therefore never mix new bucket mass with legacy mass. The new ledger is an
  optional sibling observation and comparison record only.
- Disable or quality/presenter change preserves logical material. Ordinary
  model, pose, or authority boundaries call `settle_all_for_boundary()` before
  clearing the patch and ledger. World reset is the explicit destructive
  boundary. Mid-scoop primary authority migration remains forbidden.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Invalid contract, model, generation, material, or cell grid | Reject configure; create no ledger |
| Duplicate/stale fixed-tick identity | Reject without a transaction or compartment delta |
| Patch generation mismatch or destination unavailable | Reject/retain exact source volume; no open transfer |
| Sub-quantum candidate | Retain in a per-region/action residual accumulator |
| Bucket reaches capacity | Credit only available space; retain contained overflow in active patch |
| Opening points down | Disable inner-shell recapture; allow spill/dump release |
| Settlement exceeds ledger source beyond tolerance | Increment invariant failure; never hide mismatch |
| Shadow differs from legacy | Publish explicit identities and deltas; do not overwrite either result |

### 5. Good / Base / Bad Cases

- Good: full-tool cut -> stable/loose scheduler split -> active aggregate ->
  oriented opening flux -> bucket cells -> spill/dump -> released -> loose pile.
- Base: lifecycle mode `legacy` -> no new authority or patch allocation; Jolt
  and product snapshots retain the existing analytic/parcel payload.
- Bad: a parcel collision independently credits the new bucket, a presenter
  decides volume, or shadow payload mass is added to selected legacy mass.

### 6. Tests Required

- Both model contracts complete fixed-tick cut -> scoop -> nonzero payload ->
  dump -> settle without parcel coincidence or private test credit.
- Assert unique IDs/hashes, equal/opposite deltas, bounded journal, stable/loose
  source split, coherent cells/mass/center, and zero invariant failures.
- Run partial/full capacity, retained overflow, spill/dump, duplicate/stale,
  reset/model/generation/material change, and allocation rejection paths.
- Compare low/balanced/high accepted displacement, opening flux, final logical
  volume, and product terrain digest; representative counts may differ.
- Run 20 accumulated cycles and enforce unexplained drift no greater than
  `max(1e-5 m³, 0.5% of one bucket capacity)`.
- Validate optional simulation truth against its strict schema while top-level
  selected payload and Jolt applied payload remain legacy-identical in shadow.

### 7. Wrong vs Correct

```text
Wrong: terrain cut callback -> parcel coincidence -> second bucket credit
Correct: one ledger row persistent_* -> active -> bucket

Wrong: merge an active rep with a released rep to meet a visual budget
Correct: merge only same-compartment reps; preserve aggregate provenance

Wrong: selected payload = legacy mass + shadow mass
Correct: selected source=legacy; publish shadow under a separate ledger identity
```

## Scenario: Generation-locked soil authority migration

### 1. Scope / Trigger

Use this contract whenever selecting `legacy`, `shadow`, or `active_patch` for
product excavation. `active_patch` is the product default; legacy remains an
explicit compatibility fallback and shadow remains observational.

### 2. Signatures

```text
SoilAuthorityModeController.set_requested_mode(value: String) -> bool
SoilAuthorityModeController.begin_generation(key: String) -> bool
SoilAuthorityModeController.bind_product_writers(
  legacy_enabled: bool, active_patch_enabled: bool) -> bool
SoilAuthorityModeController.report_runtime_failure(reason: String) -> bool
SoilAuthorityModeController.get_status_snapshot() -> Dictionary
ExcavationWorld.set_soil_material_lifecycle_mode(value: String) -> bool
ExcavationWorld.get_selected_soil_payload_snapshot() -> Dictionary
```

Active lifecycle truth is the optional strict
`simulation-truth-v1.soil_lifecycle_active` sibling; the existing shadow field
retains `mode=shadow` and is never reused for product authority.

### 3. Contracts

- One immutable selection is locked per material generation. A mode request
  updates only the next selection; reset, model activation, pose/authority clear,
  or another explicit material-generation boundary applies it.
- `legacy` and `shadow` register legacy as the sole cut, bucket-entry, release,
  and settlement writer. `shadow` may compute against an isolated terrain copy.
  `active_patch` registers the conservative lifecycle for all four stages.
  Writer binding must report exactly one enabled owner or fail closed.
- In `active_patch`, no legacy `BucketSoilState.step_fixed`, cut/deposit queue,
  parcel capture/release/settlement callback, or transfer reconcile may run.
  The legacy parcel pool is cleared/absent; patch representatives provide the
  bounded visual clod layer and cannot create a second ledger.
- The product-backed persistent field borrows, but never resets or owns, the
  product `TerrainState` and `TerrainCommitScheduler`. Detach uses
  `ActiveSoilPatch.clear(false)`; settlement is always an explicit transaction.
- Selected payload, Jolt bucket mass/COM, digging response, visual fill, backend
  feedback, and top-level truth all project from the selected ledger. Legacy and
  active masses are never added together.
- Initialization failure may choose legacy only before the clean generation is
  used. An active runtime failure pauses material writes, records the reason,
  requests legacy for the next generation, and never hot-switches live material.
- Low/balanced/high may change representative density and tick cost only. They
  cannot change accepted volume, ledger totals, selected payload, or final
  terrain outside the declared tolerance.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Mode request during a live generation | Record requested mode; retain selected owner and material |
| Both legacy and active writers registered | Reject binding, increment owner violation, pause use |
| Active initialization fails before first write | Select legacy in the same clean generation and expose fallback reason |
| Active runtime fails after any write | Pause writes; request legacy; require reset/new generation |
| Ordinary model/pose/authority boundary | Settle active/released and drain bucket to persistent loose before clearing; on failure retain the generation and pause writes |
| Explicit world reset | Destructively clear payload, reps, parcels, transactions, response, then create one new selection |
| Presenter/quality/hero-clod setting changes | Preserve ledger and product terrain totals |

### 5. Good / Base / Bad Cases

- Good: generation selects active -> full tool debits product terrain -> active
  representatives -> bucket ledger -> release -> loose terrain settlement.
- Base: clean boundary selects legacy -> unchanged analytic/parcel compatibility
  chain with no active product writes.
- Bad: active failure silently starts legacy callbacks in the same generation,
  or a visual parcel independently credits bucket/terrain material.

### 6. Tests Required

- Assert mode requests are boundary-applied, double-writer binding is rejected,
  runtime failure pauses, and next-generation fallback is legacy.
- Run SY205/SY135 cut, bucket entry, carry, dump, and settle in shadow and active
  modes; shadow keeps product digest fixed while active changes product terrain.
- Compare low/high accepted displacement and opening flux, then run 20 active
  cycles within `max(1e-5 m³, 0.5% bucket capacity)` drift and zero invariants.
- Validate default active startup, Jolt selected payload, strict active truth,
  model/reset cleanup, manual legacy fallback, and restoration to active.

### 7. Wrong vs Correct

```text
Wrong: requested_mode changes -> replace the live writer immediately
Correct: requested_mode changes -> next clean generation selects one writer

Wrong: active cut -> legacy parcel capture -> second bucket credit
Correct: active cut -> active aggregate -> one conservative bucket transaction
```

## Scenario: Continuous surface-patch soil solver

### 1. Scope / Trigger

Use this contract whenever semantic bucket surfaces propose stable/loose terrain
changes, the product collider is synchronized with those changes, or loosened
material is transferred between terrain, active aggregates, the bucket, and
settlement. It replaces overlapping point brushes only when the generation has
selected `surface_patch_v2`; `point_brush_v1` remains the release default until
both-model focused gates and the manual digging pass are accepted, while
`surface_patch_v2_shadow` is the zero-mutation comparison mode.

### 2. Signatures

```text
BucketSurfaceSweep.build_patch(tool_snapshot: Dictionary,
  classification: Dictionary, terrain_snapshot: Dictionary,
  interaction: Dictionary, tick: int) -> Dictionary
SoilCellPatch.validate_for_snapshot(patch: Dictionary,
  snapshot: Dictionary) -> Dictionary
SoilCellPatch.volume_metrics(patch: Dictionary,
  snapshot: Dictionary) -> Dictionary
TerrainState.cell_patch_read_snapshot() -> Dictionary
TerrainState.preview_cell_patch(patch: Dictionary) -> Dictionary
TerrainCommitScheduler.queue_cell_patch(sequence: int, patch: Dictionary,
  generation: int, transfer_id: String) -> bool
TerrainCollider.prepare_snapshot(snapshot: Dictionary) -> bool
TerrainCollider.install_prepared(snapshot: Dictionary) -> bool
TerrainCollider.restore_snapshot(snapshot: Dictionary) -> bool
ActiveSoilPatch.reserve_predebited_volume(event: Dictionary,
  aggregate_hint: String, compartment: String = "active") -> Dictionary
ActiveSoilPersistentField.schedule_tool_flux(dirty_rect_cells: Rect2i,
  horizontal_impulse_xz: Vector2) -> bool
SoilInteractionAuthority.settle_all_for_boundary(patch: ActiveSoilPatch,
  tick: int, origin_world: Vector3) -> Dictionary
ExcavationWorld.set_soil_surface_solver_mode(value: String) -> bool
```

### 3. Contracts

- `BucketSurfaceSweep` consumes accepted previous/current semantic transforms
  and is mutation-free. Adaptive sampling that exceeds the descriptor cap marks
  `sweep_discontinuous` and emits no patch. Sampling bounds the most distant
  semantic point's rotational travel, not only `bucket_link.origin`. An explicit
  active classification is a hard deny, but a sparse classifier `none` result
  may be recovered by the continuous surface's own motion/role/overlap proof.
  Only actions `cut`, `side_cut`, `scrape`, or `grade` remove terrain;
  push/back-drag/compact move existing loose material instead.
- Box semantic surfaces align their thickness axis with
  `outward_normal_godot`; diagonal floor/back normals must not be flattened into
  bucket-link-aligned faces. Heightfield coverage is conservative over each
  sample's square support cell (half-cell expansion), not a point-only triangle
  test and not an arbitrary circular brush.
- Every fixed tick merges all eligible teeth, side, floor, and outer-face offers
  into one sorted, unique, absolute-target `soil-cell-patch-v2`. Inner shell and
  opening have no stable role. A one-cell closure is allowed only when the cell
  is proven inside swept coverage and enclosed by four already-cut cardinal
  neighbors; closure is computed from a frozen offer set and cannot flood-fill.
- Patch rows carry original/target stable and loose Float32 values, action, and
  sorted contributors. Generation/base revision, row order, originals, finite
  values, safety floor, dirty rectangle, derived volume metrics, and SHA-256
  must all validate before mutation. Metadata never overrides row-derived
  volume.
- `TerrainCommitScheduler` previews one immutable candidate snapshot, prepares
  all changed collider chunks, installs the prepared candidate, commits the
  authoritative rows once, then publishes that same revision to the renderer.
  A prepare/install failure leaves terrain unchanged. The post-install invariant
  branch restores the previous collider snapshot before returning failure.
- Sweep/patch validation uses `cell_patch_read_snapshot()`, a synchronous
  copy-on-write stable/loose view with no synthesized surface bytes or SHA. Full
  presentation snapshots are materialized only for a candidate collider and the
  committed renderer revision. Live collision chunks default to 16 cells so a
  small patch does not rebuild a 32x32 concave shape every physics tick.
- Logical active aggregates own volume/provenance; visual representatives are
  deterministic derivatives and quality changes affect only those derivatives.
  Transfers reserve destination capacity before source debit. Any partial bucket
  acceptance restores the exact unaccepted active volume.
- Settlement is a `settle_loose` absolute cell patch whose committed volume is
  derived from quantized target rows. Repose flow moves loose depth only through
  simultaneous four-neighbor proposals. The bounded frontier survives across
  ticks until below repose; horizontal tool impulse may bias push/back-drag flow
  without minting or deleting volume.
- Material-ledger values are deltas relative to the generation baseline; their
  sum must remain zero. An ordinary local authority boundary drains transient
  compartments to persistent loose terrain. Only world reset or the explicitly
  user-approved Bucket Pass transition may intentionally discard the generation.
- Solver selection remains generation-bound. The public runtime setter performs
  an ordinary drain/pose-history clear and begins a clean generation; it may not
  return success while only changing the requested value. Status/payload getters
  queried re-entrantly during that boundary return an empty transitional fill
  profile instead of indexing cleared bucket cells.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Sparse classifier returns `none`, but semantic role/motion and swept surface prove overlap | Rasterize the continuous surface; do not inherit the point-probe miss |
| Explicit active/non-stable role, rest/separation, inner/opening, or discontinuous sweep | Emit no debit and leave terrain bytes/revision unchanged |
| Duplicate/unsorted row, stale generation/revision, original mismatch, non-finite target, bad metadata/hash/dirty rectangle | Reject before collider preparation or terrain mutation |
| Collider prepare/install fails | Reject patch; TerrainState and prior collider identity stay unchanged |
| Terrain invariant fails after collider install | Restore the previous collider snapshot and reject; increment rollback diagnostics only if compensation fails |
| Active/bucket/released destination lacks capacity | Retain exact source; publish no accepted transaction or authoritative visual event |
| Settlement scheduler rejects | Retain residual logical aggregate volume for retry |
| Loose frontier reaches below repose | Clear retained frontier; do not emit another terrain revision |
| Ordinary model/pose boundary cannot drain | Preserve current authority/material, report runtime failure, and do not clear |
| UI/status reads during solver generation replacement | Return a valid transitional status with empty fill profile; never index cleared cells |

### 5. Good / Base / Bad Cases

- Good: accepted semantic sweep -> one validated cell patch -> prepared collider
  transaction -> exact stable/loose debit -> logical aggregate -> bucket ->
  released -> exact loose settlement and bounded repose flow.
- Base: `surface_patch_v2_shadow` runs `point_brush_v1` as the unchanged product
  writer and computes v2 diagnostics as a read-only sibling; the terrain and
  ledger outcome must equal a pure v1 run for the same input.
- Bad: convert v2 rows back into overlapping brushes, let a visual clod own
  volume, clear mobile soil on model activation, or accept whichever collider
  identity happens to answer first.

### 6. Tests Required

- `surface_sweep_patch_test.gd`: both models, flat/slope continuity, semantic
  tooth/side/floor/outer coverage, bounded envelope, region permutation,
  diagonal plate orientation, far-point rotation sampling, the product
  `129x129 @ 0.5m` grid, sparse-probe recovery, isolated-spike closure,
  rest/separation/non-stable/discontinuity fail-closed, and unchanged cells
  outside canonical rows. Identity-basis `41x41 @ 0.25m` fixtures alone are not
  product acceptance evidence.
- `terrain_cell_patch_test.gd` and
  `terrain_cell_patch_collider_test.gd`: exact layer metrics, one revision,
  malformed/stale/tampered rejection, prepare/install zero side effects,
  post-install compensation, and collider/TerrainState identity equality.
- `soil_surface_authority_test.gd`, `soil_interaction_authority_test.gd`, and
  `active_soil_patch_test.gd`: exact source split, destination-first transfers,
  both-model journeys, 20 cycles, ordinary-boundary drain, quality-independent
  logical digest, and zero invariant failures.
- Migration/runtime tests switch the public solver setter, assert requested and
  selected modes match immediately after its clean boundary, and query both
  SY205/SY135 fill profiles plus the cleared transitional authority.
- `loose_soil_flux_test.gd`: below-repose rest, conservative convergence,
  order equivalence, compaction response, tool-biased push, retained frontier,
  and exact typed settlement.
- Before selecting product v2, manually verify full-width clean cuts, no spikes,
  intuitive carry/dump/pile behavior, no commit-tick collider blocking, and
  unchanged Terrain3D materials/vegetation on both models.

### 7. Wrong vs Correct

```text
Wrong: several bucket faces -> several overlapping brushes -> repeated debit
Correct: several semantic sweeps -> one sorted unique absolute-target cell patch

Wrong: quality=low -> merge/drop authoritative soil aggregates
Correct: logical aggregates unchanged -> rebuild fewer disposable visual samples

Wrong: model activation -> clear active patch and bucket -> leave cut terrain behind
Correct: ordinary boundary -> exact transient drain -> clear only after success

Wrong: synthetic 0.25 m identity-frame sweep passes -> assume product geometry passes
Correct: also assert real diagonal semantic axes and the product 0.5 m grid

Wrong: every v2 tick -> full surface bytes + duplicated layers + SHA even when idle
Correct: synchronous cell-patch read view -> full immutable snapshot only at commit boundaries
```

## Scenario: Visual-first arcade excavation stamp

### 1. Scope / Trigger

Use this contract when the generation selects `active_patch` plus
`arcade_stamp_v3`. This candidate prioritizes a continuous, decisive trench and
bounded frame cost over soil conservation. It must not enter
`SoilInteractionAuthority`, `ActiveSoilPatch`, `ActiveSoilPersistentField`,
`LooseSoilFluxSolver`, or the semantic full-surface classifier. The release
default remains `point_brush_v1` until the human Forward+ digging gate accepts
v3.

### 2. Signatures

```text
ArcadeExcavationStamp.configure(state: TerrainState,
  scheduler: TerrainCommitScheduler, contract: Dictionary) -> bool
ArcadeExcavationStamp.step_fixed(delta: float, pose_snapshot: Dictionary,
  tick: int) -> Dictionary
ArcadeExcavationStamp.build_proposals(pose_snapshot: Dictionary,
  terrain_snapshot: Dictionary, was_engaged: bool) -> Dictionary
ArcadeBucketLoadState.credit_accepted_cut(removed_volume_m3: float,
  tick: int, patch_hash: String, fill_gain: float = 1.0) -> Dictionary
ArcadeBucketLoadState.dump_visual_load(release_world: Vector3,
  tick: int) -> Dictionary
TerrainState.minimum_stable_height_for_index(index: int) -> float
SoilEffects.apply_visual_snapshot_for_test(status: Dictionary) -> void
```

### 3. Contracts

- Only accepted previous/current `cutting_edge` transforms, model contract,
  opening orientation, generation identity and the synchronous cell-patch read
  view enter the v3 hot path. Invalid history, movement below `0.002 m`, travel
  above `2 m`, and an edge outside the hysteretic terrain work band emit no
  terrain target.
- The projected cutting edge is widened by `1.25`, interpolated at no more than
  half-cell travel, rasterized as swept quads plus a bounded support radius, and
  stores at most one latest-minimum absolute target per terrain index. Width and
  interpolation deliberately favor eliminating gaps and residual spikes.
- Pending targets coalesce for `100 ms`. A flush emits one sorted
  `soil-cell-patch-v2`, removes at least `0.18 m` where allowed, caps one flush
  at `0.45 m`, and respects `minimum_stable_height_for_index()`. The scheduler
  remains the sole TerrainState/collider/presentation revision writer.
- Pending targets are cleared only when they are obsolete/no-op or their exact
  transfer ID is committed. Queue, collider or TerrainState rejection retains
  them so the next 100 ms window rebuilds originals from the latest revision
  and retries. Rejected work never credits bucket fill.
- `ArcadeBucketLoadState` is presentation/payload compatibility state, not a
  material ledger. Accepted changed volume increases one bounded scalar fill;
  dumping clears it and publishes one generation-scoped event with
  `accepted_dump_event_id`, `dump_release_world`, and
  `dump_released_fill_ratio`. Removed terrain need not be restored.
- `SoilEffects` maps each new dump event to a shared-mesh, non-colliding visual
  mound. The bounded pool recycles oldest entries and clears on material/world
  generation reset. Duplicate event IDs do not spawn twice; emission disable
  may stop particles but does not erase already placed mounds.
- Solver selection stays generation-bound. v3 owns the existing `active_patch`
  product-writer slot but resets and bypasses all v2 runtime objects. Enabling
  the diagnostic active-soil prototype while v3 is selected must not construct
  an `ActiveSoilPatch`. Bucket pass-through remains the first early exit and
  clears v3 scalar/presentation state through the ordinary generation boundary.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Invalid/non-finite pose, stationary edge, above-band edge | No proposal, no fill, no revision |
| Pose travel exceeds `2 m` | Clear engagement for that sample; do not bridge the teleport |
| Duplicate cell offers within/between fixed ticks | Keep one lowest pending target |
| Queue/collider/TerrainState commit rejection | Retain targets for retry; do not credit visual load |
| Target below terrain safety floor | Clamp to the per-index minimum before patch validation |
| Dump with empty load, invalid pose/orientation or outside terrain | No dump event and no mound |
| Repeated dump event ID | Preserve the existing mound count |
| Mound pool at capacity | Recycle oldest mesh; never create a collision object |
| Model/world/material generation change | Clear pending stamp, scalar load, dump identity and mound pool |
| v2 prototype toggle during selected v3 | Keep `ActiveSoilPatch` and lifecycle authority absent |

### 5. Good / Base / Bad Cases

- Good: moving edge in terrain band -> gap-free coalesced stamp -> one accepted
  terrain revision -> scalar visual fill -> dump event -> pooled visual mound.
- Base: `point_brush_v1` remains unchanged and selected by default before human
  acceptance; v2 remains available only as an unaccepted diagnostic path.
- Bad: invoke the semantic surface classifier/loose flux each frame, clear a
  rejected target, credit fill before commit, or add physics to a visual mound.

### 6. Tests Required

- `arcade_excavation_stamp_test.gd`: SY205/SY135 width, slow/fast sweeps,
  connected 5 m coverage, stationary/above/teleport guards, exactly one 100 ms
  commit, accepted-only fill, injected apply rejection and next-window retry.
- `arcade_excavation_world_test.gd`: clean generation selection, selected scalar
  payload, absence of v2 authority/patch, and prototype-toggle isolation.
- `soil_effects_visual_mound_test.gd`: event de-duplication, bounded recycling,
  generation clear, and absence of collision nodes in the mound pool.
- Human Forward+ acceptance owns cleanliness, responsiveness, material look and
  perceived stutter for both models. Run it only after focused Agent tests are
  stable; do not replace it with long automated visual soaks.

### 7. Wrong vs Correct

```text
Wrong: every physics tick -> full semantic classifier -> active material/flux -> forced terrain commit
Correct: cutting-edge pose -> bounded swept stamp -> 100 ms latest-minimum coalescer -> one patch

Wrong: clear pending rows before scheduler acceptance
Correct: clear only committed/no-op rows; retain rejected targets for retry

Wrong: dump visual load -> authoritative loose soil or Jolt mound collision
Correct: clear scalar load -> generation-scoped event -> pooled non-colliding mesh
```

## Scenario: Game-feel digging response

### 1. Scope / Trigger

Use this contract when soil contact and bucket loading should feel heavy through
bounded work-equipment speed reduction. It is a normalized game response, not a
hydraulic, structural, engine, pump, valve, cylinder-force, or stress model.

### 2. Signatures

```text
DiggingResponseShaper.configure(model_id: String) -> bool
DiggingResponseShaper.set_enabled(value: bool) -> void
DiggingResponseShaper.reset_response(reason: String = "reset") -> void
DiggingResponseShaper.step_fixed(delta: float, raw_commands: Vector4,
  soil_status: Dictionary) -> Dictionary
TrackedChassisController.set_digging_response_enabled(value: bool) -> void
JoltChassisTrackRuntime.set_external_digging_response_enabled(value: bool) -> void
```

Profiles live in
`res://resources/physics/digging_response_profiles.json`; compact telemetry is
the optional strict `simulation-truth-v1.digging_response` field.

### 3. Contracts

- Phases are `free`, `contact`, `scrape`, `cut`, `load`, `overflow`, `blocked`,
  `dump`, and `escape`. Inputs are semantic tool action/contact, accepted ledger
  flow, stable/active scope, material preset, fill ratio, overflow, and command
  direction. Presentation quality is not an input.
- Response profiles share semantics across SY205/SY135 and tune only minimum
  scale, attack/release, scale slew, hysteresis, blocked delay, flow reference,
  and per-axis weights. Material presets contribute normalized intensity only.
- `TrackedChassisController` shapes raw equipment axes immediately before the
  existing Jolt equipment-command boundary. Swing always has scale 1. Only
  negative boom/arm/bucket commands (the rig's into-work convention) may slow.
  Positive commands always retain escape/retraction authority.
- Speed scales are finite, never exceed 1, never reach zero, and are filtered by
  phase-aware attack/release plus an explicit maximum scale slew per second.
  Blocked contact cannot stall a joint; positive escape selects the faster
  recovery path.
- When the external shaper is configured, Jolt keeps its penetration engagement
  as diagnostic evidence but disables the old articulation-level second scale.
  Direct/fallback users that do not enable the shaper retain the old bounded
  penetration response.
- Disable, stop, focus loss, neutral re-arm, reset, model/authority change, and
  runtime rebuild restore phase `free` and scale 1 without changing a soil
  transaction, payload, or terrain snapshot.
- Telemetry includes phase, intensity, four scales, flow, fill, overflow,
  sequence, model, and source ledger identity. HUD/VFX/audio/camera may read or
  smooth a copy but cannot feed it back into motion or the material ledger.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Missing/invalid model profile or finite input | Reject configuration/input; return unavailable and do not scale |
| No contact or free motion | Phase `free`; scales release toward 1 |
| Stable contact with low/no flow | `contact`, then `blocked` after bounded delay; nonzero clamp remains |
| Scrape/grade/push while working inward | `scrape`; scale only negative working axes |
| Productive cut and rising fill | `cut` then `load`; smooth stronger response |
| Capacity overflow | `overflow`; retain nonzero control and expose overflow |
| Dump or positive retract/escape | Faster release toward scale 1; never apply inward resistance |
| Feature disabled, reset, neutral, or model switch | Immediate logical reset to free/unit scale; soil state unchanged |

### 5. Good / Base / Bad Cases

- Good: ledger/tool snapshot -> normalized phase/intensity -> hysteretic shaper
  -> raw equipment axes scaled once -> Jolt safe articulation boundary.
- Base: response disabled/unavailable -> raw equipment axes pass through exactly
  and existing safety/neutral behavior remains active.
- Bad: fabricate pump pressure, slow positive retraction, alter presentation
  transforms after accepted motion, or apply both old and new speed scales.

### 6. Tests Required

- Record deterministic free/contact/scrape/cut/load/overflow/dump/blocked/escape
  curves for both models and assert productive cut is slower than free motion.
- Assert model minimum scale, unit maximum, per-tick scale-slew ceiling, no
  chatter, phase hysteresis, blocked delay, and prompt escape recovery.
- Verify disabling or presentation mutation cannot change commands, ledger,
  payload, terrain, or accepted material transactions.
- Keep direct cut-resistance fallback, neutral/re-arm, model switch, both-model
  Jolt, lifecycle, simulation-truth schema, standalone, and backend gates green.

### 7. Wrong vs Correct

```text
Wrong: soil intensity -> invented hydraulic pressure -> Jolt force
Correct: normalized soil phase/intensity -> bounded command speed scale

Wrong: inward scale * old penetration scale -> accidental double slowdown
Correct: external shaper active -> old engagement remains telemetry-only

Wrong: positive retraction slowed because contact is still present
Correct: positive retraction -> escape phase -> rapid unit-scale recovery
```

## Scenario: Bucket pass-through performance policy

### 1. Scope / Trigger

Use this contract for a process-local mode that removes bucket/ground physics,
soil, and effects work while retaining visible terrain and normal chassis/track
support. It is not a visual-quality, Terrain3D-backend, soil-owner, or simulation
authority profile.

### 2. Signatures

```text
ProductSession.request_bucket_ground_mode(mode: String) -> bool
TrackedChassisController.can_set_bucket_ground_mode(mode: String) -> bool
TrackedChassisController.set_bucket_ground_mode(mode: String) -> bool
ExcavationWorld.can_set_bucket_ground_mode(mode: String) -> bool
ExcavationWorld.set_bucket_ground_mode(mode: String) -> bool
JoltChassisTrackRuntime.set_bucket_ground_mode(mode: String) -> bool
SoilEffects.set_bucket_ground_mode(mode: String) -> bool

backend/scripts/jolt_product_soak.py
  --bucket-ground-mode {normal,bucket_passthrough} [...]
  --repetitions 1..9
```

### 3. Contracts

- The only values are `normal` and `bucket_passthrough`; launch default is
  `normal`, the selection is not persisted, and ProductSession commits a valid
  requested mode at the next physics tick after all participants preflight.
- The selected mode survives process-local start/pause/reset/reconnect, model
  switch, Jolt rebuild, Test Grid, and Terrain3D fallback/recovery.
- Pass-through still accepts ordinary articulation commands at full accepted
  fraction, but skips bucket proxy sweep/contact collection, cut probe,
  articulation terrain clamp, support wrench queue/apply, legacy ground lift,
  and external digging-response shaping.
- `TerrainCollider`, track probes, heightfield fallback, hull/chassis collision,
  traction, stabilization, locomotion, and terrain presentation remain active.
- Entry and exit use the existing clean local-material boundary: selected
  payload, active/released material, parcels, pending brushes/transfers, pose,
  support, feedback, patch/presenter, and effects clear. The separate material
  generation advances; `TerrainState.world_generation`, `terrain_revision`, and
  committed surface bytes do not change because of the mode transition.
- While bypassed, production and test/manual entry points return before soil
  classification, authority/patch/parcel/settle/commit/feedback/effects work.
  Suppressed work never replays on exit.
- Status dictionaries expose the mode plus monotonic submitted/executed/
  bypassed counters. Logging is transition-bounded, never per-frame.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Unknown mode | Return `false`; keep active mode and expose `invalid_bucket_ground_mode` |
| Participant not initialized at preflight | Reject the pending transition; UI returns to the real active mode |
| Unexpected post-preflight setter failure | Close both sides to `normal`, clear transient material, and expose a bounded transition error |
| Repeated request for active mode | Idempotent success; no new material generation |
| Enter/exit with payload or pending work | Deliberately clear it; do not fabricate a conservation transaction |
| Bypassed bucket tick | Synthetic query has full accepted fraction, no contacts, and `bucket_ground_interaction_bypassed` |
| Reset/model/runtime rebuild while bypassed | Reapply the stored policy before the next runtime physics step |

### 5. Good / Base / Bad Cases

- Good: UI request -> ProductSession fixed-tick preflight -> controller/Jolt and
  excavation/effects switch -> clean empty material generation -> counters.
- Base: `normal` -> the existing query, digging response, material, terrain,
  effects, and release soak behavior is unchanged.
- Bad: disable `TerrainCollider`, infer the mode from Test Grid, merely hide
  particles while soil keeps stepping, or retain a queued support wrench.

### 6. Tests Required

- For SY205 and SY135, assert deferred activation, full-motion contact-free
  synthetic query, zero cut/support response, advancing bypass counters, and a
  still-enabled terrain collider/track path.
- Compare pre/post-transition terrain generation, revision, and SHA-256; assert
  the material generation advances and selected payload becomes zero.
- Exercise production ticks plus `queue_cut_world`, `queue_deposit_world`,
  manual dig/deposit, and fixed-step test seams while bypassed.
- Verify reset and model/runtime rebuild retain the mode, stale support/soil
  work does not replay, and exiting restores normal behavior.
- Keep the focused deterministic mode, Jolt payload/support, lifecycle, and
  normal-restoration gates selected through `validation-budget.md`.
- The paired normal/pass-through soak was completed and accepted for this
  performance mode. It is retired as a development, release, and archive gate;
  do not rerun it for ordinary regression evidence. Preserve the archived
  report as historical evidence.
- A future paired performance comparison requires an explicit new user-approved
  performance evaluation scope. The retained runner capability does not make
  the comparison an automatic gate.

### 7. Wrong vs Correct

```text
Wrong: performance mode -> disable TerrainCollider -> tracks lose ground support
Correct: performance mode -> bypass only bucket query/cut/support -> tracks unchanged

Wrong: emission=false -> active soil/patch/parcel/commit work continues invisibly
Correct: one shared mode -> early-return before soil and effects execution

Wrong: runtime reset -> default query policy for one tick -> stale support replay
Correct: stored controller policy -> reapply immediately after every Jolt rebuild

Wrong: accepted performance mode -> rerun paired soak at every release/archive
Correct: focused contract checks -> preserve archived performance evidence -> no paired soak
```

## Scenario: Bounded Voxel Tools excavation ownership

### 1. Scope / Trigger

Apply this contract whenever terrain rendering, Jolt track support, work-zone
layout, reset, or a future soil edit touches the bounded north-side voxel work
zone. It is the transitional authority seam while legacy excavation remains
available outside the zone.

### 2. Signatures

```text
VoxelWorkZoneConfig.owns_world_xz(world_xz: Vector2) -> bool
VoxelWorkZoneConfig.world_to_voxel(world_position: Vector3, scale_m: float) -> Vector3
VoxelWorkZoneConfig.voxel_to_world(voxel_position: Vector3, scale_m: float) -> Vector3
VoxelCollisionReadiness.issue(area_voxels: AABB, purpose: StringName) -> Dictionary
VoxelCollisionReadiness.mark_meshed(ticket: Dictionary) -> bool
VoxelCollisionReadiness.acknowledge_query(ticket: Dictionary) -> bool
VoxelCollisionReadiness.is_point_ready(voxel_position: Vector3) -> bool
VoxelWorkZone.is_support_ready_at(world_position: Vector3) -> bool
```

### 3. Contracts

- One centralized half-open mask owns world `X=[-16,16), Z=[8,40)` and the
  `Y=[-6,4)` volume. Terrain3D control holes, fallback topology and the project
  hard collider must all consume that exact predicate; local copies are
  forbidden.
- Terrain3D and `TerrainCollider` remain immutable hard-ground derivatives
  outside the mask. Inside it, smooth 16-bit SDF in bounded `VoxelTerrain` is
  soil truth and generated Voxel Tools collision is the only ground collider.
- Voxel coordinates are always converted through the configured uniform node
  scale and origin. The selected foundation scale is `0.125 m`; mesh blocks are
  16 voxels and the protected edit shell is two voxels.
- A readiness ticket carries `ticket_id`, `generation`, `revision`, voxel AABB,
  purpose, meshed state and changed-geometry query acknowledgement. The newest
  overlapping ticket decides readiness at a point; an unrelated regional edit
  must not disarm already-ready support elsewhere.
- `is_area_meshed()` is necessary but not sufficient. Jolt support is published
  only after a physics query sees the expected newest geometry. Reset advances
  generation, recreates the terrain and rejects all old tickets.
- `TerrainState.sample_surface_bilinear_at()` and matching-heightfield fallback
  remain valid only outside the voxel mask. A ray miss, stale voxel ticket, or
  collision-pending point inside the mask returns no synthetic heightfield
  support.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Point outside voxel mask | Terrain3D/fallback/project collider own hard support |
| Point inside voxel mask, newest ticket ready | Voxel collision may report `support_source=voxel_terrain` |
| Point inside voxel mask, ticket pending/stale | No heightfield fallback; track support fails closed |
| Older overlapping mesh/query completion | Reject; never advance readiness |
| New edit in disjoint region | Preserve ready support at unaffected points |
| Reset while mesh/collider work is pending | Advance generation and reject every pre-reset completion |
| Missing Voxel Tools class/resource | Foundation reports a stable error; never restore hard collision inside the mask |

### 5. Good / Base / Bad Cases

- Good: shared ownership mask -> one visible/collidable surface per point ->
  newest regional mesh plus changed Jolt query -> ready support.
- Base: local edit pending -> only its affected area is disarmed while the rest
  of the ready zone and the hard apron remain usable.
- Bad: Terrain3D hole with an unmasked `TerrainCollider`, or a voxel ray miss
  silently synthesized from `TerrainState` inside the work zone.

### 6. Tests Required

- `voxel_work_zone_config_test.gd` asserts half-open bounds, coordinate round
  trips, protected inset, overlapping-ticket supersession and reset rejection.
- `voxel_work_zone_seam_test.gd` asserts the Terrain3D control hole, fallback
  triangle omission and hard-collider omission use the same predicate.
- `voxel_work_zone_scene_test.gd` asserts the main scene creates the zone and
  entrance boundary, obtains exclusive voxel/hard ray hits and rebuilds safely
  after reset.
- `voxel_work_zone_foundation_probe.gd` compares configured scales with one
  connected bucket-sized removal, raw backlog statistics and changed-geometry
  collision acknowledgement. Visual seam and traversal quality remain human.

### 7. Wrong vs Correct

```text
Wrong: inside voxel zone -> Voxel collision pending -> TerrainState height fallback
Correct: inside voxel zone -> newest regional ticket pending -> no support until changed-geometry Jolt acknowledgement
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
- Every control-map cell uses material ID 0. The map remains present for
  Terrain3D hole semantics, but no product region selects a demo ground or grass
  texture role.
- `worksite_soil_common.gdshaderinc` is the single source for compacted,
  disturbed/loose, slope, damp-center, track-lane, macro-distance, roughness,
  and specular calculations. Fallback and native shaders supply only their
  geometry/normal/camera inputs.
- Native Terrain3D uses the complete 1.0.2 minimum clipmap/geomorph/height/hole/
  normal seam plus the shared PBR include through a project-owned
  `Terrain3DMaterial.shader_override`. Two official texture slots remain loaded
  only because Terrain3D 1.0.2 requires initialized assets; the override does not
  sample them.
- Native demo dressing is an explicit adapter opt-in and defaults false. Product
  runs create no Terrain3D rocks, grass particles, trees, or foliage, and keep
  world background off. Shared code-native `ConstructionSiteDressing` remains.
- `godot-terrain-state-v3-construction-site` initializes one 64 m authoritative
  surface: a level central 20 m work pad plus deterministic outer grades/spoil.
  The visible construction map and `TerrainCollider` derive the same complete
  footprint; presentation-only ground beyond the support grid is forbidden.
  Stable/loose edits and reset semantics remain unchanged after initialization.
- The optional diagnostic/demo dressing seam is bounded to 18 official rocks
  outside the logical rectangle and grass particles with a 12 m central
  exclusion radius. It is created only when
  `native_demo_dressing_enabled=true`; product default creates neither. The
  optional layer adds no collision objects.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Invalid/incomplete logical snapshot | Return an empty presentation; adapter stays fail-open |
| Terrain3D asset classes unavailable | Return no native assets; retain custom renderer |
| Logical grid point sampled in presentation | Height is bit-for-bit equal to the logical surface value |
| Point outside logical rectangle | May receive deterministic presentation shaping/materials only |
| Shared include, native override, or initialization assets unavailable | Adapter stays fail-open and keeps the custom renderer |
| Native Terrain3D backend inactive | Hide the dressing layer with the native terrain |

### 5. Good/Base/Bad Cases

- Good: accepted snapshot -> exact central patch + shared project worksite cues
  + project procedural native/fallback soil.
- Base: native backend unavailable → unchanged custom renderer/collider path.
- Bad: editor painting or Terrain3D height queries update logical terrain or
  bucket inventory.

### 6. Tests Required

- `construction_site_terrain_test.gd` asserts 64 m dimensions, exact logical
  patch parity, one procedural material role/ID, initialized native assets, and
  deterministic shared worksite layout.
- `terrain3d_adapter_test.gd` asserts the project material/override identity,
  default-off native demo dressing/background/texture sampling, presentation
  dimensions, snapshot guards, fallback, and Jolt collision seam.
- `visual_pass_test.gd` asserts the native product default/project material,
  fallback shader identity, Test Grid material retention/restore, unchanged
  Sky3D/shared cues/effects/camera/UI budgets, and native demo dressing
  exclusions across quality profiles.
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
- The simulation viewport carries no permanent third-party credit overlay.
  Packaging and distribution retain the complete ESO/S. Brunier Milky Way
  title, author, source, modification note, and CC BY 4.0 license in
  `NOTICE.md` and the adjacent third-party provenance/license files.

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
  absence of a permanent attribution overlay.
- A real Forward+ smoke must inspect the running frame and current-run logs;
  headless state tests do not prove shader, cloud, or horizon rendering.

#### 7. Wrong vs Correct

```text
Wrong: quality profile -> silently skip missing Sky3D -> report success
Correct: quality profile -> VisualEnvironment -> Sky3D or explicit failure
```

## Scenario: Operator-first onboarding and HUD

### 1. Scope / Trigger

Use this contract for product-visible lifecycle, model, control, selected soil,
warning, recovery, and diagnostic presentation in the main Godot scene.

### 2. Signatures

```text
MotionOperatorUI.show_control_guide() -> void
MotionOperatorUI.set_prompt_mode_for_test(mode: String) -> void
MotionOperatorUI.set_test_graphics_for_test(enabled: bool) -> void
ExcavationWorld.get_selected_soil_payload_snapshot() -> Dictionary
ProductSession.request_reset() -> bool
ProductSession.request_model_switch(model_id: String) -> bool
```

### 3. Contracts

- The default HUD shows model/lifecycle, current work phase, selected-authority
  bucket fill, supported control prompts, warnings, and recovery. Session IDs,
  authority epochs, generation/revision, ACK, penetration, engagement,
  velocities, and focus diagnostics are visible only after Advanced is opened.
- Bucket fill is read from `get_selected_soil_payload_snapshot()`. Visible
  particles, hero clods, legacy parcel counts, and presentation meshes are never
  payload truth. World/material/source generation changes clear transient UI
  phase before the current selected snapshot is rendered.
- The first-run guide is dismissible, recallable, preference-backed, and
  explains lifecycle, independent tracks, work equipment, camera, model switch,
  reset, and automatic physical excavation. It must not advertise bindings that
  do not exist.
- The gamepad prompt names the ISO excavator pattern and projects the canonical
  left-stick swing/arm, right-stick boom/bucket, LT/LB left-track and RT/RB
  right-track bindings. Any joy button or axis event selects this prompt; the
  next keyboard/mouse event restores the keyboard prompt without changing input
  authority or arming state.
- The top-left status panel has an always-available sibling toggle. Collapsing
  the panel hides its body without hiding the restore control, changing motion,
  or dismissing the separate first-run guide.
- `Test Grid` selects the `test` visual-quality identity and restores the prior
  product profile when disabled. It changes presentation only and remains
  independent of session/reset confirmation.
- The most recently observed keyboard/mouse or gamepad input selects prompt
  copy. Gamepad equipment mappings may be shown; track/camera prompts remain
  keyboard/mouse until those controllers own real gamepad actions.
- In `main.tscn`, `MotionOperatorUI` owns F6/F7/F8 routing. ProductSession and
  MotionClient retain embeddable lifecycle-input defaults, but their scene
  instances disable direct routing so F8 cannot bypass product confirmation.
- Reset and model switch do not dispatch before explicit confirmation. Success
  is reported only after an authoritative generation/model transition. Cancel,
  rejection, focus loss, pause, gateway failure, and neutral re-arm never mutate
  soil from UI code and resynchronize from authority snapshots.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Selected soil snapshot unavailable | Show unavailable/empty operator state; do not inspect visual representatives |
| Reset/model choice pending | Preserve generation/model until confirmation |
| Authority transition completes | Clear stale soil UI and show one completion/re-arm message |
| Focus lost, stopped/paused, or neutral not armed | Show concise recovery guidance for the active device; motion stays safely gated |
| Gateway disconnected | Show operator recovery by default and connection details only in Advanced |
| Preference read/write fails | Guide remains usable for the current run; startup continues |

### 5. Good / Base / Bad Cases

- Good: selected ledger + lifecycle snapshots -> operator hierarchy -> optional
  Advanced details.
- Base: missing gateway/soil status -> readable recovery/unavailable state.
- Bad: particle count -> fill gauge, or F8 -> immediate reset behind the dialog.

### 6. Tests Required

- `operator_ui_test.gd` covers 1280×720/1920×1080 bounds, default/Advanced
  hierarchy, keyboard/gamepad prompts, guide recall, reset/model confirmation,
  local/gateway recovery, both models, and soil generation clearing.
- Prompt tests dispatch real `InputEventJoypad*` and `InputEventKey` instances,
  assert the mode changes, and reject the obsolete keyboard-only track or
  trigger-bucket copy.
- `offline_product_test.gd`, model-switch coverage, and the standalone matrix
  retain local authority, optional gateway, lifecycle, and double-model behavior.
- Subjective legibility and composition are reserved for the focused human
  review in the final product-experience task.

### 7. Wrong vs Correct

```text
Wrong: particle count -> bucket fill; F8 -> reset immediately; diagnostics always visible
Correct: selected ledger -> operator state; confirm -> authority transition -> completion

Wrong: gamepad prompt says triggers control bucket and tracks require keyboard
Correct: gamepad prompt mirrors ISO sticks plus LT/LB/RT/RB track actions
```

## Scenario: Semantic camera workflow presets

### 1. Scope / Trigger

Use this contract for product camera mode selection, framing, reset, model/
generation cleanup, quality distance, and read-only occlusion behavior.

### 2. Signatures

```text
CameraRig.set_mode(mode: String) -> bool
CameraRig.reset_view() -> void
CameraRig.get_mode() -> String
CameraRig.set_quality_distance_for_test(max_distance: float) -> void
CameraRig.get_view_snapshot_for_test() -> Dictionary
```

### 3. Contracts

- One Camera3D owns `operator`, `chase`, `work_tool`, `inspection`, and `cab`.
  Presets
  resolve only current `MotionPresentation` semantic frames and model-specific
  framing data; missing mode anchors fall back to the current `base_link`.
- Chase uses base heading, operator uses upper-structure heading, work-tool
  follows the current bucket/contact while retaining machine context, and
  inspection preserves bounded free orbit/zoom.
- Cab uses an explicit model-local eye pose rigidly attached to the current
  `upper_structure_link`; it bypasses orbit, zoom, and occlusion shortening.
  Only the manifest-declared upper-body visual subtree receives duplicated
  per-instance alpha material overrides. Boom, arm, bucket, and tracks retain
  their materials. Exit, model replacement, and teardown restore prior
  overrides; generation reset safely reapplies the still-active cab mode.
- Model activation invalidates cached anchors before resolving the new model.
  Model/authority generation reset restores the current mode preset and clears
  drag/occlusion transients. A queued-for-free visual node is never followed.
- Camera actions are runtime-registered: 1/2/3/4 select external modes, 5 selects
  cab, and gamepad D-pad selects the four external modes; C and
  right-stick-click reset. Middle-drag and wheel retain orbit/zoom outside cab. Input
  remains `_unhandled_input`, so events consumed by product UI do not move it.
- Occlusion performs one read-only terrain/machine-mask ray from outside the
  mode minimum radius. A hit shortens to a clearance; inward correction is
  immediate and outward recovery is bounded. Queries never change physics
  layers, bodies, terrain state, or articulation.
- Missing collision data fails open to finite preset framing. Near clip remains
  in the 0.08–0.22 m safety band. Active quality profiles continue to clamp far
  and maximum intended distance.
- Operator HUD reports and selects the active mode and exposes Reset View;
  diagnostics or screenshot state are not camera authority.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Unknown mode | Reject and preserve current mode |
| Anchor missing or freed | Resolve current base fallback; never dereference old model |
| Terrain/machine query hit | Shorten before hit with minimum radius/clearance |
| Query unavailable or no hit | Recover smoothly to bounded desired position |
| Model/generation reset | Restore current model preset and clear orbit/occlusion transient |
| Quality maximum below preset | Clamp intended distance without changing mode semantics |

### 5. Good / Base / Bad Cases

- Good: current semantic frames + model preset -> bounded focus/position ->
  read-only occlusion -> Camera3D.
- Base: bucket anchor/query absent -> current base fallback and finite view.
- Bad: cache old GLB child, or rewrite a collision mask/body to improve framing.

### 6. Tests Required

- `camera_workflow_test.gd` covers all modes × both models, semantic anchors,
  freed-node switching, keyboard/gamepad actions, orbit/reset, generation reset,
  HUD reporting, deterministic occlusion/recovery, near clip, and quality clamp.
- Offline/UI/visual-state tests retain the main scene and active-mode product
  boundary. Subjective framing is a focused human check at final validation.

### 7. Wrong vs Correct

```text
Wrong: hard-coded SY205 child path -> camera target across model switches
Correct: model_activated -> current semantic frame -> preset -> read-only safety query
```

## Scenario: Shared construction-site presentation

### 1. Scope / Trigger

Use this contract for code-native worksite composition, fallback terrain
material, fixed-daylight tuning, and quality-bounded site dressing.

### 2. Signatures

```text
ConstructionSiteTerrainProfile.build_worksite_layout(maps: Dictionary) -> Dictionary
ConstructionSiteDressing.set_quality_profile(profile: String) -> bool
ConstructionSiteDressing.get_status_snapshot() -> Dictionary
TerrainRenderer.get_status_snapshot() -> Dictionary
```

### 3. Contracts

- `TerrainState` and the selected soil authority remain the only material truth.
  Terrain3D, fallback mesh, procedural shader, and site cues consume accepted
  snapshot derivatives and never write terrain, ledger, payload, or physics.
- `ConstructionSiteDressing` is a sibling of Terrain3D and fallback rendering.
  Its barrier, stake, route, track, pipe, aggregate, and sign layout is seeded,
  height-sampled from the shared presentation map, model-independent, and
  stable across reset/model changes.
- Every code-native cue lies outside the central logical excavation patch and
  contains no CollisionObject3D. It must not obstruct spawn, haul corridor,
  camera queries, tracks, bucket, or Jolt layers.
- Low/balanced/high expose exactly 14/28/45 worksite cues. Low disables cue
  shadows; balanced adds route/stored-material context and bounded shadows;
  high enables deterministic track/aggregate detail. Quality changes alter
  visibility/shadows only, never placement identity.
- Test exposes zero worksite cues and selects the texture-free fallback terrain;
  it is an operator/debug presentation identity, not a fourth simulation quality.
- Fallback `TerrainRenderer` uses accepted vertices/normals with a procedural
  `procedural_worksite_soil` material for compacted, disturbed/loose, damp, and
  macro-distance variation. Shader classifications are visual and cannot enter
  soil material accounting.
- Terrain3D uses the project procedural-soil shader override and creates no
  native demo rocks/grass/trees/foliage. Provenanced demo texture slots are
  retained only as unsampled Terrain3D 1.0.2 initialization inputs. Demo height,
  navigation, UI, and gameplay remain excluded.
- Sky3D remains fixed at 10:30 with one warm daytime sun, deterministic
  atmosphere, bounded SSAO/contact shadow tuning, and no dynamic time/weather.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Snapshot/layout invalid | Create no cues; preserve terrain authority and product startup |
| Native Terrain3D activates/deactivates | Shared dressing identity stays visible and unchanged |
| Model switch or terrain reset | Re-sample height, retain deterministic layout, create no collision |
| Unknown quality | Reject and preserve prior profile/visibility |
| Low/balanced/high | Apply exact cue and shadow budgets |
| Test | Hide all shared/native dressing and expose zero cue budget |
| Fallback renderer active | Use procedural worksite soil material on accepted mesh topology |

### 5. Good / Base / Bad Cases

- Good: accepted terrain snapshot -> shared height map -> disposable site cues;
  accepted mesh -> procedural earth material.
- Base: Terrain3D unavailable -> fallback soil + same code-native worksite cues.
- Bad: prop body enters Jolt, or shader-derived color becomes soil inventory.

### 6. Tests Required

- `construction_site_terrain_test.gd` asserts logical parity, material zones,
  deterministic cue layout/counts, finite heights, and excavation exclusion.
- `visual_pass_test.gd` asserts procedural fallback identity, 14/28/45 quality
  budgets, zero cue collision, shadow policy, fixed Sky3D, and one sun. It also
  asserts test mode has zero cues/particles, inactive native terrain, and the
  visible black/white grid fallback identity.
- Offline/model tests assert site placement does not depend on SY205/SY135 and
  remains deterministic across clean generation resets.
- Subjective work-zone legibility, palette, depth, and silhouette separation
  require the final focused human product-experience review.

### 7. Wrong vs Correct

```text
Wrong: Terrain3D-only props/materials -> different fallback product
Correct: shared code-native dressing + accepted snapshot derivatives -> both backends

Wrong: test mode -> create a second flat debug ground/collider
Correct: test mode -> same accepted fallback mesh -> texture-free grid material
```

## Scenario: Bounded machine/soil feedback presentation

### 1. Scope / Trigger

Use this contract for selected-soil visual effects, procedural machine/effect
audio, mix/mute state, event deduplication, and lifecycle cleanup.

### 2. Signatures

```text
ExcavationWorld.get_soil_visual_snapshot() -> Dictionary
SoilEffects.set_budget(count: int) -> void
SoilEffects.set_emission_enabled(value: bool) -> void
SoilEffects.clear_for_generation(generation: int) -> void
MachineFeedback.set_quality_profile(profile: String) -> bool
MachineFeedback.set_muted(value: bool) -> void
MachineFeedback.stop_all(reason: String = "stop") -> void
MachineFeedback.get_feedback_snapshot() -> Dictionary
```

### 3. Contracts

- Feedback reads selected source/ledger identity, accepted transaction ID/kind/
  volume, interaction batch key, bucket payload, normalized digging response,
  chassis track speed/slip/contact, and ProductSession lifecycle. It cannot call
  terrain, ledger, parcel, patch, Jolt command, or payload write APIs.
- Soil flow, dust, fill, and hero clods are disposable derivatives. Fill is
  shaded irregular geometry; flow grains and clods are nonuniform, deterministic
  shapes; contact dust is a separate bounded pool. None represents inventory.
- Engine, tracks, and work equipment use three preallocated 11.025 kHz
  AudioStreamGenerator loops. Gain/pitch derive from lifecycle, speed/slip,
  commands, and normalized intensity and remain inside -80..-4 dB / 0.62..1.45.
  They are game feedback, not hydraulic/engine/pump/cylinder simulation.
- Accepted cut/dump/spill/settle plus contact/warning/lifecycle cues use a fixed
  six-voice pool and code-generated PCM. Transaction/batch identity and explicit
  cooldowns prevent duplicate/chattering events. No external recording is used.
- Runtime Machine/Effects buses feed Master. Project settings own default dB;
  HUD mute silences players without changing authoritative state or VFX.
- Pause, stop, focus loss, reset, model switch, authority generation, and
  teardown stop loops, clear buffers/cooldowns, and recycle voices/effects.
- Low/balanced/high allow 1/3/3 loops, 2/4/6 voices, particles 500/1800/4200,
  clods 0/32/48, and correspondingly bounded dust counts.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Duplicate transaction/batch identity | Emit no second cue |
| Voice/cooldown exhausted | Drop/merge cue; never allocate a new player |
| Muted or dummy device | Preserve feedback state/VFX; output stays silent/fails soft |
| Pause/focus loss/reset/model switch | Zero active loops/voices and clear event transient |
| Unknown profile | Reject and preserve prior caps |
| Presentation disabled/quality reduced | Material ledger, terrain, payload, and commands remain unchanged |

### 5. Good / Base / Bad Cases

- Good: accepted snapshot identities -> bounded state mapping -> pooled VFX/audio.
- Base: dummy/missing audio -> state and visuals continue without authority impact.
- Bad: visible clod/voice count -> soil volume, or per-event player allocation.

### 6. Tests Required

- `machine_feedback_test.gd` asserts layer mapping, clamps, identity dedupe,
  quality caps, mute, buses, generation/focus/pause cleanup without listening.
- Visual/offline/soil tests assert dust/fill/clod budgets and unchanged selected
  authority/conservation behavior across lifecycle/model boundaries.
- Human final review owns subjective sound mix, clicks, action distinction, and
  close-range effect appeal.

### 7. Wrong vs Correct

```text
Wrong: penetration -> fake soil event -> new volume and new AudioStreamPlayer
Correct: accepted transaction ID -> cooldown -> fixed visual/voice pool
```

### Visual verification operating policy

- Feature implementation prioritizes executable contracts, deterministic tests,
  error-free Forward+ runs, artifact integrity, and performance telemetry.
- Routine commits do not require repeated subjective screenshot inspection.
  Automated captures may establish state, dimensions, nonblank output, hashes,
  and before/after provenance without claiming aesthetic quality.
- Composition, realism, material appeal, animation feel, legibility, and audio
  mix are human judgments. Batch them at an explicit visual milestone and give
  the reviewer the smallest representative model/profile/checkpoint set that can
  answer the decision.
- If a release criterion genuinely depends on a subjective visual judgment,
  leave that criterion pending and request human review; do not substitute pixel
  thresholds or assistant confidence. Full evidence matrices remain appropriate
  for final validation or a suspected renderer regression, not every code task.

```text
Wrong: every soil implementation commit -> assistant screenshot review -> code blocked
Correct: deterministic code gates -> milestone evidence -> focused human review
```

The M7 release candidate retains the legacy Python terrain/recording/replay
profile for compatibility; removal or deprecation requires a separate approved
migration decision and client inventory.

Reference: `docs/godot-integration.md`, `protocol/`, and `.trellis/tasks/08-06-excavator-sim-bootstrap/design.md`.
## Scenario: generation-scoped voxel excavation authority

### 1. Scope / Trigger

- Trigger: excavation inside `VoxelWorkZone` is selected with lifecycle mode
  `voxel` and solver `voxel_bucket_v1`.
- `VoxelExcavationAuthority` is the sole owner of work-zone SDF mutation and
  bucket inventory. TerrainState, active-patch and parcel runtimes must not be
  constructed or stepped while this generation is selected.

### 2. Signatures

```gdscript
VoxelExcavationAuthority.configure(zone, soil_contract, generation) -> bool
VoxelExcavationAuthority.submit_pose(pose_snapshot, identity, delta_s = 1.0 / 60.0) -> Dictionary
VoxelExcavationAuthority.submit_track_compaction(chassis_status) -> Dictionary
VoxelExcavationAuthority.step_fixed(delta) -> Dictionary
VoxelExcavationAuthority.get_payload_snapshot() -> Dictionary
VoxelSoilMaterialField.stage_approximate_cut(coordinates, voxel_volume_m3) -> Dictionary
VoxelSoilMaterialField.can_commit_approximate_cut(staged) -> bool
VoxelSoilMaterialField.commit_approximate_cut(staged) -> bool
VoxelSoilMaterialField.stage_deposit(cell_changes, requested_mass_q) -> Dictionary
VoxelSoilMaterialField.stage_mobile_transfer(removals, additions, requested_mass_q) -> Dictionary
VoxelSoilMaterialField.stage_compaction(coordinates, compaction_delta_q) -> Dictionary
```

`identity` contains `generation`, `physics_tick`, `motion_sequence`, and
`authority_epoch`. Tick and motion sequence must both advance strictly.

### 3. Contracts

- The cutter consumes the hash-bound SY205/SY135 `soil_tool` snapshot and
  produces typed, immutable proposals in local voxel coordinates. SY135
  proposals carry native packed point/radius paths for the authorized leading
  edge, inner/floor occupancy, and optional deep-insertion overburden cleanup;
  the exact capsule representation remains the compatibility/diagnostic path.
- Only adjacent queue-tail proposals may coalesce. Coalescing may never move a
  later fixed tick ahead of an already queued proposal.
- Commits occur at a starting 20 Hz cadence and publish one data revision/ticket
  per accepted transaction. SY135 uses a bounded `VoxelTool.do_path` SDF remove;
  the exact fallback uses one localized `VoxelBuffer` paste.
- All material-stage validation finishes before the irreversible SDF edit. The
  immediately following ledger commit has no remaining conditional failure
  path. Native edits are synchronous but expose no dry-run/rollback result.
- SY135 runtime mass is a declared sparse-coverage approximation: sample solid
  cells along the native path, credit each coordinate at most once until a
  deposit/transfer invalidates that coordinate, and clamp credit to remaining
  capacity. The runtime estimator uses a fixed 1.5-voxel path step and the
  center/+X/+Y three-point stencil; changing it is a mass-calibration change,
  not a geometry-quality change. Exact fallback commits retain one-cell mass
  tolerance.
- Routine material status exposes `material_state_revision` and a deferred
  digest marker; it must not sort/serialize/hash the complete sparse cell table
  after every accepted cut. `state_digest()` remains an explicit diagnostic
  and focused-test operation.
- Inner shell, floor, and overburden paths never authorize deletion alone. They
  are emitted only after the teeth/side leading-front SDF and into-material
  motion gate accepts the complete proposal. Deep insertion may clear the
  overlying column to the initial soil surface to prevent unsupported voxel
  roofs; this intentionally prefers a clean 2.5D cut over tunnel preservation.
- A developer-only capacity override may replace the effective voxel ledger
  capacity at a clean authority generation boundary. It must be finite and
  positive, must not mutate the hash-bound model contract, and status must
  expose contract capacity, override provenance, and effective capacity.
- Terrain3D remains hard-ground presentation outside the voxel zone. Its
  presentation domain must contain the complete half-open voxel X/Z ownership
  domain before applying the shared hole mask; no owned voxel cell may be
  omitted because the presentation map ends early.
- Terrain3D 1.0.x `import_images` positions pixels from the beginning of the
  containing native region, not from an arbitrary sample origin. The adapter
  must therefore pad semantic presentation maps to complete region blocks and
  import them from an origin aligned to `region_size * vertex_spacing` on both
  axes. Source-byte mask parity alone is insufficient evidence.
- Mesh and collision revisions are derivative readiness projections; they
  cannot reject or alter an accepted SDF/mass transaction.
- Deposit, settle, and compaction share this authority, one journal, and the
  same readiness ticket path. Visual mounds, dust, and clods consume committed
  transaction IDs only and never own material.
- Runtime dump samples first enter one generation/epoch/landing-neighborhood
  pending batch. Compatible samples coalesce for at most `100 ms`; leaving the
  dump gate, reaching the reserved bucket remainder, or the deadline flushes
  one immutable deposit proposal. Pending/queued mass is reserved but bucket
  inventory is debited only after the native edit and material stage commit.
- Product runtime deposit uses a bounded native `VoxelTool.MODE_ADD` path set
  (currently at most two paths) and sparse air-cell coverage. The accepted
  fixed-point mass transfer is exact, while mound shape and per-cell placement
  are explicitly approximate. Exact buffer-copy/SDF deposit remains a named
  diagnostic path only and must not return to the per-frame product path.
- Active or queued dumping suppresses background settle/compaction work.
  Native deposits form their repose-like shape at commit and do not seed a
  continuously draining settle frontier. This intentionally permits stepped
  mound growth and approximate repose in exchange for bounded latency.
- Readiness ownership is canonical per generation and native 16-cubed mesh
  block. Point support performs one block-key lookup and never scans ticket
  history. Compatible native-deposit work in the same probe block may coalesce
  into one enlarged ticket; lower/raise/expected probes or different operation
  purposes must not be collapsed into one query acknowledgement.
- A dirty block keeps its last acknowledged Jolt collider usable while the
  replacement mesh/collider is pending. Successful acknowledgement publishes
  the new block revision; timeout retirement restores that fallback, or removes
  an unconfirmed block with no fallback, rather than leaving permanent pending
  ownership. Collision remains derivative and may lag the visible SDF by the
  bounded engine rebuild interval.
- `SoilEffects` polls complete soil snapshots at no more than `30 Hz`, rebuilds
  the bucket fill surface at no more than `10 Hz` and only across `5%` fill
  quanta, reuses one `ArrayMesh`, and manages hero clods through active/free
  pools. Signals may trigger an immediate pull but reset the polling cadence so
  the same change is not fetched twice in one interval.
- Every mobile-soil operation has two independently checked conservation
  dimensions: fixed-point ledger mass and SDF-represented bulk volume at the
  operation's density/compaction. A zero ledger sum is insufficient if the SDF
  edit exceeds the declared one-cell discretization tolerance.
- The paired remove/add settle transaction remains available for explicit
  diagnostics or a future bounded one-shot operation. Product runtime native
  deposits must not enqueue it continuously. If invoked, it may move only pure
  mobile cells, carries the donor's weighted compaction state, and must never
  modify an SDF sample shared with stable solid material.
- Track compaction consumes generation-bound `voxel_terrain` contact receipts,
  preserves mobile mass, and reduces SDF bulk volume only by the density change
  reported by the staged material state. Receipt collection is independent of
  bucket pose sampling and remains active when automatic bucket interaction is
  disabled.
- Track compaction admission must reject in constant time when the material
  field contains no compactable mobile cells. When mobile soil exists elsewhere,
  each bounded contact footprint must still overlap a compactable cell before a
  proposal may enter the queue. Stable-ground driving must never allocate a
  `VoxelBuffer`, issue edit/readiness tickets, or advance data revision.
- Compaction receipt count, coalesced footprint count, and merged sample window
  are independently bounded. Compaction proposals may coalesce only when their
  voxel areas overlap; vehicle motion must not merge distant track history into
  one large staging window.
- A newer readiness ticket supersedes polling for an overlapping older edit,
  but a partially overlapped ticket must retain its spatial coverage so
  unaffected points remain ready. Superseded polling work and unverifiable
  work past the bounded timeout are retired without advancing collision
  revision.
- Soil work is bounded and fair: a pending/queued interactive deposit owns the
  foreground slot; otherwise queued compaction may proceed. A full queue may
  discard pending compaction for a deposit, but a rejected deposit is not
  entered into the duplicate set and publishes one rejection event.
- Status/transaction diagnostics expose `pending_dump_count`,
  `pending_dump_mass_q`, `pending_dump_age_s`, `dump_batch_flush_count`,
  `dump_batch_coalesced_count`, `native_deposit_committed`,
  `readiness_coalesced`, `support_query_usec`, and `batch_wait_usec`. Visual
  diagnostics expose snapshot pulls, fill rebuilds, cadences, and fill quantum.
- Authority performance diagnostics use fixed 64-sample windows and expose
  average/max/p95/p99 for proposal, commit/operation, coverage, material,
  native edit, digest, readiness issue, and status construction. Mesh-ready,
  collision-ready, and end-to-end lag use the same bounded shape. Allocation
  telemetry is labeled as an object-count proxy and must not be reported as
  allocator bytes.

### 4. Validation & Error Matrix

- stale generation/epoch identity -> `stale_identity`, no mutation
- non-increasing physics tick -> `stale_tick`, no mutation
- non-increasing motion sequence -> `stale_motion_sequence`, no mutation
- stationary/above-ground/separating/teleported sweep -> named rejection, no mutation
- protected/out-of-zone area -> `protected_or_out_of_zone`, no mutation
- full bucket -> `bucket_full`, no SDF deletion
- staging/capsule/sample/native-path budget exceeded -> bounded rejection, no mutation
- native coverage contains no solid/uncredited sample -> `no_sdf_change` or
  `no_accounted_material`, no mutation
- material/SDF mass outside tolerance -> `mass_discretization_tolerance`, no mutation
- deposit outside editable mask/support -> `dump_out_of_zone` or
  `dump_support_unavailable`, no bucket debit and one rejection event
- pending deposit cannot enter the bounded soil queue -> `soil_queue_full`,
  pending inventory remains owned by the bucket and no SDF edit occurs
- pending/queued release already reserves all bucket mass ->
  `dump_mass_already_reserved`, no duplicate debit or extra proposal
- duplicate track generation/epoch/tick -> `duplicate_compaction`, no mutation
- stale generation or sub-threshold/non-voxel track receipt -> named rejection,
  no compaction
- no compactable mobile material or no footprint overlap ->
  `no_loose_track_contact` before queue/SDF staging
- soil SDF/bulk-volume error outside tolerance ->
  `mass_geometry_discretization`, no SDF or ledger mutation

### 5. Good/Base/Bad Cases

- Good: accepted fixed-tick teeth/side-edge sweep plus constrained trailing
  clearance becomes one SDF transaction and equal/opposite terrain/bucket mass.
- Base: several adjacent overlapping 60 Hz inputs coalesce into one ordered
  20 Hz commit with bounded queue depth.
- Bad: searching the whole queue for an older overlapping proposal reorders
  transactions and is forbidden.
- Good: cut -> 100 ms coalesced native dump -> optional track compaction ->
  re-cut uses one SDF writer and returns deposited mobile mass to the same
  bucket with exact ledger conservation.
- Base: continuous release grows the mound in visible 100 ms steps and collider
  readiness may trail the SDF, while control and camera remain responsive.
- Base: automatic bucket sampling is off; generation-valid track receipts still
  reach loose-only compaction while the commit scheduler drains existing work.
- Bad: apply a fixed-radius remove sphere for settle/compaction and update only
  material flags. This can erase geometry while the ledger remains balanced.

### 6. Tests Required

- Pure cutter: both models; slow, fast, translated, curl and rotation-only;
  connected half-voxel coverage; invalid motion; constrained clearance air.
- Authority: real VoxelTerrain SDF digest, exact ledger conservation, capacity
  boundary, stale tick/generation/motion, model reconfigure and no-op rejects.
- Determinism: identical fixed inputs under different render delta partitions
  produce identical transaction digest, mass, revision and queue result.
- Integration: selected owner/payload is voxel; legacy/parcel runtimes absent;
  legacy terrain and parcel step counters remain zero; reset advances generation;
  test capacity provenance and deep initial solid soil remain observable.
- Native ownership: after materialization, query Terrain3D's world-space
  `get_control_hole`/`get_height` APIs at interior, exterior, and half-open
  boundary points. Every voxel-owned sample is a native hole and every exterior
  sample retains finite hard terrain.
- Performance: run one stable representative coalesced edit after implementation
  settles; do not replace human Forward+ feel/visual acceptance with soak tests.
- SY135 native performance: assert native transaction accounting mode/path
  counts, bounded coverage cells, exact ledger balance, repeated-cut coverage
  dedupe, deposit no native rejection after edit, and one real deep-insertion
  commit with overburden cleanup. Human Forward+ owns perceived hitching and
  final cut shape.
- Material cycle: assert pending batches do not debit the bucket, a committed
  native deposit preserves exact aggregate mass, idle frames do not move the
  mound, previously accounted stable cells never lose mass, and re-cut
  decreases mobile mass while increasing bucket mass.
- Scheduling: assert the 100 ms deadline and dump-end flush, same-neighborhood
  coalescing, no active settle frontier, duplicate/stale/weak track rejection,
  and bounded deposit/compaction priority.
- Stable-ground admission: submit many valid voxel track receipts with no mobile
  soil and assert constant-time rejection, zero queued/accepted proposals, and
  unchanged data revision. Readiness tests must retain ready coverage outside a
  partially overlapping edit.
- Presentation: assert accepted/rejected event IDs are consumed once and pooled
  effects remain bounded, fill mesh identity is reused, 5%/10 Hz rebuild gates
  hold, and clods recycle through the pool; human Forward+ owns
  pile/dump/traverse/re-dig visuals and perceived hitching.

### 7. Wrong vs Correct

```gdscript
# Wrong: can merge a later tick ahead of intervening work.
for pending in queue:
	if pending.area.intersects(proposal.area): merge(pending, proposal)

# Correct: preserve fixed-input order by considering only the adjacent tail.
var pending = queue.back()
if pending.fixed_tick_end < proposal.fixed_tick_begin and pending.area.intersects(proposal.area):
	merge(pending, proposal)
else:
	queue.push_back(proposal)
```

```gdscript
# Wrong: the ledger remains balanced but a fixed brush erases arbitrary volume.
apply_remove_sphere(radius)
material_field.commit_compaction(flags_only)

# Correct: stage density change, fit SDF loss to its bulk-volume delta, then
# atomically publish the SDF and material transaction within tolerance.
var staged = material_field.stage_compaction(cells, delta_q)
var fitted = fit_removed_volume(before, full_remove, staged.volume_loss_m3)
commit_if_mass_geometry_matches(fitted, staged)
```

```gdscript
# Wrong: each bucket wall independently erases soil and credits its own mass.
for wall_path in bucket_paths:
	voxel_tool.do_path(wall_path.points, wall_path.radii)
	credit_bucket(wall_path.estimated_mass)

# Correct: leading teeth authorize one immutable proposal; the authority stages
# one deduplicated coverage estimate before applying all native geometry.
var staged = material_field.stage_approximate_cut(coverage_cells, voxel_volume)
if material_field.can_commit_approximate_cut(staged):
	apply_native_paths(proposal.native_paths)
	material_field.commit_approximate_cut(staged)
```

```gdscript
# Wrong: every physics sample copies an SDF buffer, binary-fits a mound, then
# schedules continuous repose settlement and rebuilds presentation resources.
commit_exact_deposit_every_frame(released_mass_q)
enqueue_settle_frontier(all_changed_cells)
fill_mesh.mesh = ArrayMesh.new()

# Correct: reserve/coalesce for 100 ms, stage exact ledger mass, apply one
# bounded native add, then reuse cadence-gated presentation resources.
stage_pending_dump(released_mass_q, landing_neighborhood)
if batch_due_or_dump_ended:
	commit_native_sparse_deposit()
reuse_fill_array_mesh_at_10_hz()
```
