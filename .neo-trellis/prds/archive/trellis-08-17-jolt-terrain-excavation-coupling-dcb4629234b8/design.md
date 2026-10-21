# Design

## Runtime Ownership

```text
track commands -----------------> DynamicChassisRig (Jolt)
                                      ^
                                      | later-tick capped wrench
                                      |
equipment commands -> KinematicArticulationState -> candidate FK
                                      |
                                      v
                              BucketProxySweeper
                                      |
                   +------------------+------------------+
                   v                                     v
          accepted motion fraction              contact classification
                   |                                     |
                   v                          +----------+----------+
          accepted joint/FK state             v                     v
                                      chassis reaction        soil transaction
```

The dynamic chassis and kinematic articulation are separate state domains under
one fixed-tick coordinator. The articulation may request a later chassis wrench;
it never writes chassis transform or velocity directly. Jolt contact may constrain
the accepted bucket trajectory but never writes joint state directly.

## Phase 2 Reuse And Removal

Retain:

- profile gates, authority epochs, neutral re-arm, model-switch rebuild, and
  command identity;
- Phase 1 chassis/track runtime and terrain identity checks;
- model rest-frame/axis validation and visual parity fixtures;
- one immutable snapshot consumed by presentation and truth;
- SY205 visual-only passive four-bar.

Replace:

- five dynamic excavator bodies with one dynamic chassis body;
- four HingeJoint3D motors with `KinematicArticulationState`;
- dynamic bucket payload mass/COM with a logical payload load factor;
- five-body truth assumptions with typed dynamic chassis and kinematic frame data;
- approximate `get_colliding_bodies()` records with explicit bucket sweep/query
  results suitable for motion and soil classification.

## Kinematic Articulation Step

For each joint, keep:

```text
command -> target velocity
        -> optional payload/contact rate scaling
        -> jerk limit
        -> acceleration/braking limit
        -> velocity limit
        -> limit-aware stopping
        -> candidate position
```

The state stores target velocity, actual velocity, acceleration, position, and
quality. The solver computes candidate FK from the same model rest transforms and
declared axes used by visual parity tests. After bucket sweep, a single accepted
motion fraction in `[0,1]` scales the four-joint candidate delta consistently; the
solver then recomputes accepted FK and publishes it once.

Contact must not independently clamp arbitrary joints after FK because that can
break the serial-chain geometry. A future inverse-dynamics/controller program is
outside this phase.

## Bucket Proxy Contract

Each model descriptor binds:

- bucket frame and proxy contract version/hash;
- cutting edge segment and forward/cutting direction;
- opening/cavity volume used for carry/dump classification;
- shell and rear-support convex proxy shapes;
- collision layer/mask and query margin;
- maximum accepted penetration/travel fraction and classification thresholds;
- evidence label for every measured, observed, derived, estimated, or tuned value.

Intermediate upper/boom/arm visual links have no terrain collision shapes.

## Query Spike

Before product refactoring, a standalone Godot 4.7.1/Jolt test must compare the
available swept-shape/query approaches and record:

- previous-to-candidate transform support;
- earliest travel fraction and stable point/normal;
- exact derived terrain collider identity;
- initial-overlap and contact-loss behavior;
- query allocation/reuse and fixed-tick cost;
- reset/model-switch/teardown cleanup;
- whether a query requires a scene body and whether that body can inject impulses.

The selected product path must be query-first. If a kinematic physics body is
required for query support, isolate it from dynamic collision response and never
allow it to push the chassis directly.

## Contact Classification

Classify from accepted proxy identity, point/normal, bucket orientation, relative
motion, terrain identity, and prior contact state:

- `cutting`: teeth/cutting edge moving into eligible stable/loose soil;
- `carry`: material retained by the accepted cavity/opening orientation;
- `spill`: loaded cavity loses retention while moving/tilting;
- `dump`: deliberate opening/orientation releases material to terrain;
- `support`: shell/rear proxy presses against terrain at an eligible adverse angle;
- `blocked`: collision limits motion but is not eligible for soil or support.

