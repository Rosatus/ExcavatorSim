# Implementation plan

1. [x] Audit current Terrain3D runtime/demo asset coupling and Terrain3D 1.0.2
   runtime control-map APIs.
2. [x] Define a 64 m construction-site layout and four-role material palette.
3. [x] Add a project-owned construction-site profile that creates deterministic
   height/control maps and Terrain3D texture assets.
4. [x] Update `Terrain3DAdapter` to consume the project profile and keep only
   the official demo texture/rock assets required at runtime.
5. [x] Add regression coverage for logical-patch parity, control-map zoning,
   project-owned asset selection, and existing authority/collision contracts.
6. [x] Update docs/provenance and run focused plus full Godot verification.
7. [x] Replace the custom visual pass with the official Terrain3D demo baseline.
8. [x] Add a flat logical pad, bounded official rocks, and central grass exclusion.
9. [x] Run full Godot, project, and final visual verification.

## Scope guard

- No change to logical terrain authority, bucket semantics, or Python protocol.
- No buildings or unrelated set dressing.
