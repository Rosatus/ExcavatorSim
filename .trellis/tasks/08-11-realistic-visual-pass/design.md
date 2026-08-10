# Design — realistic visual pass

## Presentation nodes

`VisualEnvironment` owns an `Environment` resource created at runtime when the
scene's `WorldEnvironment` is empty. It uses a procedural sky, neutral warm key
light, ambient sky contribution, ACES-like tonemapping and restrained fog. The
GLB remains the single visual asset source. `TerrainRenderer` gets a rough,
non-metallic soil `StandardMaterial3D` only when no material override exists.

`CameraRig` follows the imported `CTRL_EXCAVATOR_ROOT` with bounded orbit,
distance and height. Mouse drag/wheel are presentation input; interpolation and
look-at never feed back into MotionClient or any local authority state.

`VisualQualityController` applies named budgets: particle amount, shadow
quality and camera far distance. It rejects unknown profiles and reports a
snapshot for UI/tests. The default `balanced` profile is safe for 1920×1080 at
the 60 FPS target; `low` remains a graceful fallback for weaker hardware.

## Soil effects

`SoilEffects` creates one `GPUParticles3D` emitter with a fixed upper bound and
a small sphere draw pass. It listens to `ExcavationWorld.excavation_changed`,
uses only the result volume/generation, restarts on accepted edits, and clears
on generation changes. Missing GPU particles or a disabled effect leaves the
world fully usable. The effect is disposable and cannot mutate `TerrainState`.
