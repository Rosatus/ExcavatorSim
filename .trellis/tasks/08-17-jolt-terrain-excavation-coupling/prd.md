# Jolt Terrain Excavation Coupling

## Goal

Couple physical bucket/chassis contacts to convincing body reaction and the existing
logical soil/payload transaction so digging, carrying, dumping, and bucket support
share one visible and numeric outcome without making Jolt or Terrain3D the soil
volume authority.

## Dependency

Requires accepted articulated Jolt equipment from
`08-17-jolt-articulated-equipment`.

## Requirements

- Add model-specific convex cutting, cavity/shell, and rear-support collision
  proxies aligned to validated bucket frames for both models.
- Collect bounded Jolt contact manifolds/summaries with exact physics tick and
  terrain generation/revision identity.
- Replace heuristic visual lift with actual chassis/work-equipment contact reaction
  in Jolt mode; legacy mode retains its existing behavior.
- Convert eligible contact/sweep data into exactly one soil transaction that owns
  cut/carry/spill/dump decisions and commits TerrainState/BucketSoilState changes.
- Keep stable/loose layers, capacity, density, fill, COM, and volume conservation
  semantics. Jolt clods/particles remain disposable presentation.
- Make terrain collider rebuilds transactional at physics-tick boundaries; stale
  contacts/colliders cannot mutate soil or inject unbounded impulses.
- Bound penetration recovery, resistance, payload updates, and contact loss to avoid
  explosions, self-feedback, or double counting.

## Acceptance Criteria

- [ ] Rear/shell support at adverse angles lifts/tilts the actual physical chassis;
      teeth-first cutting does not trigger the wrong support classification.
- [ ] Dig/carry/spill/dump emerge from bucket motion/contact without production
      Dig/Deposit buttons and conserve logical volume within documented tolerance.
- [ ] Visual fill/payload telemetry and applied physics payload derive from the same
      BucketSoilState transaction identity.
- [ ] Stale/unavailable collider, revision replacement, reset, model switch, and
      contact loss have bounded tested behavior with no duplicate edits.
- [ ] Both models pass scripted excavation cycles and live MCP review from several
      approach/support angles.

## Out Of Scope

- Per-grain authoritative soil, fracture/rock breaking, Terrain3D editor mutation,
  exact cutting-force science, or physical debris as volume authority.

