# Realistic visual pass

## Goal

Make the imported SY205 client read as a restrained, realistic Windows Forward+
scene while keeping all motion, terrain and bucket state contracts unchanged.

## Requirements

- Configure a physically plausible sky/ambient environment, directional key
  light with shadows, soil PBR defaults and a camera rig that follows the
  excavator presentation without writing transforms to Python.
- Add explicit `high`/`balanced`/`low` quality profiles. Quality changes are
  presentation-only, bounded and inspectable; the default targets 1920×1080 at
  60 FPS without changing deterministic terrain or motion cadence.
- Add bounded, disposable soil clump/dust effects driven only by local
  excavation result signals. Effects are generation-gated and clear on reset,
  reconnect, pose clear or authority generation changes.
- Preserve the supplied GLB bytes and five-frame mapping. Do not infer physics
  or contact semantics from visual meshes and do not add dynamic rigid bodies.

## Acceptance Criteria

- [x] Main scene launches cleanly with realistic environment, camera rig and
  terrain material in the approved Forward+ project.
- [x] Quality profiles apply deterministically to visual budgets and expose a
  status snapshot; unsupported profile names are rejected without mutation.
- [x] Soil effects stay within the configured particle/clump budget, react to a
  local excavation change, and ignore stale generations.
- [x] Camera/environment/material changes do not alter authoritative pose,
  terrain bytes, bucket volume or Python transport.
- [x] Godot headless visual smoke and existing motion/GLB/terrain/excavation
  tests pass; `pixi run verify` stays green.

## Notes

- Keep `prd.md` focused on requirements, constraints, and acceptance criteria.
- Lightweight tasks can remain PRD-only.
- For complex tasks, add `design.md` for technical design and `implement.md` for execution planning before `task.py start`.
