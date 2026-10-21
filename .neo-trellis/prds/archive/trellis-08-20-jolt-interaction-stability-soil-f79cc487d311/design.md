# Technical Design

## Recommended Architecture

The recommendation is an AGX-inspired hybrid, not a direct AGX clone:

```text
operator commands
      |
      v
ray/shape track support + traction ---> one dynamic Jolt chassis

accepted bucket FK ---> terrain query active zone ---> TerrainState dirty patch
          |                        |
          |                        +--> removed volume ledger
          v                                      |
moving bucket parcel shell <--- DynamicSoilParcelManager
          |                                      |
          +--> captured aggregate                +--> settled loose-terrain batch

TerrainState snapshot + dirty bounds ---> Terrain3D region patch
                                     +--> dirty collider chunk swap
```

## Authority Layers

| Layer | Responsibility |
|---|---|
| Jolt chassis runtime | Chassis pose/velocity and track support/traction |
| Kinematic articulation | Slew, boom, arm, bucket FK and accepted motion |
| `TerrainState` | Stable/loose heightfield, revision, generation, dirty bounds |
| `BucketSoilState` | Capacity, transfer ledger, captured aggregate volume/mass |
| `DynamicSoilParcelManager` | Bounded active parcel bodies and terrain/bucket/world transfer states |
| Terrain3D/collider/effects | Derived presentation/contact consumers |

No parcel, renderer, collider, or Gateway component may write chassis pose or bypass the terrain/bucket transaction owners.

## Chassis Strategy

Use one coherent ray/shape-supported crawler model:

- Track probes provide vertical support through spring-damper forces and provide the normal-load estimate used by traction limits.
- Longitudinal force tracks target belt speed with acceleration/braking limits.
- Lateral resistance is high for straight/arc travel but reduced smoothly during counter-rotation so skid steer can pivot.
- Differential traction is the primary yaw source. A bounded yaw assist may remain only as a low-gain correction, not as a second saturated controller.
- The chassis hull remains for obstacles, rollover, and safety, but is raised or filtered so it is not the continuous flat-ground support surface.
- All forces are computed and applied in one fixed-physics phase from one contact snapshot.

This keeps the existing single-body maintenance boundary while removing the current box-contact/ray-controller conflict.

## Terrain Patch Contract

Each accepted terrain revision produces:

```text
terrain_epoch
world_generation
terrain_revision
full_refresh
dirty_rect_cells
surface snapshot / digest
```

Brush application converts its radius to a clamped grid rectangle, touches only those cells, and unions changed bounds across the fixed-step batch. A one-cell halo is included for normals and chunk seams.

### Terrain3D

- Startup/reset/generation change: build the 64 m presentation map and import once.
- Ordinary revision: retrieve the existing Terrain3D region height image, edit only mapped dirty pixels, update region height bounds, mark the region edited/modified, and call `update_maps(TYPE_HEIGHT, false, false)`.
- Keep the current native terrain visible while applying the patch; never call `_set_native_active(false)` merely because work is pending.
- Do not rebuild dressing on ordinary revisions. The current rocks/grass are outside the logical excavation patch and can remain stable.
- Rebuild the fallback renderer only when native Terrain3D is unavailable, or update its cached mesh data incrementally.

Terrain3D 1.0.2 documents direct pixel/region image editing followed by `update_maps`; `all_regions=false` refreshes only regions marked edited. It does not expose a guaranteed pixel-subrect GPU upload contract, so the implementation promises edited-region refresh, not a fictitious partial-texture API.

### Collider

The project collider becomes a set of stable per-chunk bodies/shapes. Dirty chunks plus a border halo are rebuilt off to the side and swapped individually. The applied terrain revision advances only after all affected chunks are installed. Unchanged chunks and the previous revision remain available during preparation.

## Soil Strategy

### Why Not Full Per-Grain Physics

AGX itself does not use raw particle contacts as the sole excavation authority. It converts solid cells through a shovel active zone, kinematically couples dynamic particles to the shovel, constructs aggregate bodies for resistance, and merges settled mass back into terrain. Its documentation also identifies particle count and solver iterations as the main performance cost.

The project therefore uses three representations:

1. **Heightfield mass** — stable/loose terrain in `TerrainState`.
2. **Dynamic parcels** — a bounded pool of Jolt rigid clods, each carrying explicit volume/mass and transfer identity.
3. **Aggregate/fines presentation** — captured bulk volume plus GPU dust/small grains.

### Shovel Geometry

Each model contract declares:

- cutting edge;
- cutting direction;
- lip/top edge or opening plane;
- convex inner capture volume;
- compound shell plates for bottom, back, and sides.

Only cutting-edge active-zone contact with admissible motion excavates. Side/back contact remains grading/support evidence.

The moving parcel shell is an `AnimatableBody3D` or equivalent kinematic collision carrier updated from accepted bucket FK. Its collision mask includes dynamic soil parcels only. Terrain contact continues through query-only bucket proxies, preventing an infinite-mass kinematic bucket from fighting the chassis/terrain solver.

### Transfer State Machine

```text
terrain stable/loose
  -> activated_dynamic
  -> world_parcel
  -> bucket_candidate
  -> bucket_captured/aggregate
  -> dumped_world_parcel
  -> settled
  -> terrain loose
```

- Cutting removes a committed terrain volume and allocates it across a bounded number of parcels plus optional aggregate remainder.
- A parcel becomes captured only after crossing the lip plane into the inner volume and remaining contained for a short hysteresis window. Capacity rejection leaves it in the world.
- Captured aggregate contributes payload mass/COM and a gravity-aligned fill surface.
- Dumping releases parcels with the bucket-point velocity plus small non-authoritative jitter; Jolt gravity controls the fall.
- Low-speed grounded parcels merge in batches into the loose terrain layer and return to the pool.
- Every transition carries explicit volume so visual behavior can be non-deterministic without abandoning conservation.

## Quality Budgets

- Dynamic parcel pool is quality-scaled and hard-capped; the initial target is 32 low, 64 balanced, and 96 high, with an absolute cap of 128.
- Fine GPU particles remain visual-only and may use a much larger count.
- Parcel collision uses dedicated layers and sleeping; no parcel collides with the excavator chassis or intermediate work-equipment links.
- Full terrain refresh, parcel-pool recreation, and dressing rebuild occur only on startup/reset/model/generation transitions.

## Rollback

- Chassis child can fall back to the current runtime behind a temporary tuning switch until the new support solver passes both models.
- Terrain child retains full snapshot import for startup and stale recovery; incremental patch failure keeps the previous visible terrain and schedules a full resync.
- Soil child can disable dynamic parcels and retain the corrected gravity-aligned aggregate/GPU presentation without changing terrain or bucket authority.

## Child Sequencing Update

The original chassis child removed the repeating support bounce, but follow-up
visual evidence identified two separate calibration gaps: model-specific reset
posture and insufficiently measured longitudinal/braking response. The new
`08-20-calibrate-jolt-posture-longitudinal-response` child must complete after
the chassis support solver and before incremental terrain or parcel soil work.
It changes only Jolt reset/response behavior and its telemetry/tests; terrain
patching and bucket-soil authority remain downstream consumers.
