# Automatic Soil Interaction Design

## Authority And Representation

| Layer | Responsibility | Authority boundary |
|---|---|---|
| `TerrainState` stable/loose field | Persistent coarse scars and piles | Global shape only; low-frequency commits |
| Transfer ledger and active episode | Identity and ownership of released material | Prevents duplication and stale resurrection |
| Bucket cellular occupancy | Retained volume, mass, center of mass, spill eligibility | Runtime payload source |
| Fill mesh and GPU grains | Continuous visible material | Derived, stochastic, quality-scalable |
| Pooled Jolt clods | Hero impacts, rolling chunks, sound contacts | Non-authoritative and hard capped |

Python/Pinocchio remains articulation authority. Godot composes articulation with
the tracked chassis, samples bucket geometry, owns terrain/material interaction, and
may publish a latest-value aggregate observation. Terrain3D renders committed coarse
terrain; it is not the granular solver.

## Bucket Contract And Pose Snapshot

Each model catalog entry references a validated soil contract containing cutting and
top edges, tooth direction, cavity proxy, opening plane, side/rear boundaries,
support proxy, nominal/heaped capacity, density presets, and visual attachment paths.
Contract rejection is model-specific with no cross-model visual fallback.

A `BucketPoseSnapshot` is produced once per fixed physics step after the latest
accepted Python articulation pose and current chassis transform are composed. It
contains previous/current world transforms for all interaction proxies, linear and
angular deltas, model/session/world/generation identity, and validity flags. The
soil system consumes one immutable snapshot per step. Teleports, identity changes,
missing frames, or excessive deltas reset sweep history and cannot cut soil.

This ordering removes `_process`/`_physics_process` ambiguity and gives the later
support/lift task one stable raw support proxy that does not depend on particles.

## Transfer Lifecycle And Identity

Material follows one directional ledger:

1. A swept cut reserves a bounded coarse terrain kernel and creates an active
   episode with unique episode and generation IDs.
2. The episode transfers material into bucket cells or an escaping-flow accumulator.
3. Occupancy leaving the opening transfers to escaping flow; it is removed from the
   bucket aggregate in the same fixed step.
4. Landing flow transfers into a settled accumulator and retires its visual token.
5. A terrain commit merges settled/scar deltas into `TerrainState`, then retires the
   committed ledger entries.

The ledger permits bounded smoothing loss, compaction, and LOD reconciliation but
never simultaneous ownership. Each generation has hard caps and deterministic
cleanup even though cell motion and particles are intentionally stochastic.

## Continuous Interaction Pipeline

1. Consume the fixed-step pose snapshot and query the coarse terrain surface.
2. Classify cut, push, intake, carry, spill, dump, rear support, or no-op from swept
   proxies, relative motion, local gravity, opening exposure, and optional Jolt
   contact hints.
3. Create/update a bounded active episode and enqueue its scar delta.
4. Route released material through the bucket grid. Occupancy updates aggregate
   payload and fill mesh; escaping transfers drive continuous GPU emitters and a
   small optional pool of Jolt clods.
5. Convert landed material into pile deltas and enqueue them for the terrain commit
   scheduler.
6. Retire completed episodes and publish the newest local payload aggregate.

Nominal/heaped capacity calibrates grid dimensions, fill visualization, expected
mass, and abnormal-state clamps. It does not grant a fixed payload. The initial grid
is hundreds to low thousands of active cells, sufficient for bucket-local settling,
heaping, leakage, and dumping without becoming a global solver.

## Terrain Commit Scheduler

`TerrainCommitScheduler` is the sole owner of normal runtime soil mutations and
flushes of:

- applying queued scar and pile kernels to `TerrainState`;
- taking the resulting terrain snapshot;
- requesting Terrain3D mesh updates; and
- rebuilding collision once per completed flush.

