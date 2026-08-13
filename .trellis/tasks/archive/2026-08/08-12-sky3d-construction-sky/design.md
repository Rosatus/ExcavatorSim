# Design — Sky3D construction-sky environment

## Architecture and boundaries

Sky3D must fit inside the existing presentation boundary:

```text
Python motion/lifecycle authority
  -> existing main scene
     -> project-owned visual layer
        -> WorldEnvironment / key light / quality profile
        -> optional Sky3D-backed sky-atmosphere implementation
```

The integration may not create a second authority for time, simulation cadence,
terrain, motion, or bucket state. If Sky3D is adopted, it remains a visual
backend owned by project code, not a free-standing scene contract.

## Chosen integration

Choose option 1: a project wrapper over the full Sky3D environment. The root
node keeps the stable name `WorldEnvironment` and remains a
`WorldEnvironment` subtype by attaching `Sky3D.gd`. `VisualEnvironment` owns
the fixed-day/profile policy; Sky3D owns its shader, environment, SunLight,
MoonLight, SkyDome, and TimeOfDay implementation.

The existing `KeyLight` remains present and disabled so structural consumers do
not break. `VisualQualityController` continues delegating environment profiles
to `VisualEnvironment` and stops treating `KeyLight` as the active sun.

Terrain3D's optional infinite world background is disabled because its generated
cliff shell obscures the entire Sky3D horizon. The local 64 m Terrain3D site,
materials, dressing, and logical terrain seam remain unchanged.

Sky3D is configured to 10:30 using `TimeOfDay.CelestialMode.SIMPLE`, producing a
19.5-degree SkyDome polar angle (about 70.5 degrees solar elevation), with
`editor_time_enabled=false`, `game_time_enabled=false`, `system_sync=false`, and
zero cloud wind. Low disables clouds/fog; balanced enables restrained
clouds/fog; high enables the same features with stronger sky quality. No profile
changes target FPS, terrain/motion cadence, or authority state. Quality-profile
failure propagates to `VisualQualityController` instead of being reported as a
successful partial application.

Production directly uses the addon implementation and required assets. It does
not instantiate Sky3D demo scenes. NOTICE/provenance includes Sky3D MIT, GPoSM
moon MIT, and ESO/S. Brunier Milky Way CC BY 4.0 attribution; the running UI also
shows the required Milky Way credit to all users.

Terrain3D native initialization observes assets/material before enter-tree, but
its `region_size=128` and collision mask are applied after enter-tree because
Terrain3D 1.0.2 restores scalar defaults while initializing. Native activation
hides both fallback ground layers, and queued/failed native work restores them.

## Rejected alternatives

- Selective shader copying is rejected because it forks a tightly coupled
  sky/sun/fog/time implementation and increases maintenance drift.
- An isolated prototype is rejected because local audit confirms the root
  subtype is structurally compatible and requirements already approve rollout.
- Leaving the existing procedural sky is rejected because it does not meet the
  requested atmosphere/cloud quality.

## Considered options

1. **Project wrapper over Sky3D**
   - Keep a project-owned seam such as `VisualEnvironment`.
   - Instantiate/configure Sky3D or parts of it beneath that wrapper.
   - Preserve current quality/profile control and status reporting.

2. **Selective borrowing**
   - Reuse or port the parts that materially help the project, such as sky
     shading, horizon treatment, fog/cloud tuning, or light calibration ideas.
   - Keep the existing `WorldEnvironment` + `KeyLight` structure.

3. **Isolated prototype**
   - Build a non-production test scene to measure fit, visual value, and
     performance before touching the main scene.

The option list records the evaluated alternatives; the project-wrapper option
above is authoritative.

## Compatibility constraints

- Existing tests currently anchor to root-level `WorldEnvironment`,
  `KeyLight`, `VisualEnvironment`, and `VisualQualityController`.
- Current visual quality logic already owns shadow/far-plane/effect budgets.
- Sky3D's own time, light, and fog stack is broader than the present need, so
  any adopted subset must be intentionally bounded.

## Validation shape

The plan should define:
- scene-node contract and ownership,
- profile mapping (`low/balanced/high`),
- whether the scene stays fixed daytime or supports controlled time-of-day,
- provenance/licensing footprint,
- fallback behavior when the addon is absent or disabled.

The addon is a vendored production dependency, so missing resources are an
import/verification failure rather than a runtime protocol fallback. Existing
terrain, motion, and renderer fail-open seams are unaffected.
