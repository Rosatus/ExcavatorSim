# Integration release candidate

## Goal

Prove that the Godot-first local-world client can connect to Python motion,
operate the supplied SY205 scene, dig/deposit/reset locally, survive authority
generation changes and remain usable when optional physics is unavailable.

## Requirements

- Keep the motion-only and legacy Python profiles opt-in and wire-compatible;
  do not introduce a new terrain/bucket protocol in this milestone.
- Exercise the real Godot scene composition through a deterministic fake
  transport seam and retain backend WebSocket capability/route coverage.
- Verify hello/view-state acceptance, pose presentation, local excavation and
  volume reset, reconnect/epoch stale guards, effect/collider degradation and
  UI status availability.
- Run all Godot headless contracts (foundation, GLB, motion, terrain,
  excavation, visual, release candidate) plus `pixi run verify`.
- Record the deferred decision: retain legacy Python terrain/replay for
  compatibility until a separately approved migration removes its clients.

## Acceptance Criteria

- [x] A release-candidate test connects a scene with a fake transport, consumes
  hello/view state, moves the visual rig, digs, deposits, resets and reconnects.
- [x] Authority epoch changes clear pose/inventory/effect state and stale frames
  cannot replace the new generation.
- [x] No-physics mode remains operational and quality profiles stay bounded.
- [x] All backend and Godot checks are green with no protocol/schema/GLB drift.
- [x] Legacy Python terrain/replay retention is documented as a deliberate
  compatibility decision, not silently removed.

## Notes

- Keep `prd.md` focused on requirements, constraints, and acceptance criteria.
- Lightweight tasks can remain PRD-only.
- For complex tasks, add `design.md` for technical design and `implement.md` for execution planning before `task.py start`.
