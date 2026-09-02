# Voxel excavation terrain redesign

## Goal

Replace the heightfield excavation product path with one bounded, purpose-built
Voxel Tools work zone that produces continuous, clean, responsive excavation
for an excavator simulator. Terrain3D remains the non-deformable surrounding
worksite; all removal, transport, dumping, compaction, and re-excavation of soil
happens inside the voxel zone.

This is a greenfield product redesign for the pinned Godot 4.7.2 custom build
with Voxel Tools 1.7. Existing excavation implementations may be deleted or
rewritten and do not constrain the new authority model.

## Background and confirmed facts

- The pinned custom editor and export templates expose Voxel Tools 1.7, but the
  current product scene does not instantiate a voxel terrain.
- The current soil authority is a `129 x 129` two-layer heightfield at `0.5 m`
  spacing. Terrain3D consumes derived presentation data.
- Two manual attempts at the full-surface heightfield solver failed the product
  gate: digging remained stuttery, removed little soil, and produced small
  intermittent marks despite focused automated checks passing.
- Voxel Tools supports smooth 3D SDF terrain, bounded `VoxelTerrain`, bulk
  runtime edits, localized asynchronous remeshing, and generated static
  collision. Collision/mesh readiness is not guaranteed in the edit tick.
- The current machine spawn is `(0, 0)`, and both the existing site layout and
  the SY205 initial direction favor a north/+Z approach to a side work zone.

## Requirements

### R1. Worksite composition

- Terrain3D shall become hard, non-excavatable surrounding terrain.
- The first product scope shall contain one fixed `32 m x 32 m` voxel work zone
  on the north/+Z side of the site, with `6 m` initial soil depth and `4 m`
  above-grade deposit headroom.
- The existing `(0, 0)` spawn shall remain entirely on hard terrain with an
  approximately `8 m` approach apron. The hard site may extend toward +Z and
  conflicting presentation-only dressing may move.
- The zone shall be visibly enclosed, with a clear vehicle entrance aligned to
  the initial +Z travel direction. Its boundary shall hide volume edges without
  creating a second soil or collision authority.
- Zone dimensions shall be centralized configuration. Multiple zones, runtime
  relocation, and runtime resizing are not required.

### R2. Volumetric soil representation

- The work zone shall use the installed Voxel Tools module and a smooth,
  three-dimensional SDF representation.
- Valid excavation may create undercuts, overhangs, near-vertical faces, and
  cavities. The result shall not collapse to a heightfield or column model.
- The initial implementation shall use bounded `VoxelTerrain` rather than a
  world-scale LOD terrain. The exact uniform voxel scale is an engineering
  parameter established by the foundation benchmark, starting at `0.125 m`.
- Soil data mutation shall have one gameplay authority. Terrain3D, Voxel Tools
  meshes/colliders, Jolt contacts, particles, and visible clods are derivatives
  or consumers, not competing writers.

### R3. Continuous bucket cutting

- Cutting shall use a swept volume derived from accepted fixed-tick bucket
  motion and the hash-bound geometry of each supported bucket model.
- The cutter shall include teeth/main edge and side edges, followed by a
  constrained bucket-clearance volume so no untouched spikes remain inside an
  accepted bucket sweep.
- Motion shall be subdivided by voxel-relative translation and rotation bounds,
  not render frame rate. All proposed edits in one commit window shall be
  clipped to the zone and coalesced before mutation.
- Direction, speed, soil overlap, and engagement hysteresis shall prevent a
  stationary, above-ground, separating, or teleported bucket from acting as an
  unconditional eraser.
- Accepted removal shall be limited by available bucket inventory. A full
  bucket shall not silently delete additional authoritative soil.

### R4. Soil inventory, dumping, and compaction

- Bucket contents shall be bounded authoritative inventory, credited only by an
  accepted voxel removal transaction and limited by the active model capacity.
- Dumping inside the zone shall return inventory to the same voxel authority as
  smooth SDF deposits that are collidable, traversable, compactable, and
  re-excavatable.
- Deposited soil shall use bounded aggregate placement plus limited
  angle-of-repose settling. It shall not create one simulated grain or rigid
  body per soil particle.
- Track contact may compact loose deposited material through bounded,
  coalesced edits; visual particles remain non-authoritative.
- Dumping outside the voxel zone shall not create authoritative soil on the
  Terrain3D surface and shall not debit bucket inventory. A bounded transient
  scatter effect and clear boundary diagnostic are allowed.
- The transaction ledger shall keep terrain-material delta plus bucket
  inventory conserved within a declared voxel-discretization tolerance.

### R5. Jolt and asynchronous collision

- Jolt shall continue to own chassis rigid-body motion, tracks, support, and
  blocking collision. Soil removal decisions shall use authoritative SDF/tool
  state and accepted motion rather than stale collision contacts.
