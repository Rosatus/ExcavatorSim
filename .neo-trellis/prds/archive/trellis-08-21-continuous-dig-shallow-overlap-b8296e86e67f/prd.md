# Analytic soil cutting loop (continuous dig)

## Goal

Make digging a material-removal process driven directly by the authoritative
heightfield, not a collision-arbitrated state machine: every fixed tick the
kinematic tooth pose is sampled against `TerrainState`, and active commands
convert penetration into cut transactions and resistance immediately. Terrain
must yield at least as fast as the edge presses, eliminating the entire
symptom class (stops cutting mid-dig, clips through terrain, dead zones after
submersion, lift-required restarts).

## Scope Decision (2026-08-21, third revision)

Two prior patches (shallow-overlap validity, evidence bands) treated symptoms
of a structural flaw: soil evidence was arbitrated by physics queries against
a lagging, discretely-swapped collider mesh. The arbiter and the authority are
permanently half a tick apart, so every boundary condition eventually misfires.
This task replaces query-arbitrated cutting with an analytic loop. The
resistance load and band-floor stall from the previous iteration are kept
unchanged; they slot into the new loop as-is.

## Root Cause (structural, evidenced by three failed symptom fixes)

- Cutting evidence required rest-point proximity against the collider mesh;
  once the edge submerged past tolerance, evidence vanished, cuts stopped,
  terrain stopped yielding, and divergence accumulated until the query fully
  disarmed — free sink, visual clipping, permanent dead zone.
- No per-tick coupling existed between "edge pressed N mm deeper" and "terrain
  dropped N mm": yield rate was an emergent accident of batching, not a
  guaranteed invariant.

## Requirements

- Analytic engagement: sample `TerrainState` bilinearly under the tooth (and
  cutting-edge width samples) each tick; penetration = surface − tooth Y.
- Cutting fires when penetration > 0 AND dig intent (any active work-equipment
  command including swing, or movement criteria) — no query records involved.
- A validated in-band query contact remains an additional (never mandatory)
  cutting trigger so genuine mesh contacts off the sample line still count.
- Query failures, stale identity, or initial overlap can no longer disarm or
  block cutting; they only gate support transactions as before.
- Engagement for resistance/stall is computed analytically too, independent of
  collider availability, so the band-floor stall holds even while chunks lag.
- Cut depth stays `min(penetration, maximum_cut_depth_m)` via the existing
  `BucketSoilState._apply_cut`; capacity, grid, and idempotency keys unchanged.
- Shell/rear support and obstacle blocking semantics byte-identical.

## Acceptance Criteria

- [ ] Headless test: sustained vertical press keeps queuing cuts every tick
      while commanded; terrain surface under the tooth tracks downward and
      penetration stays bounded (no runaway sink, no dead zone).
- [ ] Headless test: swing-drag with engaged tooth queues cuts along the arc.
- [ ] Headless test: resting bucket with zero commands queues nothing despite
      contact.
- [ ] Headless test: stale collider identity does not stop analytic cutting;
      support transactions still require fresh identity.
- [ ] Full standalone matrix passes; `git diff --check` clean.
- [ ] Human live check: continuous press-dig, micro-trim, and slew-drag all
      excavate without lifting; no visual clipping.

## Out of Scope

- Granular terramechanics, force feedback models, multi-material soils.
- Sweeper/shell/rear support redesign (unchanged this task).
- Dump/spill/carry semantics (unchanged).