Producers submit immutable deltas only. The scheduler coalesces them and flushes on
profiled cadence, accumulated-volume/area threshold, or maximum-latency deadline.
Reset/model/world generation changes discard uncommitted entries; a normal feature
shutdown may force one final valid-generation flush before cleanup. The initial
scene bootstrap may build the first presentation snapshot before a scheduler
exists, but it must not apply soil deltas. Tests assert that no normal production
soil path calls terrain mutation or rebuild APIs directly outside the scheduler.

## Visual System And Quality Tiers

The fill surface is a smoothed mesh over bucket occupancy, not a rising plane. GPU
emitters persist for cutting, intake, retained grains, side spill, dump flow,
impacts, and dust; their rates, direction, and inherited velocity come from transfer
events. Particles may use visual heightfield/SDF/box collision but never define
payload or push the excavator.

Jolt clods use pooled low-poly convex shapes, isolated collision masks, and sleep,
lifetime, distance, and generation reclamation. Turning clods off must not change
the bucket aggregate or make material flow unreadable.

Initial profiling targets, to be calibrated before acceptance:

- balanced: approximately 1,000-2,000 active GPU grains and 24-48 awake clods;
- high: approximately 3,000-5,000 active GPU grains and no more than 64 awake clods;
- bucket fill mesh below approximately 500 visible triangles;
- coarse terrain commits normally limited to 10-15 Hz;
- soil presentation around 1 ms CPU and 2 ms GPU on the target quality tier.

These are profiling gates, not permanent product guarantees. LOD removes hero clods
first, then reduces grain count and update cadence while preserving occupancy/fill.

## Optional Feedback Compatibility

Feedback is implemented only after the Godot visual gate and defaults off. Existing
required WebSocket capabilities remain exactly `input_snapshot` and `commands`.
`bucket_load_feedback_v1` is optional and absence is normal.

Compatibility uses a guarded two-stage negotiation:

1. A new client performs an HTTP capability preflight. A missing endpoint, 404,
   malformed response, or absent feature means legacy mode and an unchanged hello.
2. Only after the preflight advertises `bucket_load_feedback_v1` does the client add
   `optional_capabilities` to hello. The new backend conditionally returns
   `negotiated_optional_capabilities` only when the client sent that field.
3. Required-capability validation remains unchanged. Optional values are normalized
   separately and never enter the loop that faults on missing required capabilities.
4. An old client sends the old hello and receives the old-shaped acknowledgement;
   a new client talking to an old backend also sends the old hello after preflight
   fallback. Both combinations therefore remain valid.

Once ready and negotiated, Godot may send `bucket_load_feedback` with protocol,
session, simulation epoch, model ID/version, world/generation ID, monotonic client
sequence, mass, center of mass, normalized fill, bounded resistance, and quality.
Python accepts only finite, in-range, current-identity, increasing samples and keeps
one latest-value mirror with a monotonic timeout. Disconnect, reconnect, model
switch, reset, rejection, or disablement clears sender and mirror state. Feedback
does not affect the local simulation and is not recorded as terrain/grain replay.

## Production Rollout And Rollback

Automatic soil begins behind a feature flag. Manual queue methods remain callable
by standalone tests and an explicit debug build flag, but production UI nodes and
F9/F10 bindings are removed. Rollback disables dynamic soil and activates the
existing aggregate diagnostic path without exposing manual controls to production.

The visual gate runs scripted cut, carry, spill, dump, reset, reconnect, and model
switch scenarios for SY205 and SY135. It records state transitions, active-object
caps, orphan lifetime, terrain-commit cadence/latency, and 30-second balanced/high
profiler captures. Backend feedback work begins only after this gate passes.

## PBD Escalation Gate

Only plan a native/GPU PBD prototype if the cellular solver plus fill mesh and GPU
flow still fails specifically on visible intake, settling, or spill. The prototype
must be bucket-local, asynchronously expose aggregates only, preserve the non-PBD
fallback, and pass a separate budget and dependency review before adoption.