- Tracks and chassis shall be able to enter, traverse, and park in the voxel
  zone and on settled deposits.
- Mesh and collision rebuild work shall be bounded and prioritized around the
  active bucket envelope and track-support neighborhood.
- Each dirty block/region shall carry generation and revision readiness. A
  newly edited region shall not silently become valid Jolt support until its
  matching collision work is complete.
- Driving into collision-pending terrain shall fail safely through bounded
  motion/support gating. Stale data shall not cause uncontrolled drops,
  impulses, or cross-seam snagging.

### R6. Lifecycle, diagnostics, and performance

- Application startup shall create the deterministic initial work zone. No
  voxel persistence or migration of old heightfield saves is required.
- A game-level reset shall restore initial SDF/material state, clear bucket and
  visual soil, advance the authority generation, and reject stale asynchronous
  results.
- Runtime diagnostics shall expose generation/revision, queued edit volume,
  dirty/ready blocks, mesh/collision latency, Voxel Tools backlog/drop counters,
  transaction counts, bucket inventory, conservation error, and rejected edits.
- The fixed-tick authority path shall remain bounded. Bulk buffer/shape edits
  and chunk-aligned dirty regions shall replace per-frame full-volume rebuilds
  and unbounded per-voxel calls.
- The final product path shall remove obsolete heightfield excavation modes and
  their hot-path integration after voxel acceptance. A temporary development
  selection/rollback seam may exist only until cutover.

### R7. Validation ownership

- Agent validation shall use the smallest deterministic parser/import checks,
  pure geometry/ledger tests, and focused headless runtime scenarios after the
  implementation is stable.
- Godot AI MCP remains the recommended development-time tool for scene/resource
  inspection and structural verification.
- Human review owns final Forward+ visual cleanliness, interactive digging feel,
  driving feel on edited terrain, and sustained subjective smoothness.
- Heavy matrices and performance runs shall execute once at their owning stable
  milestone, not after every edit. The retired paired bucket-pass soak remains
  out of scope.

## Acceptance criteria

- [ ] **AC1 (R1/R2):** A fresh product scene shows one enclosed north-side
  `32 x 32 m` smooth voxel zone with the excavator spawned on hard Terrain3D,
  an unobstructed approach, no visible hole, and no overlapping collider seam.
- [ ] **AC2 (R3):** Slow, fast, translated, and curling strokes from both SY205
  and SY135 form a continuous trench/cavity matching the accepted cutter and
  clearance envelope, with no untouched spikes inside it.
- [ ] **AC3 (R3):** Stationary, above-soil, separating, out-of-bounds, and
  teleport samples remove no soil; valid entering/curling samples do.
- [ ] **AC4 (R4):** Accepted removal increases bucket inventory without
  exceeding model capacity; a full bucket causes no unaccounted deletion.
- [ ] **AC5 (R4):** In-zone dumping creates a stable, collidable pile that can
  be traversed, compacted, and excavated again while ledger error stays within
  the declared discretization tolerance.
- [ ] **AC6 (R4):** Out-of-zone dumping leaves both hard terrain and bucket
  inventory unchanged and emits one bounded diagnostic/visual response.
- [ ] **AC7 (R5):** The excavator drives from the hard apron into the voxel zone,
  traverses edited ground, and parks on it without falling through, catching on
  chunk seams, or receiving unstable impulses.
- [ ] **AC8 (R5/R6):** Sustained digging and dumping keep edit queues bounded,
  expose mesh/collider backlog, and meet the profiled product frame budget
  without per-edit full-volume rebuilds.
- [ ] **AC9 (R6):** Reset restores the initial zone and empty bucket, advances
  generation, and prevents pre-reset mesh/collision work from reappearing.
- [ ] **AC10 (R6/R7):** Fixed input produces identical transaction ordering,
  accepted voxel edits, bucket inventory, and authority hashes independent of
  render frame rate; subjective visual/performance criteria remain explicitly
  pending until human approval.
- [ ] **AC11 (R6):** Final cutover leaves one voxel excavation product path and
  removes obsolete heightfield cutting/loose-soil runtime ownership without
  changing Python/Gateway transport or non-soil machine controls.

## Out of scope

- Replacing the whole world or distant Terrain3D landscape with voxels.
- DEM, MPM, SPH, per-grain rigid bodies, or production-grade continuum soil.
- Multiplayer/network terrain replication or Python terrain authority.
- Cross-application persistence, save migration, or replay of voxel edits.
- Multiple/movable work zones or runtime resizing.
- Production calibration of hydraulics, soil mechanics, machine CAD, or haptic
  force feedback.
- Backward compatibility with old excavation solver modes or old soil saves in
  the final product.
