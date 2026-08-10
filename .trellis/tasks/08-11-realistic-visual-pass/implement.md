# Implementation plan

1. [x] Add `VisualEnvironment` and `CameraRig`; attach realistic Forward+
   environment, shadows, camera follow and soil PBR defaults.
2. [x] Add `VisualQualityController` with high/balanced/low budgets and a
   read-only status seam.
3. [x] Add bounded generation-gated `SoilEffects` and connect it to local
   excavation results without touching authority state.
4. [x] Add a headless visual smoke test and MCP scene/UI inspection; verify
   imported GLB frame parity remains unchanged.
5. [x] Run `pixi run verify`, review docs/manifests, archive M6 and journal it.

Exit gate: [x]

## Scope guard

No GLB byte edits, Python protocol changes, local physics authority, replay,
per-grain rigid bodies, unbounded particles or wall-clock simulation timing.
