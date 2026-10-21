# Automatic soil interaction

## Goal

Make excavation happen from bucket motion alone: soil should visibly leave the
ground, enter and settle in the bucket, spill when unsupported, and form a stream
and pile when dumped. The visible fill and reported payload must derive from the
same bucket-local material state rather than a fixed-volume Dig command.

## Confirmed Constraints

- The archived tracked-chassis milestone provides the stable composed chassis pose,
  reset signals, and model lifecycle needed by this task.
- Python/Pinocchio remains articulation authority. Godot owns terrain contact,
  local soil presentation, and the optional aggregate payload observation.
- `TerrainState` stable/loose Float32 layers remain the coarse persistent terrain
  representation; Terrain3D and its collider are presentation/collision consumers.
- Exact conservation, deterministic granular replay, and cross-quality visual
  parity are not product requirements. Obvious duplication, disappearance, and
  unbounded accumulation are still defects.
- Jolt rigid bodies are suitable for a small capped set of visible clods, not for
  representing every soil grain or determining bucket payload.

## Requirements

### Continuous bucket interaction

- Produce a fixed-physics-step bucket pose snapshot after the latest chassis and
  accepted articulation transforms are composed. The snapshot carries previous and
  current cutting edge, top edge, opening, and cavity transforms plus model,
  session, world, and generation identity.
- Classify cut, push, intake, carry, spill, dump, rear-shell support, and no-op from
  swept bucket proxies, terrain surface, bucket-local gravity, and relative motion.
  Missing, stale, rejected, or discontinuous snapshots must create no material.
- Provide separately validated SY205 and SY135 bucket contracts: nominal/heaped
  capacity, cutting and top edges, tooth direction, cavity/opening/side/rear
  proxies, material density, and visual attachment paths.

### Local material and terrain lifecycle

- Use an explicit bounded lifecycle:
  `coarse terrain -> active episode -> bucket occupancy or escaping flow -> settled
  accumulator -> coarse terrain`. Every episode is tagged with generation and
  unique identity so reset/reconnect/model switch cannot duplicate or revive soil.
- Use a compact CPU bucket occupancy solver as the source of retained volume, mass,
  center of mass, fill state, heaping, and spill. Capacity is calibration and an
  abnormal-state clamp, not a fixed amount granted per dig.
- Drive a smoothed bucket fill mesh and continuous GPU cut/intake/spill/dump/dust
  effects from the same transfer state. Use pooled, capped Jolt clods only as
  non-authoritative near-camera presentation.
- Reconcile settled flow into coarse scar/pile deltas. Small smoothed LOD loss or
  compaction is acceptable; one transfer identity may not exist in two lifecycle
  states at once.
- Introduce one terrain commit scheduler as the sole owner of applying queued
  `TerrainState` deltas and rebuilding Terrain3D/collision. It flushes once per
  profiled cadence, accumulated threshold, or bounded maximum latency; no soil
  subsystem may rebuild terrain directly.

### Controls, quality, and lifecycle

- Production UI and production input maps expose no Dig/Deposit button or key.
  Direct dig/deposit queue APIs remain available only to standalone tests or an
  explicit debug feature flag.
- A dynamic-soil feature flag can disable the new path and restore the existing
  manual aggregate diagnostic path without changing locomotion or articulation.
  The diagnostic controls remain hidden in production in either mode.
- Define balanced/high caps for active episodes, bucket cells, GPU grains, Jolt
  clods, fill-mesh complexity, terrain commit rate, lifetime, culling, and cleanup.
- Reset, reconnect, model switch, contract rejection, world-generation change, and
  feature disablement clear local material, emitters, clods, accumulators, and
  optional feedback within a bounded interval.

### Optional Python feedback

- Backend feedback begins only after the Godot-only visual gate passes. It is
  default-disabled and never blocks or changes the local visual simulation.
- Negotiate `bucket_load_feedback_v1` as an optional capability without changing
  the existing required `input_snapshot` and `commands` capabilities. New clients
  must remain compatible with a backend that does not know the optional feature;
  old clients must remain compatible with the new backend.
- When negotiated and enabled, send a bounded-rate latest-value sample containing
  model/session/generation identity, client sequence, mass, center of mass, fill,
  resistance, and quality. Python validates finite ranges and identity, mirrors the
  newest sample, and expires it after timeout. Terrain/grain replication and replay
  parity are not required.

## Out Of Scope

- Global soil made from thousands of Jolt rigid bodies, Jolt soft-body soil, or
  Terrain3D sculpting used as the local dynamic-material solver.
- Global DEM/PBD/MPM simulation, synchronous full-particle GPU readback, exact
  Float32 conservation, deterministic soil replay, or identical stochastic results
  across machines and quality tiers.
- Payload-driven hydraulic, chassis, or free-body dynamics. The following support/
  lift child may consume only a stable coarse support/contact signal.
- A local PBD solver in the initial implementation. It requires a separate planning
  review if the accepted cellular/GPU result fails the documented visual gate.

## Acceptance Criteria

- [x] In scripted SY205 and SY135 cut/carry/spill/dump scenarios, bucket motion alone
      produces every expected state transition and production Dig/Deposit controls
      are absent.
- [x] Visible retained soil, the fill surface, spill/dump behavior, and reported
      payload aggregates all derive from one bucket occupancy state and do not
      visibly contradict each other.
- [x] Both model-specific contracts pass debug-overlay review; invalid or stale pose
      snapshots create no terrain removal or local material.
- [x] Transfer identities move through the lifecycle without simultaneous ownership,
      obvious duplication, sudden large disappearance, or growth beyond configured
      active caps during a 30-second sustained excavation run.
- [x] The terrain commit scheduler is the only normal soil-mutation/rebuild owner
      (the initial scene presentation bootstrap is the documented exception), normally
      commits no faster than 10-15 Hz, respects the profiled maximum latency target,
      and rebuilds mesh/collision at most once per flush.
- [x] Balanced and high quality profiler captures meet the recorded CPU/GPU/physics
      budgets; disabling clods still preserves readable intake, carry, spill, and
      dump behavior.
- [x] Reset, reconnect, model switch, rejection, world reset, and feature disablement
      remove orphan local effects and stale payload no later than 0.5 seconds after
      the lifecycle event.
- [x] A new client completes the unchanged required handshake with a legacy backend,
      and a legacy client completes it with the new backend. Optional feedback is
      emitted only after positive negotiation and is rejected when stale, invalid,
      unnegotiated, or disabled.
- [x] Godot standalone tests, backend schema/runtime tests, `pixi run verify`, backend
      smoke, headless import, `git diff --check`, profiler capture, and Godot MCP live
      visual review pass.

## Deferred Escalation

If the accepted CPU occupancy plus GPU flow implementation still fails specifically
to make intake, settling, or spill visually convincing, plan a bounded 3-5 m local
PBD/native-compute prototype. It must retain aggregate-only readback, quality
fallback, and the same coarse-terrain authority boundary.
