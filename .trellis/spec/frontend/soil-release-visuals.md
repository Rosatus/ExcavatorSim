# Stable soil deposits and release visuals

## Product contract (2026-09-09)

The product is voxel-only. Cut → bucket ledger → stable repose-angle deposit → re-cut.
This replaces the earlier airborne/mobile/compaction/settle lifecycle.

`terrain_mass_delta_q + bucket_mass_q + discarded_cut_mass_q + exported_dump_mass_q == 0`.
`VoxelSoilMaterialField` stores one `stable_mass_q` per touched cell. Native and
redeposited soil use the same fixed material density and cutting path. There is
no mobile material, compaction density, flight escrow or periodic settlement.
Depositing invalidates cut coverage for touched cells so re-cut can credit soil.

Dump admission retains the opening gate and bounded 100 ms batch. Pending/queued
mass remains in the bucket. The current-SDF repose surface plan is staged, then
geometry and stable ledger are committed synchronously. Rejected deposits do not
debit stock; clipped deposits retain their remainder. Soil proposals accept only
`deposit`; the product queue is bounded FIFO. Cutting retains its scheduler priority.
Ledger mass is exact; voxel surface column geometry remains approximate.
Collision acknowledgement may lag the visible SDF by the engine rebuild interval.

GB12 cutting (2026-09-28): the attachment's `fill_profile_id=gb12_s50`, not
its host model ID, enables native swept occupancy and lift-exit cleanup.
Cutter and both synchronous/prepared authority gates share `uses_native_paths`.
Admission probes the full tooth and both side segments at voxel spacing; floor
lanes use radius-based spacing across the whole width, including when tilted.
Focused regressions cover isolated tooth/side remnants, tilted floor coverage,
and native transactions/preparation with GB12 on SY80U as well as SY135.

Boundary policy (2026-09-28): cut admission requires overlap with the finite
voxel volume, not containment of the full bucket sweep in inset editable bounds.
Cut windows and native raster buffers are clipped to semantic voxel ownership;
the hidden support apron and neighboring mesh geometry remain unchanged.
Outside the editable receiving region, normal confirmed open-mouth unloading
debits the bucket at the usual release rate into `exported_dump_mass_q` without
a terrain edit or stable-deposit visual event. Pending deposits are cancelled
before this debit. The export sink also accepts the final sub-voxel remainder;
stale identity and simple-digging gates still apply. In-zone deposit admission,
repose geometry, and rejected-deposit retention remain unchanged.

Simple digging (advanced settings opt-in, `ExcavationWorld.set_simple_digging_enabled`
-> `VoxelExcavationAuthority.set_dump_gate_enabled`) holds the dump gate closed:
no pose can open the gate or stage a deposit, and staged-but-uncommitted dumps
are cancelled on entry — contained soil can never leave the bucket. Cutting is
unchanged: geometry commits at any fill level and `stage_cut(..., allow_overflow)`
keeps clipping captured inventory to remaining capacity, routing the excess into
`discarded_cut_mass_q`, so a full bucket never blocks a cut. The flag survives
authority rebuilds (re-applied on configure) and re-enabling restores the normal
gate. This is a production mode, distinct from the test-only
`set_voxel_unlimited_bucket_for_testing` capacity override.

The option is a three-state scope on `ProductSession` (`simple_digging_mode`:
OFF / ALWAYS / ASSIST_ONLY; the legacy bool request maps on->ALWAYS). The
session recomputes the effective flag every physics tick — chassis-side assist
toggles (level assist key, slope preview Enter/Esc) bypass the session, so
polling is the only complete observation path — and pushes it to
`ExcavationWorld` only on change. ASSIST_ONLY counts level assist enabled or
slope mode ACTIVE; the slope PREVIEW phase does not drive the bucket, so the
gate stays open there. Legacy bool config values migrate to ALWAYS/OFF on load.

### Receiving surface (2026-09-18)

Route incoming material from the column below the release point over the current
SDF first-hit surface. A parcel can cross only an adjacent downhill edge whose
height difference reaches the repose slope. Otherwise it rests at that column
until its capacity is consumed. Each parcel starts at the source again, so the
updated surface can redirect subsequent material. A remote low pit cannot
receive material across an intervening ridge. Existing ground is never lowered.

