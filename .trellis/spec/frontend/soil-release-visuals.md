# Soil Release and Visual Resources

## Scope / Trigger

Voxel unloading, airborne mass, ground arrival scheduling, and soil appearance.

## Signatures

- `VoxelSoilMaterialField.release_to_flight(mass_q: int) -> bool`
- `VoxelSoilMaterialField.return_from_flight(mass_q: int) -> bool`
- `SoilFlight.duration(release: Vector3, landing: Vector3) -> float`
- `VoxelExcavationAuthority.step_fixed(delta)` returns `release_changed` separately from terrain `changed`.
- `soil_visual_resources.gd` supplies `surface_material(world_coordinates)`, cached `clod_mesh(size, variant)`, and `dust_texture()`.

## Contracts

`terrain_mass_delta_q + bucket_mass_q + in_flight_mass_q + discarded_cut_mass_q == 0`.
Only the material field owns these accounts. Capture capacity reserves space for in-flight returns. Bucket fill/payload represents retained bucket mass alone.

The authority holds at most 48 flights and emits at most one release event per step; estimated fall time over 4 seconds cannot release. Arrival uses 5.5 m/s² gravity, 0.7 m/s initial downward speed and half the 100 ms emission period. `release_changed` triggers an immediate world snapshot signal, without pretending terrain changed. Ground arrival reuses the surface executor's current-SDF scan and cutting keeps scheduling priority.

During synchronous landing resolution, escrow returns to bucket stock immediately before normal deposit staging/commit. Unrepresented or rejected mass remains in the bucket. This can visibly restore fill after a failed landing; it must never disappear. `clear` retires flights and their escrow; reconfigure resets generation accounts.

The release event retains the existing v1 envelope and adds `flight_duration_s` and `release_committed`. For these events, short frozen-source emission survives subsequent gate closure, while landing publishes no new release. Predicted endpoints are not retargeted if terrain changes in flight; the actual ground deposit always uses current terrain. This is a bounded visual approximation, not per-grain collision simulation.

The authority and world visual snapshots forward `flight_queue_depth` and `in_flight_mass_q`. Transition from nonzero flight depth to zero explicitly clears GPU flow and pooled clods once; no final tail survives beyond observed authoritative completion. Consume completed event IDs without emission when subscribing after landing. Voxel mode never uses the legacy `interaction_state + flow_volume_m3` fallback. `amount_ratio` scales down to zero, without a minimum visual amplification. Stock below 0.01 voxel of loose volume remains in the bucket ledger instead of endlessly relaunching failed/partial sub-visual deposits.

Ground/fill share Ground037 albedo and normal/roughness textures. Ground uses world triplanar projection; moving fill uses object triplanar projection. Roughness uses the normal texture's alpha. Grains/clods use cached 32-triangle irregular meshes with vertex color; dust uses a cached soft alpha mask. Preserve existing particle, pool, and fill rebuild budgets.

## Validation & Error Matrix

| Condition | Required result |
| --- | --- |
| Invalid/excess release mass | No account mutation |
| Gate closes before release | Cancel pending batch |
| Gate closes after release | Flight still lands |
| Landing fails or clips | No lost mass; remainder stays in bucket |
| Reset | No surviving flights or replay |
| Background settle pending at arrival | At most one terrain transaction; never overwrite landing journal row |
| VFX disabled and re-enabled | No replay of consumed release |
| Bucket retains sub-visual SDF residue | No repeated flight; mass stays accounted |
| Last flight retires | Clear GPU tail and clod pool once |
| Late subscriber sees completed event | Consume ID without emitting |

## Good / Base / Bad Cases

Good: high dump emits while ground waits, then one supported SDF deposit. Base: idle produces neither flow nor terrain writes. Bad: using a visual timer to debit inventory or hiding a permanent independent mound over authoritative terrain.

## Tests Required

`soil_release_visual_quality_test.gd`: release before SDF, gate-independent arrival, failure return, reset, foreground transaction ownership, resource reuse, triplanar mapping, soft dust, TTL and toggle replay. `voxel_soil_material_field_test.gd` and `voxel_excavation_world_test.gd` retain ledger/integration coverage. Cutting performance regression remains separate from GPU/material aesthetics.

`soil_dump_completion_test.gd` must run continuous downward admission long enough to exhaust inventory and drain flights. Assert no tail releases, no flow/clods, retained residue below the representation threshold, conservation, no stale fallback or late-subscriber replay, and proportionate small-release intensity. World integration asserts forwarding of completion fields. A TTL-only test cannot detect repeated tiny release IDs or surviving clods.

## Wrong vs Correct

Wrong: commit ground immediately, then launch falling particles. Correct: commit release into flight stock, then publish ground at scheduled arrival under the same authority. Headless success validates state contracts; visual quality remains human review.
