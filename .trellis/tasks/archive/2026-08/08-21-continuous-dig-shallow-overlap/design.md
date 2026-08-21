# Design: Analytic Soil Cutting Loop

## Principle

Soil is material removal, not collision. The authoritative heightfield
(`TerrainState`) is sampled analytically under the kinematic tooth pose every
fixed tick; physics queries never arbitrate whether cutting happens. Queries
remain exclusively for rigid-body semantics: shell/rear support evidence and
obstacle blocking.

```
per fixed tick:
  tooth poses (kinematics, no query)
        │ bilinear sample TerrainState under tooth + edge width samples
        ▼
  penetration = surface_y − tooth_y            (analytic, zero lag)
        │ engaged = penetration > 0
        │ intent   = active work-equipment command OR movement criteria
        ▼
  engaged AND intent ──► queue cut(depth = min(penetration, maximum_cut_depth_m))
        └───────────────► engagement → resistance scale / band-floor stall
```

Invariant: terrain yields exactly as deep as the edge presses in the same
tick, so divergence between edge and surface cannot accumulate. Sink-through,
dead zones, and lift-restarts are structurally impossible rather than patched.

## Components

### 1. ExcavationWorld — analytic evidence replaces record arbitration

- New `_analytic_cut_evidence(snapshot)`: computes previous/current tooth
  world positions (existing `local_tooth_offset` chain), samples the surface
  at the tooth XZ plus `cutting_edge` width-line samples (contract
  `half_width_m`, 3 points), returns engagement, max penetration, and intent.
- Intent: any work-equipment joint target velocity beyond deadzone (swing
  included) OR legacy movement criteria (`forward_cut`/`downward_cut`).
- `_classify_interaction_records`: the `cutting_edge` classification comes
  from analytic evidence; a validated in-band query contact point adds an
  equivalent trigger (supplementary only). Shell/rear records keep the exact
  existing path; dump/spill/carry untouched.
- Batch eligibility splits: cutting eligibility is analytic (finite teeth,
  inside grid, intent); support eligibility stays `query_identity_valid`.
- `_cut_motion_from_batch`: uses real tooth positions directly; contact-point
  rewriting removed.
- Idempotency keys unchanged (`epoch|tick|generation|revision|sequence`);
  `physics_tick` uniqueness keeps analytic cuts duplicate-safe even when the
  motion sequence stalls with a stale collider.

### 2. Runtime — analytic engagement

- Engagement normalization drops its dependency on query validity:
  `probe_cut_penetration(candidate_bucket_frame, terrain_state)` runs every
  tick regardless of collider state, feeding the existing low-pass and
  band-floor stall. A lagging chunk swap can no longer disable resistance.

### 3. Sweeper — unchanged role, reduced authority

- Still sweeps shell/rear for support and blocking; still produces
  accepted_fraction from blocking proxies only. Its cutting-proxy records are
  informational; no classification depends on them.

## Failure Modes Considered

- **Resting bucket erosion**: depth clamp minimum would nibble terrain under a
  stationary bucket; intent gate prevents it (no commands → no cuts).
- **Press faster than yield**: brush depth equals per-tick penetration, so
  yield matches press by construction; residual overshoot bounded by the
  band-floor stall at `maximum_cut_depth_m`.
- **Cross-slope single-edge touch**: width-line samples catch off-center
  engagement; the supplementary query trigger covers exotic mesh contacts.
- **Stale collider**: cutting continues analytically; only support waits for
  fresh identity — matching their physical natures (soil data vs rigid body).

## Test Strategy

- New focused test `analytic_dig_test.gd`: sustained press queues cuts every
  commanded tick with bounded penetration; swing-drag cuts along the arc;
  resting bucket cuts nothing; stale identity keeps cutting but blocks support.
- `excavation_gameplay_test.gd`: hybrid cases keep passing via the
  supplementary trigger; expectations updated where they encoded
  query-mandatory cutting.
- `bucket_shallow_overlap_test.gd` / `cut_resistance_test.gd`: unchanged
  contracts (sweeper semantics, resistance curve) keep passing.
