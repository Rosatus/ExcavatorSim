# Phase 1 validation evidence

## Selected foundation configuration

- Godot: `4.7.2.stable.custom_build.ed1daf0bf`
- Voxel Tools: `1.7`
- Terrain: bounded `VoxelTerrain`, `VoxelGeneratorFlat`,
  `VoxelMesherTransvoxel`, smooth 16-bit SDF
- Product scale: `0.125 m` per voxel
- Mesh block: 16 voxels
- Local bounds: `256 x 80 x 256`; world bounds
  `X=[-16,16), Y=[-6,4), Z=[8,40)`
- Viewers: one full-zone visual/collision viewer and one chassis-local
  collision-priority viewer

The `0.125 m` candidate stays selected because it passes the foundation budgets
and preserves substantially more bucket-edge detail than the `0.20 m`
candidate. The coarser candidate remains a measured fallback, not an automatic
runtime quality mode.

## Stable focused run

Command:

```powershell
.\godot\client\tests\run_voxel_work_zone_foundation_probe.ps1
```

Passing artifact:
`output/voxel_foundation/20260902-233223/run-summary.json` (local, gitignored).

| Measurement | 0.125 m | 0.20 m | Budget |
|---|---:|---:|---:|
| Initial mesh/collision ready | 14 frames | 4 frames | <= 60 frames |
| Connected 4 m path edit | 119 us | 45 us | <= 2,000 us |
| Changed-geometry Jolt acknowledgement | 34,381 us | 34,461 us | <= 250,000 us |
| Changed ray height | -1.100 m | -1.100 m | below -0.65 m |
| Dropped load/mesh blocks | 0 | 0 | 0 |
| Static-memory observation | 61.99 -> 95.05 MB | 86.66 -> 90.00 MB | diagnostic only |

Headless `Performance.TIME_PROCESS` and `TIME_PHYSICS_PROCESS` reported zero in
this standalone runner, so they are recorded as unavailable rather than used to
claim visual frame time. The bounded synchronous edit and asynchronous
collision budgets above are the Agent-owned foundation gates; sustained
Forward+ smoothness remains human-owned.

The same run passed:

- half-open coordinate and protected-shell contracts;
- per-region latest-ticket readiness and reset stale-ticket rejection;
- exact Terrain3D control-hole/fallback-mesh/project-collider ownership parity;
- main-scene zone/boundary composition and exclusive hard/voxel Jolt ray hits;
- deterministic construction-site layout after relocating conflicting cues.

## Release-template boundary

The runner verifies the pinned Windows release-template path/hash through the
repository toolchain resolver. The upstream template is compiled with
`disable_path_overrides=yes`, so it cannot execute a source project directly;
runtime instantiation requires an exported PCK. Per the approved goal, no
release package is built in this phase. `voxel_module_export_smoke.gd` now
instantiates the runtime work zone and will exercise that contract during the
next explicitly requested distribution build.

## Human review

On 2026-09-03 the user explicitly accepted the Phase 1 Forward+ foundation
review, covering layout, material family, seam readability, entrance
clearance, pristine traversal feel, reset behavior and sustained subjective
smoothness. Digging behavior was intentionally outside this phase.
