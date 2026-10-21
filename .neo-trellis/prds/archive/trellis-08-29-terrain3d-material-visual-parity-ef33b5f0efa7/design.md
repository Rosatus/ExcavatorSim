# Design — Terrain3D procedural soil material

Separate the Terrain3D-required vertex/region machinery from a project-owned
fragment/PBR module. The module uses world position and terrain normal to
reproduce the existing fallback classifications without demo texture arrays.
Maintain one reviewed constants source or parity fixture for both shaders.

Replace unconditional `_add_demo_particles()` and native rock construction with
explicit product dressing flags whose production values are false. Generate a
single bare-ground control role or make the override independent of texture IDs.
Keep `world_background=NONE` and the sibling construction-site dressing visible.

Use a fixed screenshot checkpoint for subjective review, backed by executable
status/assertion tests for all objective exclusions.
