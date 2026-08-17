# Implementation Plan

- [ ] Validate/refine SY205/SY135 physical cutting/shell/support proxies with asset
      evidence and controlled Godot visualization.
- [ ] Implement contact collector and bounded identity-tagged contact summaries.
- [ ] Implement tick-boundary terrain collider prepare/switch/invalidate transaction.
- [ ] Refactor excavation classification to consume one physical contact/sweep input
      and emit one logical soil/payload transaction.
- [ ] Remove/bypass heuristic ground-lift reaction only in Jolt authority mode.
- [ ] Connect payload mass/COM updates and derived effects without feedback loops.
- [ ] Add conservation, stale revision, duplicate tick, penetration recovery,
      support/cutting angle, lifecycle, both-model, and long-cycle tests.
- [ ] Run full gates plus MCP visual/contact/conservation scenarios; record collider
      rebuild and fixed-tick costs.
- [ ] Update terrain, bucket, physics, and client authority specs.

## Rollback Point

Keep current automatic logical excavation and visual reaction behind the legacy
profile until this phase passes; mode selection must never combine both paths.

