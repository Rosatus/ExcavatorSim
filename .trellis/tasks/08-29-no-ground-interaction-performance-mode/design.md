# Design — bucket pass-through performance mode

## 1. Target architecture

```text
Operator UI toggle
  -> ProductSession requested mode
  -> fixed-tick transition coordinator (priority before chassis/Jolt/soil)
       |-> TrackedChassisController / Jolt runtime bucket-query policy
       |-> ExcavationWorld soil-execution policy + clean material boundary
       `-> SoilEffects execution policy

normal:
  equipment FK -> bucket sweep/cut probe -> accepted fraction/support wrench
               -> soil classification/authority -> terrain commit/collider/effects

bucket_passthrough:
  equipment FK ---------------------------------> accepted fraction 1.0
  track probes -> TerrainCollider/TerrainState -> chassis support/traction (unchanged)
  terrain presentation ----------------------------------------------> visible
```

`ProductSession` is the product-facing source of requested/active mode and owns
transition timing. It must not reimplement soil or Jolt rules. The controller
and `ExcavationWorld` remain the respective execution owners.

## 2. Mode contract

Use one shared two-value contract (`normal`, `bucket_passthrough`) and reject
unknown values. Keep it in a small project-owned policy/constant owner rather
than duplicating strings across UI, session, excavation, controller, and tests.

`ProductSession.request_bucket_ground_mode(mode)` queues a request. At the start
of its next physics tick (priority -30, before the controller/Jolt/soil order),
it applies the transition as one preflighted boundary:

1. Preflight the shared value and required, initialized adapters without
   mutating any state. A failed preflight keeps the prior mode and payload.
2. Disable bucket-ground execution in `TrackedChassisController`; this clears
   legacy lift state and propagates to the current Jolt runtime.
3. Apply the execution policy in `ExcavationWorld`. Entry runs the destructive
   clean-material boundary. Exit establishes another empty material generation
   only to reject stale pose/support/brush work; it cannot discard new material
   because no material work is permitted while bypassed.
4. Commit the `ProductSession.active_mode` and transition sequence.

After preflight, adapter setters must be deterministic/no-fail state changes.
Do not pretend that cleared material can be rolled back. An unexpected internal
failure after clearing fails closed to `normal`, reports that material was
cleared, and requires a clean retry; it may not restore stale payload or work.

Mode selection is not serialized. Reset/model/reconnect may rebuild generation
or runtime objects, but each rebuild re-applies the current policy before work
resumes. Test Grid and Terrain3D backend transitions are presentation-only and
cannot change it.

## 3. Jolt and chassis behavior

Add a stored bucket-ground policy to `TrackedChassisController` and propagate it
to every newly configured `JoltChassisTrackRuntime`.

When bypassed, Jolt still computes command shaping and accepted articulation FK,
but it does not call `BucketProxySweeper.sweep()` or
`probe_cut_penetration()`. It publishes a stable synthetic query diagnostic with
`accepted_fraction = 1.0`, no contacts, and reason
`bucket_ground_interaction_bypassed`; it clears queued/applied support wrenches,
cut engagement, and response accumulators. `_collect_bucket_query_contacts()`
must not manufacture contacts from a stale prior result.

The existing `_apply_track_forces()`, terrain identity update, terrain collider,
heightfield fallback, hull collision mask, track support, traction, differential
yaw, and attitude stabilization remain untouched.

For compatibility profiles, `TrackedChassisController` ignores submitted bucket
support contacts and clears `BucketGroundLiftReaction` while bypassed. Disabling
the mode restores the configured `ground_lift_enabled` behavior.

## 4. Soil execution and transition cleanup

`ExcavationWorld` owns a distinct interaction policy; do not overload
`automatic_soil_enabled` or `soil_material_lifecycle_mode`.

At a mode boundary, extend/reuse `_clear_local_material(reason)` so it:

- resets the scheduler for the current world generation, dropping queued
  brushes without resetting persistent terrain;
- clears legacy bucket/transfer state, active authority ledger, active patch,
  presenter representatives, parcels, selected payload feedback, pose history,
  support/interaction batches, consumed keys, and flow state;
- increments material generation and begins the same selected soil-owner mode
  on a clean ledger;
- explicitly pushes zero payload to the chassis using the new identity;
- records a bounded transition diagnostic and cumulative cleared-transition
  count, not a conservation transaction.

At the top of `_physics_process`, pass-through updates lightweight status and
bypass counters, then returns before automatic sampling/classification,
authority/patch/parcel stepping, scheduler flush, feedback generation, or
interaction-derived effects. Manual/test cut and deposit queues reject with the
same mode reason.

`SoilEffects` gets an execution gate independent from visual-quality emission.
While bypassed it clears transient emitters/fill/clods once and returns before
per-frame snapshot, flow, or clod processing. Restoring the mode reapplies the
current quality budget; Test Grid can still independently suppress emission.

## 5. Diagnostics and instrumentation

Status snapshots use typed dictionaries already owned by each subsystem and are
composed upward; no backend wire schema changes are needed.

Expose at minimum:

- session: requested/active mode, pending flag, transition sequence and error;
- Jolt/controller: query submitted/executed/bypassed, support queued/applied/
  bypassed, cut-probe executed/bypassed;
- excavation: automatic samples/classifications, authority steps, patch steps,
  terrain commit attempts, parcel steps, and bypass ticks;
- effects: update executed/bypassed and last clear reason;
- transition: material generation before/after, cleared payload volume, cleared
  representative/parcel counts, persistent terrain identity before/after.

Counters are monotonic for the process and may be reset only by explicit
test-only helpers. Do not emit per-tick logs. Log one bounded record for each
mode transition or rejected transition.

The main Tools row gets a toggle and concise tooltip. Advanced diagnostics show
the active mode and a compact counter summary. A transition that clears payload
shows a short status message; no confirmation modal is required.

## 6. Validation design

Deterministic standalone tests drive both model buckets through the terrain for
fixed tick counts. They compare pre/post `TerrainState` bytes/digest/revision,
material snapshots, Jolt accepted fraction/support/cut response, and subsystem
counters. A second phase re-enables normal mode and proves ordinary interaction
returns without stale work.

Extend the existing warmed product soak harness with a mode dimension and a
mode-specific scenario predicate. Normal retains cut/payload/dump/support gates;
pass-through requires surface crossing, zero soil mutation/support response,
valid track contact, and advancing bypass counters. Run three paired traces per
model at balanced quality, alternating order, and compare median fixed-step p95
while retaining existing absolute ceilings.

The comparison artifact records commit and machine identity, model, quality,
mode order, trace identity, warm-up/sample duration, all three raw p95 values,
their median, existing ceiling results, and targeted work-counter deltas.

Source and isolated exported smoke runs must agree on default mode, transition,
terrain immutability, and restoration. The implementation is GDScript and
platform-neutral; Windows exported runtime is the required release proof and
Linux export/source checks run where the existing environment supports them.

## 7. Compatibility, failure, and rollback

- Existing ordinary mode is the default and is the rollback path.
- A failed preflight leaves the previous active mode and payload in force. An
  unexpected post-clear failure fails closed to `normal` with empty material and
  an explicit diagnostic; partial activation and fabricated payload restoration
  are not accepted.
- Terrain rendering/collider availability continues to fail open according to
  its existing contract and is not coupled to the new policy.
- Rebuilding the Jolt runtime, model, or soil generation must copy the active
  policy before accepting new work.
- No persisted-data or protocol migration is required.
