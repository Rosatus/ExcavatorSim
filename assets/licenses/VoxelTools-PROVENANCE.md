# Voxel Tools build-toolchain provenance

- Upstream: https://github.com/Zylann/godot_voxel
- Release: https://github.com/Zylann/godot_voxel/releases/tag/v1.7
- Voxel Tools version/tag: 1.7 / `v1.7`
- Voxel Tools release commit: `2ac9f5f`
- Godot custom build: `4.7.2.stable.custom_build.ed1daf0bf`
- Godot engine commit: `ed1daf0bf`
- License: MIT (`VoxelTools-LICENSE.txt`)
- Integration role: native engine module included in the pinned editor and
  Windows/Linux release templates

ExcavatorSim Phase 1 only validates that `VoxelTerrain` and `VoxelLodTerrain`
are registered and instantiable. The product scene does not create Voxel Tools
terrain, storage, generators, viewers, collision, or data. TerrainState remains
the logical terrain authority, Terrain3D remains the presentation backend, and
Jolt/TerrainCollider retain their existing collision responsibilities.

The exact upstream asset names and archive/binary SHA-256 values used for a
build are locked in `tools/godot_voxel_toolchain.json` and copied into each
Godot package's `build-manifest.json` under `build_toolchain`.
