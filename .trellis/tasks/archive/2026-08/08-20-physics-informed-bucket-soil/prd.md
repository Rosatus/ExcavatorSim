# Physics-informed bucket soil parcels

## Goal

Replace the current direct cut-to-bucket visual shortcut with a bounded, physics-informed soil transfer that makes bucket capture, carry, and gravity-driven release visibly natural while preserving volume/capacity accounting.

## Recommendation

Use an AGX-inspired hybrid rather than full per-grain physics. A shovel active zone removes terrain mass, a bounded pool of volume-carrying Jolt parcels moves through a compound bucket shell, and aggregate/fine representations cover the remaining volume. `TerrainState` and `BucketSoilState` remain authoritative ledgers.

## Requirements

- Only cutting-edge active-zone contact with admissible cutting direction and motion removes terrain. Shell/rear contact alone must not dig.
- Cut volume becomes world dynamic parcels/aggregate first; it is not immediately credited to the bucket.
- A moving, model-specific compound bucket shell collides with parcels only. It contains bottom/back/side plates and an open mouth; terrain collision remains query-only.
- Parcels crossing the lip plane into the cavity and remaining contained can be captured until capacity is reached. Parcels may miss or spill.
- Captured parcel/aggregate volume contributes to `BucketSoilState` capacity, mass, center of mass, and fill presentation.
- Dump/spill releases material with inherited bucket velocity and Jolt gravity. Fines may use a separate GPU stream.
- Grounded, low-speed parcels settle into loose terrain via one batched transaction and return to the pool.
- Reset, pause/stop, focus loss, model switch, and generation changes clear or reconcile all parcel states.
- Quality profiles cap dynamic parcel bodies; no one-body-per-grain design.

## Acceptance Criteria

- [ ] A cutting edge produces a visible excavation and a bounded parcel burst; shell-only contact produces neither a terrain transaction nor bucket fill.
- [ ] Repeated digs produce different captured volumes when parcel trajectories differ, while total ledger volume remains conserved within tolerance.
- [ ] The bucket fill surface stays aligned with world gravity while the bucket rotates.
- [ ] Dumping causes parcels to leave through the opening and fall; no material floats, accelerates upward, or remains glued to the old cavity transform.
- [ ] Settled parcels create a loose terrain deposit through the dirty terrain path and stop colliding after recycling.
- [ ] Capacity, parcel count, transfer IDs, and teardown pass for SY205 and SY135.
- [ ] Low/balanced/high quality budgets remain within configured active-body caps and do not regress fixed-step timing gates.
- [ ] Godot MCP live smoke confirms dig -> carry -> partial miss -> dump -> settle behavior with Python stopped.

## Out of Scope

- Full AGX soil mechanics, continuum soil, hydraulic force feedback, or production excavation calibration.
- Overhangs/caves and discontinuous volume below a heightfield.
- Making individual visible grains authoritative.