The transaction-local solver uses bounded parcels (0.125 voxel volume) and a
bounded route-step budget. Only represented additions debit stock; work left by
a budget limit stays in the bucket. This is a discrete quasi-static surface
routing approximation, not a particle flight or continuous settling system.
Do not interpolate thickness from low pit samples onto higher rim samples, nor
allocate volume globally by absolute elevation without a traversable route.

A sampling perimeter is not a physical capacity limit. Start with a small
voxel-resolution domain and grow it when newly added soil reaches its border.
Do not use the minimum outer-ring height/cost as an upper bound on pile volume:
a low pit at that border falsely reports a full receiver and strands bucket
stock. Computational domain/staging limits still reject without debiting mass
and have distinct reasons. Work-zone ownership and protected-shell checks remain.

Surface scans batch-copy the current SDF and read signed-16 `[z][x][y]` samples;
height/gradient must match the scalar first-positive-to-nonpositive scan. Reuse
samples only while expanding one transaction, never across terrain revisions.
`soil_deposit_surface_test.gd` checks volume, repose, vertical-datum invariance,
supported rim accumulation, connected overflow, intervening ridges, domain
growth, batch/scalar parity, and stationary unloading
on a receiving surface captured from the failing recorded-input replay.

## Visual events

One immutable `voxel-soil-release-event-v1` is published after the deposit commits.
It includes `terrain_stable=true`, `release_committed=true`, process-local
`published_usec`, frozen source/landing transforms, mass, volume and emission duration.
There is no flight queue or delayed landing mutation. `release_changed` accompanies
the actual terrain commit. `SoilFlight` remains only a bounded decorative particle
trajectory helper; it owns no material and cannot trigger terrain edits.

`SoilEffects` consumes each ID once, rejects events older than their emission window,
and stops emission on its local TTL. Already emitted grains/clods retire under their
bounded visual lifetimes. VFX disabled/re-enabled must not replay consumed events.
Voxel mode must not use continuous-flow fallback or decorative ground mound meshes.
Reset clears presentation history. Fill/ground retain shared texture resources and
existing fill/pool/cadence budgets.

## Contained bucket fill

`SoilEffects` delegates mesh construction to `bucket_fill_surface.gd`:
`configure(model_id, cavity_size) -> bool`, `build_arrays(fill_ratio) -> Array`.
It consumes inventory only. The measured `sy135_bucket_fill_profile.json` and
`sy205_bucket_fill_profile.json` resources use `bucket-fill-profile-v1`, carry
the source GLB SHA-256 and cavity center/up, and store a 25×33 lining-height grid
in cavity-local coordinates. Heights are measured along `growth_direction_y`:
**SY135 -Y, SY205 +Y**. The proxy's `up_godot` is not a universal visual growth
direction, and `floor_wear_plate` is not an inner-surface marker.

A bounded volume estimate selects one rising soil level; deterministic relief
does not change seed with stock. Clip each sampled triangle where the surface
meets the lining; join the top and bottom there instead of creating a floating
box or rectangular skirt. Shared edge intersections use canonical endpoint
order, and Godot clockwise winding must agree with the supplied outward normals.
At most 2 mm of internal contact overlap hides seams. The volume is a visual
approximation and never recalibrates nominal bucket capacity or ledger mass.

Keep the existing 10 Hz rebuild gate, 5% stock quantum, ArrayMesh reuse and local
triplanar soil textures. First positive sub-quantum stock must still create a
thin layer. Empty/invalid snapshots hide fill and invalidate first-fill state;
model changes rebuild with that model's profile. Unknown named models fail
closed; only anonymous compatibility/test snapshots use the generic bowl.

`BucketVisualMaterials.apply()` duplicates the original SY135 bucket surface
material per activated instance, replacing its near-black untextured paint with
rough dark steel. SY205 keeps its original atlas. Do not mutate imported/shared
resources or use self-illumination to disguise black lining. `VisualEnvironment`
keeps contact-scale SSAO (0.4 m / intensity 0.8), existing exposure and profile
enable/disable behavior; it does not add a bucket light.

Focused checks: `bucket_fill_surface_test.gd` covers source hash, independent
imported-mesh ray contacts, closed clockwise solids, low stock, monotonic volume,
determinism, invalidation and material isolation; `model_switch_test.gd` covers
the real material activation hook; existing soil-effects and visual-pass tests
cover cadence, resource reuse and quality restoration. Appearance remains a
human Forward+ check under `validation-budget.md`.

