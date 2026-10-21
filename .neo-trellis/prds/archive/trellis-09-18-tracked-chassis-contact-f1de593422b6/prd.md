# Stable tracked chassis contact

## Goal and authorization
User reported violent jitter/penetration on slopes, pit edges and obstacles,
approved the assessment plan on 2026-09-18, including rebuilding the underlying
track motion/collision. Preserve Jolt as the single dynamic chassis authority,
input/lifecycle interfaces, equipment and soil boundaries. SY135 is primary;
other models receive focused shared-code compatibility checks.

## Acceptance
- Permanent physical obstacle protection; no driving through a wall.
- Distributed track support handles steps, slopes, crests and partial contact
  without hull-mask cycling, artificial teleport recovery or unbounded forces.
- Flat idle/drive stability remains within 0.01 m/s heave RMS, 0.02 rad/s
  pitch/roll rate RMS and 0.01 m height span after settling.
- Full-motion obstacle checks cover transient penetration, contact transitions,
  force/velocity guard activation and settling, not only endpoints.
- Voxel collision apron is usable only when its own block is ready; editable
  soil bounds stay unchanged. Real seam queries must validate accepted support.
- Track truth/sensor field types, model axis conventions, focus/reset lifecycle
  and bounded equipment support coupling remain valid.
- Human manual: SY135 driving over slope/pit edge/obstacles, both turn
  directions and bucket-supported landing feel; pending user review.

## Milestones
1. M0: retain failing wall/step evidence; build reproducible contact regression.
2. M1: prototype continuous obstacle hull and revised finite-area support/drive;
   compare identical scenarios before selecting the production core.
3. M2: readiness/apron, partial support and equipment/lifecycle integration.
4. M3: focused cumulative regression, remove obsolete core patches, update
   contracts and hand off human review. No commit/push requested this turn.

## Baseline
130bba7. `output/track-locomotion-assessment.md` contains the preceding assessment.
Old `jolt_chassis_track_test.gd` passes, but the isolated SY135 wall trial drives
through z=-3m to z=-7.5076m with collision_mask=0. Keeping the old hull enabled
stops at z=-0.725m; on a 0.3m one-sided step it blocks and increases peak vertical
speed to 0.4195m/s. This rules out a mask-only fix as the complete solution.

## Progress
First implementation delivered for manual trial. User subsequently directed:
focus on implementation, do not spend effort on tests; user owns driving tests.
This overrides the planned automated matrix. The initial regression scaffold is
retained but was only run against the old core, which failed as expected.

Implemented: extracted TrackContactSolver, permanent rounded track/belly hull,
finite-area sweeps, unfiltered load response, shared friction budget and dt-scaled
effort; removed old hull switching, normal servo, yaw assist and telemetry velocity
write. Fixed apron bounds + initial block readiness; semantic edit bounds unchanged.

Agent automated: Godot editor import and --check-only on all three changed runtime
scripts passed. Editor reports existing duplicate terrain texture UIDs and SY135
NEO scene UID fallback. No new-core driving test, full suite, export or visual pass.
Human manual: pending; restart main scene, SY135, drive into an obstacle, across
single-sided steps/pit lips, turn both ways, then release travel and inspect settle.
No commits/pushes. Next: user trial feedback; refine contact geometry/load behavior
from the specific failing situation rather than adding generic damping.


### User trial follow-up
User reports penetration resolved and overall improvement; slopes catch more often
and small remaining contact patches struggle to recover. Continued implementation:
- Held directional input now develops bounded drive through rollback instead of
  repeatedly entering the neutral no-cross brake regime.
- Real Jolt track-hull normal impulses contribute traction capacity and load
  telemetry, attributed once by track shape and collider/normal. They are not
  reapplied as suspension force. Belly, upper hull and walls cannot grant grip.
- Initial sweep overlaps are queried explicitly so touching a steep lip does not
  silently lose the only supporting station.
- Rounded track end radius follows track height, rather than being limited by
  belt width; obstacle collision stays enabled.
Only parser checks per the user's testing preference; effectiveness of these
follow-up changes awaits user trial. Existing main.tscn modifications are preserved.
