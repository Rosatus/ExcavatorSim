# Implementation Plan

## Phase A: Contract And Local Query Spike

- [x] Verify the archived Phase 1 task is completed and record its dynamic
      chassis/track exit evidence; verify the archived Phase 2 task is completed
      and record the exact prototype seams retained versus superseded.
- [x] Freeze the hybrid ownership table, fixed-tick order, typed hybrid snapshot,
      rollback boundary, and removal list for the Phase 2 five-body assumptions.
- [x] Run a disposable Godot 4.7.1/Jolt spike for previous-to-candidate bucket
      convex sweep/query behavior, earliest travel fraction, point/normal,
      initial overlap, terrain collider identity, performance, and teardown.
- [x] Choose and document a query-first bucket proxy mechanism that cannot inject
      uncapped kinematic impulses into the chassis.
- [x] Refine SY205/SY135 cutting/opening/shell/rear proxy contracts with asset
      evidence and controlled Godot visualization.

## Phase B: Kinematic Work-Equipment Runtime

- [x] Extract/reuse the Phase 2 command identity, neutral re-arm, joint limits,
      fixed-step velocity/acceleration/jerk shaping, and model lifecycle seams in
      one `KinematicArticulationState` owner.
- [x] Produce candidate and accepted four-joint/FK snapshots for both models,
      retaining visual parity and the SY205 visual-only passive linkage.
- [x] Replace dynamic upper/boom/arm/bucket bodies and HingeJoint3D motors in the
      product path while retaining the accepted dynamic chassis/track runtime.
- [x] Replace dynamic bucket payload mass/COM mutation with bounded next-tick
      motion-load multipliers derived from BucketSoilState identity.

## Phase C: Bucket Motion And Contact Bridge

- [x] Sweep all bucket proxies from previous to candidate FK against the exact
      applied terrain collider revision.
- [x] Compute one accepted motion fraction, recompute accepted joint/FK state, and
      publish one immutable contact summary per proxy/tick identity.
- [x] Implement mutually exclusive per-contact cutting, carry, spill, dump,
      support, and blocked classifications using proxy, orientation, relative
      motion, normal, and terrain identity.
- [x] Deterministically reduce all records for one bucket motion key into one
      idempotent SoilInteractionBatch, zero or one soil transaction, and zero or
      one aggregated support request; record consumed contact IDs.
- [x] Handle initial overlap, tunneling risk, contact persistence/loss, stale
      collider identity, and out-of-bounds motion with bounded fail-closed behavior.

## Phase D: Chassis Reaction And Soil Transaction

- [x] Convert accepted shell/rear support evidence into one later-tick chassis
      wrench request with source/eligible/expiry tick identity,
      force/torque/rate/duration caps, duplicate rejection, and stale rejection.
- [x] Disable the legacy transform-offset lift in the hybrid authoritative profile
      and assert that no other node writes the chassis transform.
- [x] Route eligible cut/carry/spill/dump classifications into exactly one
      TerrainCommitScheduler/BucketSoilState transaction.
- [x] Make terrain collider prepare/switch/invalidate transactional so same-tick
      terrain edits cannot feed their own query or chassis response.
- [x] Keep visual clods, particles, Terrain3D maps, and payload presentation as
      consumers of committed events only.

## Phase E: Hybrid Presentation And Truth

- [x] Update MotionPresentation to consume dynamic chassis plus accepted kinematic
      joint/FK frames from the same hybrid snapshot.
- [x] Update authoritative truth/schema fixtures to distinguish dynamic body state,
      kinematic joints/frames, bucket queries, motion fraction, queued/applied
      chassis wrench, payload load factor, and quality.
- [x] Remove five-body/four-physical-joint count assumptions and the
      `jolt_articulated_authority` claim from the product path without weakening
      Python-shadow isolation.
- [x] Preserve model/profile/reset/disconnect lifecycle, no hot fallback, and zero
      residual runtime/query nodes.

## Phase F: Verification And Documentation

- [x] Test both models in every joint direction for start/accel/brake/reverse/hold,
      limits, payload slowdown, mixed axes, long-run finite state, and reset/re-arm.
- [x] Test cutting versus support classification, candidate motion clamping,
      chassis lift/tilt caps, no infinite-mass push, contact loss, stale collider,
      duplicate tick, model switch, and world reset.
- [x] Test automatic dig/carry/spill/dump without production buttons and conserved
      stable/loose/bucket volume across long scripted cycles.
- [x] Test one-writer invariants and one snapshot shared by presentation, truth,
      contact, payload, and sensor seams.
- [x] Run `pixi run verify`, backend smoke, the Godot standalone matrix, task
      validation, and Godot MCP live SY205/SY135 cutting/support scenarios.
- [x] Record fixed-step/query/collider costs and update architecture, client,
      terrain, bucket, runtime-profile, truth, and test documentation.

## Rollback Point

Keep `python_kinematic` as the product-safe profile until Phase F passes. The
archived five-body implementation is an evidence baseline, not an automatic
runtime fallback. Mode selection must never combine the hybrid articulation,
five-body prototype, or legacy transform-offset lift.
