# Phase 3 authority/collider evidence

## Deterministic A/B gate

Command:

```powershell
& godot/client/tests/run_terrain3d_authority_equivalence.ps1 `
  -OutputDir E:\projects\ExcavatorSim\output\terrain3d_phase3\final
```

Result: `run-summary.json` reports `passed=true`, test exit code `0`.

The runner executes the same startup, active cut, carry, 240-tick dump/settle,
Jolt settle/drive/articulation/brake, real bucket contact sweep, Test Grid,
reset, native failure and recovery sequence under `soil_shader` and `terrain3d`
for SY205 and SY135. A main-scene A/B sequence separately verifies
start/pause, SY205→SY135 model switch, and reset.

| Model | Final surface SHA-256 | Final ledger SHA-256 | Project-collider track samples |
|---|---|---|---:|
| SY205 | `2231bf9222f7c1aa29028119c6de3891ee80a21fa6fb909d5b3fed05ca6ca5dc` | `7281185757d3cff9102ea10584bc07051dab76b69afe66643dcf07fd49fea9ff` | 1792/backend |
| SY135 | `421c8fbd75c46c5e766d35018292dec20fac9e94168c646d562c092c938fd5eb` | `a79fb048c7bf4eb3f382a9f58f89bb136781ea22ea7bb1405caccc33ed0e9454` | 1792/backend |

For each model, native and fallback stable/loose arrays, surface bytes, terrain
identity, ledger journal, payload, accepted chassis/articulation snapshots and
reset identities compare equal. Native readback reports collision mode `0` and
layer `0` at every checkpoint.

## Supporting regression gates

Passed on Godot 4.7.1/Jolt:

- `jolt_bucket_query_spike.gd`
- `bucket_shallow_overlap_test.gd`
- `jolt_chassis_track_test.gd`
- `soil_interaction_authority_test.gd` (including the 20-cycle scenarios)
- `terrain3d_adapter_test.gd`
- `terrain_state_test.gd`
- `construction_site_terrain_test.gd`
- `model_switch_test.gd`
- `release_candidate_test.gd`

Accepted bucket contacts now assert `query_source="terrain_collider"`; accepted
track contacts expose only `terrain_collider` or the logical
`terrain_state_fallback`. The evidence is a Phase 4 cutover prerequisite, not a
visual-quality claim.

The full `run_standalone_matrix.ps1` was also attempted. All tests through
`sensor_telemetry_test.gd` passed, then the pre-existing environment-dependent
`can_gateway_e2e_test.gd` stopped the matrix because the Gateway process exited
before its first heartbeat. This is the same out-of-scope baseline stop seen in
Phase 2; no Gateway files are changed here. Every terrain/Jolt/soil/model test
after that matrix position was run directly in the focused list above.
