# Stable soil deposits and release visuals

## Product contract (2026-09-09)

The product is voxel-only. Cut → bucket ledger → stable repose-angle deposit → re-cut.
This replaces the earlier airborne/mobile/compaction/settle lifecycle.

`terrain_mass_delta_q + bucket_mass_q + discarded_cut_mass_q == 0`.
`VoxelSoilMaterialField` stores one `stable_mass_q` per touched cell. Native and
redeposited soil use the same fixed material density and cutting path. There is
no mobile material, compaction density, flight escrow or periodic settlement.
Depositing invalidates cut coverage for touched cells so re-cut can credit soil.

Dump admission retains the opening gate and bounded 100 ms batch. Pending/queued
mass remains in the bucket. The current-SDF repose surface plan is staged, then
geometry and stable ledger are committed synchronously. Rejected deposits do not
debit stock; clipped deposits retain their remainder. Soil proposals accept only
`deposit`; the product queue is bounded FIFO. Cutting retains its scheduler priority.
Ledger mass is exact; coarse surface column geometry remains approximate.
Collision acknowledgement may lag the visible SDF by the engine rebuild interval.

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

## Rigid fill attachment and forward tilt

### Scope / trigger
Contained fill must move with the rendered bucket, including between physics
samples. A 30 Hz soil snapshot must never throttle rigid attachment transforms.

### Signatures
- `MotionPresentation.get_soil_proxy_local_transform(proxy_name) -> Transform3D`
  shares the validated local proxy transform with world sampling.
- `MotionPresentation.model_replacing` fires before the candidate becomes active,
  including candidates whose mapping validation fails.
- Optional profile `surface_forward_tilt_degrees` defaults to 0; SY135 starts at 6.

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
Forward cavity -Z receives tan(angle)*(z_mid-z) in relief. Normals, volume
inversion and mesh share it. Reserve abs(tan(angle))*z_span/2 below the prior
full level for dry-rim closure. Do not tilt the lining or imported transforms.
Visual full volume may change; ledger capacity does not. SY205 keeps zero tilt.

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
`bucket_fill_surface_test.gd`: forward trend, rim cap, contact, closure,
monotonic growth, determinism and zero SY205 slope.
`model_switch_test.gd`: proxy-transform refactor retains frame parity.

### Wrong vs correct
Wrong: update fill world pose only in a 30 Hz inventory callback.
Correct: fixed cavity-local transform under the rendered bucket frame.

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
