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
- `TerrainState.sample_surface_bilinear_at()` is the support-height authority.
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
| Jolt collider disabled/unavailable | Continue from bilinear heightfield |
| Collider identity is stale | Ignore raycast and continue from heightfield |
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

- Real Godot 4.7.1/Jolt tests cover both models settling, straight travel,
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

`Terrain3DAdapter` is an optional presentation/collision backend, not a second
authority. Its public seam is:

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
- The local window is 3/4/5 metres for low/balanced/high. Each profile fixes
  representative, substep, neighbor, settlement, memory, and tick-time budgets.
  Quality changes may merge representatives but must preserve aggregate volume.
- `loose`, `compact`, `sand`, and `damp` are game-feel presets with distinct
  friction, cohesion, damping, sleep, compaction, and repose values. They are
  not calibrated geotechnical material claims.
- Representatives use gravity, the shadow terrain floor, full-bucket semantic
  proxy contact, spatially bounded neighbor displacement, inner-shell
  containment, and opening-oriented release. Sleeping or window-evicted volume
  settles through `ActiveSoilPersistentField.settle_volume()` and its scheduler.
- `ActiveSoilPatchPresenter` is a disposable `MultiMeshInstance3D` derivative.
  Its instance count, transforms, visibility, or loss never changes volume.
- Model switch, pose clear, authority/world generation change, reset, disable,
  or material reconfiguration drops the old shadow generation and its visual
  derivative. Default-off product snapshots remain byte-identical.

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
  patch: ActiveSoilPatch, focus_world: Vector3) -> Dictionary
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
- Disable, reset, model switch, authority generation change, or material change
  clears the patch and ledger together. Mid-scoop primary authority migration is
  forbidden in this contract.

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
| Reset/model/authority boundary | Clear payload, reps, parcels, transactions, response, then create one new selection |
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
- `visual_pass_test.gd` asserts fallback shader identity, Test Grid material
  retention/restore, unchanged Sky3D/shared cues/effects/camera/UI budgets, and
  native demo dressing exclusions across quality profiles.
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
