# Implementation plan

1. [x] Audit current visual-scene contract, Sky3D capabilities, and the exact
   structural conflicts between them.
2. [x] Decide the integration shape: full wrapper, partial borrowing, isolated
   prototype, or rejection.
3. [x] Define the production scene contract, quality-profile mapping, and addon
   enablement/fallback behavior.
4. [x] Record licensing/provenance scope for any shipped Sky3D assets.
5. [x] Produce implementation-ready acceptance criteria and validation commands
   for the eventual coding phase.
6. [x] Integrate Sky3D through `VisualEnvironment` and the stable main-scene
   node paths.
7. [x] Map low/balanced/high profiles to fixed-day Sky3D settings and add
   regression coverage.
8. [x] Update NOTICE, integration docs, and frontend boundary contracts.
9. [x] Run focused Godot checks, the nine-script standalone matrix, and a real
   Forward+ visual/log smoke.
10. [x] Complete `pixi run verify`; the final run passed ruff, mypy, all 145
    backend tests, provenance verification, and standalone-path verification.
    Two earlier runs exposed an existing flaky backend reset/terrain hash race
    without requiring any Godot/Sky3D or backend semantic change.

## Scope guard

- No demo-scene splice into main.tscn.
- No change to motion authority, terrain authority, or bucket semantics.