## Rigid fill attachment and surface orientation

### Scope / trigger
Contained fill must move with the rendered bucket, including between physics
samples. A 30 Hz soil snapshot must never throttle rigid attachment transforms.

### Signatures
- `MotionPresentation.get_soil_proxy_local_transform(proxy_name) -> Transform3D`
  shares the validated local proxy transform with world sampling.
- `MotionPresentation.model_replacing` fires before the candidate becomes active,
  including candidates whose mapping validation fails.
- Optional `body_opening_rim_cavity_local` contains four measured body mouth
  corners, excluding teeth. SY135 uses these to define its free-surface plane;
  profiles without them retain the existing deterministic mound relief.

### Contracts
SoilEffects owns the fill resource but parents the node to the active cavity
frame. Use the contract-local transform; never reconstruct it from an older
world pose. Bound fill ignores snapshot world transforms. Inventory retains
30 Hz polling and 10 Hz / 5% geometry rebuilds.
Before replacement or reset, hide and reparent fill to SoilEffects. Failed
candidates also leave it parked. Mismatched-model snapshots hide fill. Effects
teardown frees its externally parented node; model-first teardown guards freed
references and preserves ArrayMesh reuse. Only isolated consumers without a
presentation use explicit world poses; losing a bound presentation fails closed.
SY135 uses unchanged-source bucket vertices 60/64/68/71: the body cutting lip
and opposite rim. Tooth tips 74/83 are excluded. The resulting cavity-local
outward normal is (0,-0.8046611205,0.5937343524), with 36.422459 degrees of
inclination from cavity XZ. The semantic opening proxy is not the visual rim.
Derive the plane equation from these corners; normals, volume inversion and
mesh use the same slope. Full stock sits 65 mm inside this plane along its
normal. Stock changes plane offset, not orientation. Preserve measured lining
heights and attachment transforms; synthetic dry/missing-ray profile samples
sit 40 mm outside the body mouth plane at each sample's Z to close the solid.
Only those synthetic samples change from the old constant -0.04 boundary.
The earlier arbitrary 6-degree tilt and proxy-parallel plane were superseded;
their runtime options and tests are removed. SY135 retains texture/color soil
detail on a planar top. SY205 retains its existing relief and profile bytes.
Visual full volume may change; ledger capacity does not.

SY135 fill containment uses a one-cell maximum envelope of the measured lining
and a 3 mm inward clearance. This prevents interpolated fill triangles from
bridging sharp shell transitions; do not push its underside outward for contact.
The baked measurements and body-mouth plane stay unchanged. Check generated
face corners, edge midpoints and centroids against imported bucket triangles
from low stock through full stock, not only against the baked sample points.

### Validation / error matrix
| Condition | Expected |
|---|---|
| Fixed stock, moving bucket, no snapshots | Rigid local attachment, no rebuild |
| Old world pose | No pullback |
| Wrong model snapshot | Hidden fill |
| Replacement succeeds or contract fails | Reclaim attachment before asset removal |
| Empty/reset | Hidden; reset parks and invalidates geometry |
| Effects-first or model-first teardown | No node leak or freed-reference access |

### Good / base / bad cases
Good: hierarchy drives pose, inventory drives geometry.
Base: isolated tests explicitly provide world transforms.
Bad: increasing poll Hz or adding lerp to hide independent pose sampling.

### Tests required
`bucket_fill_follow_test.gd`: two real models, between-tick ancestor/bucket
motion without fresh snapshots, old model/world snapshots, unchanged rebuild
count, reset/refill, failed candidate recovery and both teardown orders.
`bucket_fill_surface_test.gd`: SY135 coplanarity and body-mouth normal alignment,
imported rim anchors (2 mm import tolerance), rim clearance, lining contact,
closure, monotonic growth, determinism and unchanged SY205 relief.
`model_switch_test.gd`: proxy-transform refactor retains frame parity.

### Wrong vs correct
Wrong: update fill world pose only in a 30 Hz inventory callback.
Correct: fixed cavity-local transform under the rendered bucket frame.

## GB12 attachment soil (2026-09-18)

