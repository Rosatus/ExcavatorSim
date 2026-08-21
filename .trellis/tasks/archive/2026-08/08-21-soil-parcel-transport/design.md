# Design: Bounded soil parcel transport

## Architecture position

```
ExcavationWorld (_physics_process)
  soil_state.step_fixed()            -> result.cut_events[]   (extended)
  parcel_pool.step_fixed(delta, snapshot)                      (new, after step_fixed)
      spawn_from_cut_events(...)     <- cut_events + chassis velocity
      capture pass                   <- bucket cavity frame from status
      settle pass                    -> soil_state.queue_deposit_volume(...)
  dump/spill handler                 -> parcel_pool.release_volume(...)  (rewritten)
```

The pool is a plain `Node3D` created by `ExcavationWorld` in `_ready`
(sibling of presentation nodes), script `soil_parcel_pool.gd`, class
`SoilParcelPool`. It is deliberately not a scene file so tests can
instantiate it headless.

## Data flow decisions

### Cut events (option B: result-carried)

`BucketSoilState._apply_cut` already returns accepted cuts with volume and
has the tooth positions in the command. `step_fixed` aggregates a new
`cut_events` array into its result:
`[{center: Vector2, tooth: Vector3, volume_m3: float}]`.
No ledger/transfer changes; spawn happens in the world right after
`step_fixed`, which (with force flush) is the same tick terrain yields.

### Capture test (bucket-local box)

Per tick the world passes the bucket cavity transform (already published in
the visual snapshot as `pose.cavity`) and interior half-extents derived from
the soil contract. A parcel is capturable when:

- local position inside interior AABB (half-extents + small margin),
- relative speed to bucket origin below `capture_speed_max` (2.0 m/s),
- recapture guard inactive.

On capture: `soil_state.credit_captured_volume(parcel.volume)` (new public
wrapper around `_add_occupancy`, clamped to free capacity); credited amount
below parcel volume leaves the remainder in the body (partial capture), and
a fully credited body recycles.

### Settle (reuse deposit pipeline)

Grounded check via one short downward shape/ray query against the terrain
mask; dwell timer 0.35 s under 0.4 m/s. Settle calls
`soil_state.queue_deposit_volume(seq, xz_position, volume)`; the parcel
enters `settling` state and recycles when the next `step_fixed` result
reports the deposit accepted (tracked via a pending counter matched against
result deposit volume). Rejection retries up to 3 times, then forces recycle
(volume dropped, counted in telemetry).

### Dump/spill rewrite

The existing handlers compute rate-limited volumes from ledger occupancy.
They now call `parcel_pool.release_volume(volume, lip_world, bucket_velocity)`
instead of `queue_deposit_volume`. Occupancy is removed immediately at
release (`_remove_occupancy` through a new public `release_poured_volume`);
parcels carry it physically. Released parcels get `guard_until = now + 1.0 s`
and must exit the cavity AABB once before becoming capturable.

### Collision layers

Parcels: `collision_layer = payload layer bit` from the rig descriptor
(fallback `1 << 6`), `collision_mask = terrain | machine` bits from the same
descriptor. Machine bodies are untouched; parcels detect them one-way.

## Parcel body

- `RigidBody3D` + SphereShape3D + SphereMesh, shared material; radius from
  volume via sphere inversion clamped to [0.03, 0.09] m; mass =
  volume * density (1600 kg/m^3 default).
- Pool preallocates budget bodies frozen and invisible at `_ready`;
  activate/deactivate toggles `freeze`/`visible`/teleport (same pattern as
  SoilEffects clods).
- Volume split on spawn: one parcel if volume <= large clamp, else two.

## Budgets and lifecycle

- Default budget 48 active bodies; spawn beyond budget steals the oldest
  settled parcel, else the oldest flying one.
- `clear_for_generation()` deactivates everything; wired where
  `soil_state.reset_for_generation` is already called (world reset paths).
- No per-tick allocations: events arrays are reused, math is inline.

## Test strategy

- New `tests/soil_parcel_test.gd` (headless, fake TerrainState like
  analytic_dig_test): spawn bounds/velocity inheritance, budget steal,
  capture credit + overflow skip, guard blocks instant recapture, settle
  queues deposit and recycles, clear empties.
- `excavation_gameplay_test.gd`: re-enable occupancy expectations (dig
  accumulates when parcels captured; dump reduces; spill path live). The
  sections flipped to "empty bucket" earlier are restored to capture
  semantics via the pool's deterministic test hooks (capture forced by
  placing cavity over spawned parcels).
- `release_candidate_test.gd` M7: restore carry/dump assertions with the
  pool attached.
- Matrix registration for the new suite.

## Risks

- Physics cost of 48 rigid bodies among the machine: bounded, spheres only,
  masked to terrain+machine; fixed-step gates watched by release candidate.
- Ledger conservation across partial captures/rejected settles: covered by
  explicit tolerance assertion in tests rather than exact equality.
- Capture false positives while digging (bucket passing through spawn
  spray): relative-speed gate + entry margin keep grab radius tight.
