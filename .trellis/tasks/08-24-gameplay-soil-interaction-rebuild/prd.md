# Gameplay soil interaction rebuild

## Goal and user value

Replace the current tooth-point, circular-brush, parcel-capture excavation chain
with a game-oriented soil system in which the complete bucket can dig, scrape,
push, grade, carry, spill, and dump visibly continuous material. The result must
look convincing and feel responsive on ordinary desktop hardware without trying
to reproduce professional hydraulic circuits or engineering-grade soil mechanics.

## Confirmed baseline

- `TerrainState` is the persistent deterministic authority and currently stores
  `stable_heights` plus `loose_depth`; derived renderers and colliders consume its
  snapshots (`godot/client/scripts/terrain_state.gd:4-28`).
- Current cutting samples the cutting-edge origin against the height field and
  removes a circular brush. The cut is deliberately decoupled from bucket
  capacity (`godot/client/scripts/excavation_world.gd:524-562`,
  `godot/client/scripts/bucket_soil_state.gd:229-274`).
- Cut material becomes one of at most 48 Jolt parcel carriers. Bucket volume only
  increases if a carrier enters the cavity below the capture-speed threshold;
  parcels never arbitrate cutting (`godot/client/scripts/soil_parcel_pool.gd:4-24,431-477`).
- The current fixed-tick order couples analytic interaction, ledger stepping,
  parcel stepping, forced terrain commit, and transfer reconciliation in
  `ExcavationWorld` (`godot/client/scripts/excavation_world.gd:82-112`).
- Reset, model switch, authority changes, and disable already provide generation
  boundaries at which a new soil authority can cut over without migrating
  in-flight legacy parcels (`godot/client/scripts/excavation_world.gd:837-888`).
- Only one excavator model is active in the current product session. SY205 and
  SY135 must both satisfy the same behavior contract, but simultaneous multi-
  machine soil ownership is not required.

## Requirements

### R1 — Full-bucket semantic interaction

Describe the complete bucket with model-specific, simplified interaction
proxies aligned to accepted presentation/Jolt poses. Teeth and the main cutting
edge penetrate and cut stable soil; side cutters widen and side-cut; the floor
and wear surface scrape, scoop, grade, and compact; the outer back and sides push
or back-drag; inner surfaces contain, frictionally guide, and compress active
material; the opening controls entry, overflow, and release. The system must not
treat every overlapping triangle as an identical terrain-deletion tool.

### R2 — Persistent terrain plus bounded active soil

Keep a persistent terrain field for long-lived height, loose material, material
class, and game-level compaction. Center one bounded 3–5 m local soil patch on
the active bucket; the same patch must include the receiving ground during dump
and represents short-lived separation, flow, pile formation, and settling.
Material crossing the patch boundary must be conservatively settled into the
persistent field rather than requiring a second simultaneous patch. Stable active
material must likewise rasterize back when it sleeps or is evicted.

The active patch may use a fixed-budget particle, voxel, or position-based
implementation. The prototype must select the simplest implementation that meets
the observable behavior and performance contract; bit-exact particle replay is
not a product requirement.

### R3 — One conservative material lifecycle

One fixed-tick `SoilInteractionAuthority` must own transfers among persistent
terrain, active soil, bucket contents, released/in-flight material, and settled
terrain. A successful cut may not delete terrain first and then depend on a
later incidental rigid-body capture to create bucket payload. Visual particles,
dust, and hero clods may represent material, but their counts never define mass.

### R4 — Continuous cut, carry, dump, and settle

Material entering the bucket through its opening must immediately and
progressively affect one authoritative bucket ledger. Carry must preserve volume
and provide a gravity-relative visible fill surface. Spill and dump must debit
the same ledger, re-enter the active patch with bucket point velocity, form a
readable pile, and settle back into the terrain field without duplication or
loss.

### R5 — Game-feel resistance, not hydraulic simulation

Derive a normalized engagement/load signal from tool role, displaced material,
material preset, fill ratio, and motion direction. Use it to apply smooth,
bounded work-equipment speed reduction and to drive camera, animation, VFX, and
audio cues. Do not model pump pressure, valve flow, cylinder force, engine torque
curves, structural stress, or force-feedback hardware. Soil response must never
permanently stall controls or compromise neutral/reset safety.

### R6 — Visual-first product quality

Prioritize readable soil separation, movement into the bucket, bucket fill,
side spill, dumping, pile formation, and surface continuity. Low/balanced/high
profiles may change solver/render resolution and visual density, but not material
ownership or operator-visible lifecycle semantics. Balanced 1920×1080 remains
the primary 60 FPS target on the development machine.