The attachment contract keeps the host `model_id` for authority identity and
adds optional `fill_profile_id: gb12_s50` for visual geometry. SoilEffects selects
and invalidates by both identities; attachment changes hide the old fill and
stale snapshots from a different profile cannot bind to the new tool.
The mesh remains rigidly parented under GB12_ROOT's contract-local cavity.

`tools/bake_bucket_soil.gd` consumes `gb12_s50_soil_bake.json`, measures the
imported GB12 GLB, updates its soil contract and catalog hash, and bakes the
independent lining profile. `--check` detects drift without writing;
`tools/preview_bucket_soil.gd` renders three stock levels from the same recipe.
The actual mouth joins the lip top to the crown beam's front underside; the
rolled bowl's rear edge lies under the covered mounting crown and is not the
outlet rim. The measured normal is approximately (0, 0.538754, 0.842463).
Use the maximum triangle height across each grid footprint so narrow internal
gussets cannot disappear between rays. The runtime lining envelope and 65 mm
mouth clearance keep the stock surface contained. Nominal ledger capacity is
unchanged; the visual volume is approximate.

Optional `interaction.release_opening_down_dot` overrides the runtime's default
0.5 gate floor, still bounded below by the contract dump threshold and the
shared 0.15 minimum. GB12 uses 0.15 (mouth normal 8.63 degrees below horizontal).
Its world normal includes host articulation, XTR13 tilt and rotation. Standard
buckets omit the field and retain 0.5. Confirmation, cutting/obstruction guards,
pending-mass ownership and committed deposit accounting remain shared.
`gb12_soil_test.gd` checks source geometry, fill containment, lifecycle and
48 compound poses; `gb12_soil_dump_test.gd` checks shallow-angle release,
closed-mouth retention and mass conservation on voxel terrain.

### Reusable attachment geometry

New soil-holding attachments supply optional `soil_geometry` using
`bucket-soil-geometry-v1`: `mouth_polygon_godot`, `cavity_depth_m`,
`fill_profile_path`/`fill_profile_sha256`, and `source_glb_path`/`source_glb_sha256`.
The polygon is the one authoritative tool-local opening. Its first edge defines
width and its right-hand normal points out. Only a single convex planar mouth
(3–32 points) and a height-field lining are supported. Unsupported shapes fail
validation; the baker does not infer multiple outlets or articulated cavities.

`bucket_soil_geometry.gd` derives the mouth/cavity frames and validates generated
proxy/semantic projections, source identity and fill profile provenance. The
attachment loader also matches that source to the tool GLB in the catalog.
`BucketSoilTool` samples the actual opening polygon and uses the shared cavity
frame. `MotionPresentation` supplies that same frame to fill and world poses;
`bucket_soil_release.gd` uses the opening frame's +Y for geometry-backed tools.
The authority still owns confirmation/obstruction and all ledger transactions.

`BucketFillSurface.configure_contract` loads the pinned profile directly; new
tool IDs must not be added to `PROFILE_PATHS` (native compatibility only).
Generated profiles dry samples outside the mouth and clip interpolated faces
to its polygon. `bucket_soil_geometry_test.gd` verifies arbitrary rotated mouth
frames, invalid polygons/provenance, stale state and a new unregistered ID.
`tools/tests/bucket_soil_bake_test.gd` checks deterministic in-memory baking and
failure without writes for stale sources, missing meshes, moved/crossed anchors
and output/input aliases. Adaptation procedure lives in the attachment skill's
`references/contained-soil-adaptation.md`; do not duplicate tool-specific bake code.

## Mode retirement

Only `voxel` / `voxel_bucket_v1` are selectable. Old serialized requests normalize
at a clean generation boundary. Initialization/runtime failure pauses the voxel
writer and never selects legacy. Legacy heightfield classes remain source-only
compatibility dependencies; they are not a product fallback. Loose flux solver
and its dedicated tests were removed.

## Human validation

The user owns execution of tests and visual/runtime review for this migration.
Updated test sources cover stable deposit/re-cut conservation, pending and rejected
inventory, mode retirement, direct terrain publication, idle geometry stability,
VFX expiry and stale-event rejection. Check both SY135 and SY205 dumping, repeated
pile growth, driving over piles and re-digging; do not infer visual quality from
ledger conservation. Restart/reset the scene after migration; no live old ledger
conversion or persisted save migration is provided.
