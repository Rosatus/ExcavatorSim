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

## Integration options

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

The design task should choose one of these and reject the others explicitly.

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

