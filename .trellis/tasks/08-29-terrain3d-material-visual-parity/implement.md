# Implementation plan — Terrain3D visual parity

1. Capture fallback shader constants/functions and baseline checkpoint.
2. Create the Terrain3D-compatible project shader/material resource.
3. Port procedural soil PBR calculations while retaining native vertex logic.
4. Remove/gate demo texture zones, grass particles, rocks, trees, and background.
5. Add status fields and tests for material identity and dressing exclusions.
6. Run Forward+ native/fallback checkpoint captures and deformation samples.
7. Run terrain-state, construction-site, visual, and repository checks.
8. Obtain focused human visual acceptance and document tolerated LOD/normal
   differences for Phase 2.

No product default switch is allowed in this phase.
