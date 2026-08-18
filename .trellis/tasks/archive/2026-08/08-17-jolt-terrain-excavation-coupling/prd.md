# Hybrid Work Equipment And Excavation Coupling

## Goal

Replace the complete articulated Jolt product path with a maintainable hybrid:
one dynamic Jolt chassis, four bounded kinematic work-equipment joints, bucket-only
collision queries, capped chassis support reaction, and one conserved logical
soil/payload transaction.

## Dependencies And Migration Baseline

- Requires the accepted Phase 1 dynamic chassis/track authority recorded at
  `.trellis/tasks/archive/2026-08/08-17-jolt-chassis-track-authority`.
- Uses archived Phase 2 at
  `.trellis/tasks/archive/2026-08/08-17-jolt-articulated-equipment` as evidence for
  model-frame parity, command/lifecycle handling, post-step snapshot sharing, and
  rollback comparison.
- Phase 2's dynamic upper/boom/arm/bucket bodies, HingeJoint3D motors, bucket mass
  mutation, and five-body truth count are explicitly superseded, not dependencies
  to preserve.

## Requirements

### R1. Kinematic Articulation Authority

- Add one fixed-step state owner for swing, boom, arm, and bucket position,
  velocity, acceleration, target, and command identity.
- Apply model-specific joint limits, maximum velocity, acceleration, braking,
  optional jerk, and load-response tuning.
- Require neutral re-arm after reset, model/profile change, or invalid input.
- Compute accepted FK from validated rest frames and axes; visual presentation,
  bucket proxies, truth, and sensors consume the same immutable snapshot.

### R2. Simplified Dynamic Boundary

- Retain only the chassis as an excavator dynamic rigid body in the product path.
- Remove/disable dynamic upper, boom, arm, and bucket bodies and their physics
  joints without changing the accepted Phase 1 track/chassis behavior.
- Do not create terrain collision for intermediate work-equipment links.
- Do not apply BucketSoilState mass/COM to a dynamic bucket body. Payload instead
  produces a bounded motion-load factor for velocity, acceleration, and braking.

### R3. Bucket-Only Collision Queries

- Add model-specific cutting-edge, opening/cavity, shell, and rear-support convex
  proxies aligned to validated bucket frames for SY205 and SY135.
- Sweep previous-to-candidate proxy transforms against the current applied terrain
  collider before accepting the kinematic joint step.
- Verify the exact Godot 4.7.1/Jolt query/body API in a disposable local spike.
- Every result carries authority epoch, physics tick, model/proxy version, terrain
  generation/revision, contact point, normal, travel fraction, and quality.
- Never use a forced kinematic bucket as an uncontrolled infinite-mass pusher.

### R4. Motion Resistance And Support Reaction

- Teeth/cutting contact may scale or clamp the candidate joint step and feed the
  soil classifier; it must not be misclassified as rear support.
- Shell/rear-support contact may scale motion and queue one bounded equivalent
  chassis force/torque for a later physics step.
- Bound force, torque, penetration recovery, rate of change, duration, and
  contact-loss decay.
- Disable the legacy transform-offset `BucketGroundLiftReaction` in the hybrid
  authoritative profile. No second chassis writer or feedback path is allowed.

### R5. One Logical Excavation Transaction

- Aggregate all eligible accepted proxy evidence for one bucket motion tick into
  one ordered interaction batch. An eligible batch emits exactly one transaction
  that owns cut, carry, spill, and dump decisions; an ineligible batch emits none.
- Key the batch and transaction by `(authority_epoch, physics_tick,
  terrain_generation, terrain_revision, bucket_motion_sequence)` and reject a
  duplicate key without consuming volume twice.
- Resolve multi-proxy evidence with one documented deterministic precedence and
  retain the consumed evidence IDs for diagnostics.
- Commit terrain and payload only through TerrainState, BucketSoilState, and the
  established commit scheduler.
- Preserve stable/loose layers, capacity, density, fill, COM, and volume
  conservation semantics.
- Visual clods, particles, Terrain3D maps, and collision proxies remain disposable
  derivatives and never become volume authority.

### R6. Transactional Terrain Collider

- Prepare collider updates from copied accepted terrain snapshots.
- Switch applied revision only at a controlled tick boundary and invalidate old
  query/contact identity.
- Edits from one tick become eligible only for a later collider revision, avoiding
  contact -> edit -> collider -> contact recursion in the same tick.
- Stale, unavailable, or failed collision data fails closed for support/soil edits
  while keeping bounded kinematic motion and product lifecycle operable.

### R7. Hybrid Truth And Presentation

- Publish dynamic chassis state separately from kinematic joint/frame state.
- Report bucket candidate/accepted motion, contact classification, applied motion
  fraction, queued/applied chassis wrench, payload/load factor, and quality.
- `MotionPresentation` consumes accepted FK and retains SY205's passive four-bar as
  visual-only.
- Do not relabel kinematic frames as Jolt rigid bodies to preserve the Phase 2
  five-body schema shape.

## Acceptance Criteria

- [ ] SY205 and SY135 run with one dynamic chassis body and no dynamic
      upper/boom/arm/bucket bodies or physics work-equipment joints.
- [ ] Four-axis work-equipment motion starts, accelerates, brakes, reverses, holds,
      and stops at limits smoothly under fixed-step position/velocity/acceleration
      and optional jerk bounds.
- [ ] Payload changes motion-load response and visual/numeric fill consistently
      without mutating dynamic bucket mass properties.
- [ ] Bucket proxy sweep prevents uncontrolled terrain penetration and never
      pushes the chassis as an uncapped infinite-mass body.
- [ ] Rear/shell support at adverse angles queues bounded force/torque that can
      lift/tilt the actual dynamic chassis; teeth-first cutting does not trigger
      the support class.
- [ ] Dig/carry/spill/dump emerge from bucket motion/contact without production
      Dig/Deposit buttons and conserve logical volume within documented tolerance.
- [ ] Each accepted bucket contact produces at most one classification and
      resistance decision; all eligible contacts for one bucket motion key
      deterministically produce zero or one idempotent soil transaction and zero
      or one aggregated chassis-wrench request.
- [ ] Stale/unavailable collider, revision replacement, reset, model switch,
      command loss, and contact loss have bounded tested behavior with no duplicate
      edits or residual bodies/queries.
- [ ] Presentation and truth consume one hybrid snapshot and distinguish dynamic
      chassis data from kinematic articulation data.
- [ ] Both models pass scripted excavation/support cycles and Godot MCP review from
      several cutting and support angles.

## Out Of Scope

- Dynamic rigid-body upper/boom/arm/bucket chains and physics joint motors.
- Hydraulic pressure/flow, exact cutting-force science, physical link momentum
  reaction, and engineering-grade tipping prediction.
- Terrain collision for boom/arm visuals, per-grain authoritative soil,
  fracture/rock breaking, Terrain3D editor mutation, or physical debris as volume
  authority.

## Rollback

Until this phase passes, `python_kinematic` remains the product-safe profile and the
archived Phase 2 implementation remains a comparison baseline only. A rollback
requires a new authority epoch and full runtime rebuild; it must not combine the
hybrid articulation, five-body prototype, or legacy transform lift in one session.
