# Jolt interaction stability and soil behavior

## Goal

Remove the three interaction defects that currently dominate the standalone simulator experience: unstable crawler travel, full-terrain flicker during excavation, and bucket soil that neither looks nor falls naturally. The result should remain maintainable within the approved Godot/Jolt hybrid boundary rather than becoming a full hydraulic, multibody, or per-grain soil simulator.

## Background

- The default product is Godot/Jolt with one dynamic chassis and bounded kinematic work equipment; Python is an optional gateway.
- The current crawler combines load-bearing rigid-body contact against a concave terrain mesh with a separate ray-based traction controller. This creates competing contact constraints and poor skid-steer behavior.
- Every accepted terrain revision currently hides Terrain3D, rebuilds complete height/control images, imports them again, and rebuilds dressing/fallback derivatives.
- `BucketSoilState` currently moves cut volume directly into a logical bucket grid. `SoilEffects` then derives a local-axis fill mesh, GPU flow, and a small pool of non-authoritative clods. Physics does not decide what actually enters or exits the bucket.
- AGX Terrain uses a hybrid model: a shovel active zone converts solid terrain mass to dynamic soil; dynamic particles are kinematically coupled to the shovel; aggregate bodies provide force feedback; settled dynamic mass merges back into the terrain.

## Requirements

### R1. Stable and responsive tracked chassis

- Straight travel, turning, and counter-rotating pivot must not cause sustained chassis heave, roll, pitch, or visible whole-machine jitter on the construction-site ground.
- Realized straight and pivot speeds must track the configured belt-speed targets instead of merely satisfying existence-level motion tests.
- Flat-ground support and traction must have one coherent owner. The safety/obstacle chassis hull may remain, but it must not compete with the track support solver as a second load-bearing terrain model.
- The solution must retain a single dynamic chassis and must not introduce individual track shoes, suspension joints, or full vehicle multibody dynamics.

### R2. Incremental terrain deformation without flicker

- Ordinary cut/deposit commits must keep the last accepted Terrain3D surface visible until the next revision is ready; queuing work must never hide the entire terrain.
- The logical terrain mutation path must expose the affected cell rectangle and avoid scanning or rebuilding unrelated cells where practical.
- After initial materialization or full reset, Terrain3D updates must edit the existing region height image and refresh only edited region maps instead of calling full `import_images` for every revision.
- Rocks, grass, and other site dressing must not be freed and recreated for every terrain revision.
- The exact-revision custom terrain collider must replace only dirty chunks and must keep the previous chunks active until replacements are ready.
- Full snapshot/import remains available for startup, reset, generation change, stale recovery, and explicit resynchronization.

### R3. AGX-inspired physics-informed bucket soil

- Excavation activation must be driven by the cutting edge, cutting direction, motion, and terrain intersection. Generic contact by the whole bucket must not automatically delete terrain.
- Removed terrain volume must first become a bounded dynamic-soil transfer rather than being credited directly to the bucket.
- A model-specific moving bucket shell must collide with dynamic soil parcels but not with the terrain/chassis authority layers. It must approximate the bottom, back, and side walls while keeping the mouth open.
- The amount captured must depend on physical parcel motion through the bucket lip/cavity, subject to capacity and conservation checks.
- Dumped material must inherit bucket point velocity and then fall under Jolt gravity. Artificial upward or sideways flow direction may be used only for disposable dust/fines, not for authoritative parcels.
- Dynamic parcels that settle on the ground must merge back into the loose terrain layer through a batched terrain transaction.
- `TerrainState` remains the stable/loose heightfield authority. `BucketSoilState` evolves into the transfer/capacity ledger and aggregate state owner; it is not removed.
- Visual fidelity may use a world-gravity-aligned aggregate fill surface and GPU fines in addition to bounded rigid soil parcels.

### R4. Integration and product boundaries

- Work proceeds in this order: tracked chassis stability -> incremental terrain updates -> physics-informed soil parcels.
- Both SY205 and SY135 must use model-specific chassis and bucket contracts with no cross-model fallback.
- Reset, model switch, lifecycle stop/pause, focus loss, and authority generation changes must clear dynamic parcels and pending transfers safely.
- The feature must run without Python and must not change the optional gateway authority boundary.

## Acceptance Criteria

- [ ] On flat ground, sustained straight, arc, and pivot commands complete without visible whole-machine jitter or repeated solver bounce.
- [ ] Straight and pivot performance is asserted against configured target speeds, with bounded heave and roll/pitch oscillation telemetry.
- [ ] Repeated bucket contact and excavation produce no whole-terrain hide/show flash and do not replace the Terrain3D node.
- [ ] Normal cut/deposit commits report dirty bounds, avoid full Terrain3D import, and rebuild only affected collider chunks.
- [ ] Cutting-edge excavation creates bounded dynamic soil parcels at the cut location; shell/rear contact alone does not excavate.
- [ ] Some excavated parcels can miss the bucket, while parcels that cross and remain within the cavity are captured up to capacity.
- [ ] Rotating the bucket downward releases captured material under gravity; settled material becomes loose terrain without a mass-ledger leak.
- [ ] SY205 and SY135 pass standalone tests and a Godot MCP live smoke for travel, excavation, carry, dump, reset, and model switching.
- [ ] Active dynamic soil bodies remain within configured quality budgets and teardown leaves no stale bodies or transfers.

## Out of Scope

- Full AGX Terrain equivalence, continuum/MPM/FEM soil, or one rigid body per visible grain.
- Individual track links, sprockets, rollers, hydraulic cylinders, pressure circuits, or dynamic boom/arm/bucket bodies.
- Production-grade excavation resistance calibration or bidirectional soil force feedback into the kinematic work equipment.
- Tunnels, caves, overhangs, or discontinuous volumetric terrain.
- Python-side pose, terrain, or bucket authority.

## Task Map And Order

1. `08-20-stabilize-jolt-tracked-chassis` — remove competing support/contact behavior and tune responsive skid steer. (Archived after initial stabilization.)
2. `08-20-calibrate-jolt-posture-longitudinal-response` — calibrate model-specific reset posture and bounded acceleration/braking response before terrain/soil work.
3. `08-20-incremental-terrain3d-deformation` — introduce dirty-region terrain and collider updates without visibility churn.
4. `08-20-physics-informed-bucket-soil` — add the AGX-inspired dynamic parcel/cavity/settling loop on the stable foundations above.

The parent task owns cross-child acceptance and final Godot live integration. Each child is independently planned, implemented, verified, committed, and archived.
