# Toolchain and Migration Evidence

## Observed local toolchain

Root: `E:/applications/godot_voxel`

| Binary | SHA-256 | `--version` |
|---|---|---|
| `godot.windows.editor.x86_64.exe` | `4AA32DE020EF9AEA9FD9BF5A3A22FA72BB55DB3DAC6BD1CF8AC45B775D7749C3` | `4.7.2.stable.custom_build.ed1daf0bf` |
| `godot.windows.template_release.x86_64.exe` | `21229489A7078EABF26E910044EC2DEFE19FCD49143DF6E8C545948515D98D8C` | `4.7.2.stable.custom_build.ed1daf0bf` |
| `godot.linuxbsd.editor.x86_64` | `BBEC8C1C5AF9C61B6ACBDFC85214404CA3037D0758DC567D0C4A2C68E475453F` | `4.7.2.stable.custom_build.ed1daf0bf` (WSL) |
| `godot.linuxbsd.template_release.x86_64` | `EB21C5D7B85D281DB68C3B315237C6E6CEACF65067C7E5C595B2B94AA3E40B7E` | `4.7.2.stable.custom_build.ed1daf0bf` (WSL) |

Godot AI MCP session `client@27d6` reported `Godot 4.7.2-stable (custom_build)`, project `ExcavatorSim`, `res://scenes/main.tscn`, readiness `ready`. ClassDB reported `VoxelTerrain`, `VoxelLodTerrain`, and `Terrain3D` as instantiable. Editor logs contained only four existing Terrain3D demo texture UID duplicate warnings.

## Official upstream release

- Release: `https://github.com/Zylann/godot_voxel/releases/tag/v1.7`
- Voxel Tools tag: `v1.7`
- Release commit: `2ac9f5f`
- Engine identity: Godot `4.7.2.stable.custom_build`, engine commit `ed1daf0bf`

Official GitHub asset zip digests:

| Asset | SHA-256 |
|---|---|
| `godot.windows.editor.x86_64.exe.zip` | `e2292adb0b671508ab220fce5bcd052b1c20674a3385d89c6b38601e6e1f956b` |
| `godot.windows.template_release.x86_64.exe.zip` | `86fe371ed80948ccb4b4ac78a0e62e2917bc257890bdaa62b4f6e7aa402f0775` |
| `godot.linuxbsd.editor.x86_64.zip` | `35c92e9f2209d1edbf6ebd57dfa52af060ec5d9ee2aade105a084e5911415dea` |
| `godot.linuxbsd.template_release.x86_64.zip` | `d26c2ddfca6bb8323c1380bc0cc8322405db1f7ef359df23dd97664fad4366ec` |

The release provides ordinary release templates only. `double` has no matching export templates; `tracy` is profiling-only. The Module and GDExtension editions must not be enabled together because their registered classes conflict.

## Current repository anchors

- `godot/client/project.godot`: Godot 4.7 feature, Forward+, D3D12, Jolt, Terrain3D enabled, `jolt_authoritative`.
- `tools/build_release_dist.ps1`: current single Windows/Linux release entry, staging/atomic replacement, Gateway integration, Terrain3D binary hashes and manifests.
- `godot/client/export_presets.cfg`: Windows/Linux x86_64 release presets; custom release/debug templates currently empty.
- `backend/scripts/jolt_product_soak.py` and Terrain3D PowerShell launchers: current active 4.7.1 Mono fallback references.
- `.trellis/spec/frontend/validation-budget.md`: stable-then-once heavy validation and human-owned visual review.

## Historical decision recovered by `trellis mem`

Past release-chain inspection established that `tools/build_release_dist.ps1` is the only full dual-platform entry: it rebuilds both Gateways, exports both Godot presets, stages manifests/notices, normalizes Linux permissions, creates `ExcavatorSim-linux-x86_64.tar.gz`, and atomically replaces `godot/dist`. This migration extends that entry rather than creating a parallel release pipeline.