### R7 — Safe migration and fallback

Develop the new chain behind an explicit soil-authority mode. Begin with shadow
telemetry and visual-only comparison, then change ownership only at reset/model/
authority-generation boundaries. The old analytic/parcel path remains a
compatibility fallback through final validation; its parcels may later remain as
bounded hero clods but must not double-credit or double-deposit primary material.

### R8 — Double-model, offline-first compatibility

SY205 and SY135 use the same authority and transaction semantics with separate
tool geometry/configuration. Preserve offline Godot/Jolt operation, optional
gateway behavior, Terrain3D-as-derived-presentation, fixed-step lifecycle,
quality profiles, provenance, and the existing product reset/model-switch
contracts.

## Acceptance criteria

- [ ] Both SY205 and SY135 expose complete, validated bucket tool descriptors;
      debug visualization shows the semantic regions aligned with the rendered
      bucket throughout the accepted articulation range.
- [ ] The bucket can visibly perform forward cutting, side cutting, scooping,
      floor scraping/grading, back pushing/back-dragging, carrying, controlled
      spill, dumping, and settling without single-point or whole-volume terrain
      deletion artifacts.
- [ ] A real unassisted operator sequence produces nonzero bucket payload after
      cutting on both models; carry and dump do not use test-only volume credit.
- [ ] Every transaction balances within `max(1e-6 m³, 0.1% of accepted moved
      volume)`. After a 20-cycle soak, final unexplained drift is no greater than
      `max(1e-5 m³, 0.5% of one bucket capacity)`.
- [ ] The visible cut volume, bucket fill, spill/dump amount, settled pile, and
      published payload all derive from the same accepted transfers.
- [ ] Free motion, light scraping, active cutting, near-full loading, overflow,
      and blocked motion have distinct bounded game feel; speed returns smoothly
      to normal after disengagement and controls cannot deadlock.
- [ ] Balanced 1920×1080 sustains 60 FPS on the development machine during the
      standard two-model journeys. The active soil implementation has explicit
      per-profile update, memory, and visual budgets. Before authority cutover,
      active-soil p95 update cost must be at most 2/4/6 ms and active-soil memory
      at most 96/256/512 MiB for low/balanced/high respectively.
- [ ] Reset, disable, model switch, pause/focus recovery, authority-mode change,
      Terrain3D failure, and optional-gateway degradation leave no stale patch,
      material, load, visual body, or response state.
- [ ] Legacy fallback and new authority can each complete the regression journey;
      primary mode never has two owners for cut, bucket credit, release, or settle.
- [ ] Focused soil tests, Godot standalone matrix, offline product tests,
      `pixi run verify`, task validation, provenance, performance capture, and
      human visual comparison pass.

## In scope

- Full-bucket semantic proxies; persistent terrain-field extensions; one bounded
  local active-soil patch; conservative material transactions and bucket ledger;
  game-feel speed response; derived soil visuals/telemetry required to prove the
  lifecycle; feature flags, fallback, tests, evidence, and specs.
- Game-oriented material presets such as loose soil, compact dirt, sand-like
  low-cohesion soil, and damp/cohesive dirt, provided they remain tunable presets
  rather than calibrated engineering models.

## Out of scope

- Professional hydraulic, engine, cylinder, structural, soil-pressure, or
  force-feedback simulation; calibrated geotechnical claims; full-field DEM,
  MPM, or unbounded rigid-body particles; paid proprietary middleware.
- Arbitrary caves, tunnels, overhangs, simultaneous multi-machine patch
  ownership, multiplayer, backend authority migration, new excavator assets, or
  replacing Jolt chassis/work-equipment authority.
- Making visual particle counts authoritative or requiring bit-exact replay of
  all active particles across GPUs.

## Key decisions and deferred items

- The complete bucket participates, but surfaces have distinct roles; “all
  surfaces cut identically” is explicitly rejected.
- Visual continuity and responsive game feel outrank engineering calibration.
- The persistent logical ledger and terrain transfers are deterministic and
  replayable; detailed active-patch motion may be visually deterministic within
  tolerances rather than bit exact.
- CPU grid/particle versus Godot compute implementation is intentionally chosen
  by the active-patch prototype using the same behavior and budget gates. This
  technical choice does not change product scope or acceptance behavior.
- Legacy parcel transport remains available until the migration child proves the
  new owner; deletion of compatibility code is deferred beyond this parent.