One contact identity may produce at most one accepted classification result per
physics tick. Cutting and support are mutually exclusive for one proxy record.
All records for one bucket motion key are ordered by travel fraction, proxy role,
and stable contact ID, then reduced once. The minimum admissible travel fraction
owns motion clamping. Invalid/stale/initial-overlap safety records make the batch
ineligible. Valid shell/rear records reduce independently into zero or one support
request. Valid soil records reduce into zero or one operation using the documented
precedence `dump -> spill -> cutting -> carry`; cutting consumes only cutting-edge
records. This allows a valid support request and soil transaction to coexist while
preventing one proxy record from changing semantic role.

The batch idempotency key is `(authority_epoch, physics_tick, terrain_generation,
terrain_revision, bucket_motion_sequence)`. It stores every consumed contact ID,
emits exactly one soil transaction when an eligible soil operation remains after
reduction, and emits none otherwise. Replaying a consumed key is a no-op with an
explicit duplicate diagnostic.

## Chassis Reaction

Support classification emits a request, not a transform:

```text
{
  authority_epoch,
  source_physics_tick,
  eligible_apply_tick,
  expiry_tick,
  model_id,
  terrain_generation,
  terrain_revision,
  point_world,
  normal_world,
  penetration_or_blocked_distance,
  relative_speed,
  requested_force,
  requested_torque
}
```

The chassis adapter accepts `eligible_apply_tick = source_physics_tick + 1` and an
explicit short `expiry_tick`. On the eligible step it validates unchanged authority,
model, terrain generation/revision, and request identity, clamps force, torque,
application point, rate of change, duration, and total heave/pitch/roll response,
then applies one wrench. Early, late, stale, duplicate, or mismatched requests are
discarded. Contact loss decays future requests; it never restores chassis pose by
direct transform writes.

This is a perceptual gameplay response based on real collision evidence, not a
claim of articulated rigid-body force transmission.

## Contact To Soil Flow

```text
accepted bucket sweep/contact at physics tick
  -> immutable classified contacts (model + terrain identity)
  -> one idempotent SoilInteractionBatch per bucket motion key
  -> zero or one TerrainCommitScheduler/BucketSoilState transaction
  -> payload fill/mass/COM/load-factor snapshot
  -> next-tick kinematic tuning
  -> copied renderer/Terrain3D/collider/effect updates
```

Contact geometry supplies evidence. The soil classifier owns semantic decisions
and volume. Neither query penetration nor Terrain3D height edits directly mutate
logical terrain.

## Collider Transaction

Prepare a new static collider from a copied accepted terrain snapshot. Switch the
applied revision only at a controlled tick boundary, invalidate old query/contact
identity, bound any transition recovery, and include the applied revision in every
result. Edits produced this tick become eligible for a later collider revision,
preventing recursive same-tick self-feedback.

## Payload And Effects

BucketSoilState produces volume, mass, local COM, fill, and transaction identity.
The kinematic load adapter converts accepted payload into bounded per-joint
velocity/acceleration/braking multipliers at the next fixed tick. It does not mutate
a dynamic bucket body. Hero clods and particles consume events but cannot feed
terrain, payload, contact, or chassis authority.

## Hybrid Snapshot

Capture once after the accepted fixed step:

- authority/model/proxy/terrain/command identity;
- dynamic chassis transform and velocities;
- four kinematic joint target/position/velocity/acceleration values;
- accepted FK frame transforms;
- bucket candidate and accepted transforms/motion fraction;
- classified contact summaries;
- queued wrench source/eligible/expiry identity and applied wrench tick/result;
- track state and payload/load factor;
- quality flags and fixed-step/query timing.

Presentation and truth consume this snapshot. Neither may sample live query/body
nodes independently.

## Failure And Rollback

- Invalid articulation/proxy descriptor: fail closed before replacing the accepted
  runtime; no cross-model fallback.
- Missing/stale collider: reject support and soil edits, clear queued wrench, and
  use bounded no-contact kinematic behavior with explicit quality.
- Query initial overlap: limit recovery and disarm soil edits until separation or
  reset; never inject an unbounded chassis force.
- Reset/model/profile switch: clear candidate motion, contacts, queued wrench,
  payload adapter state, and derived effects under a new authority epoch.
- Rollback: rebuild `python_kinematic`; do not mix hybrid, five-body prototype, or
  legacy transform lift state.
