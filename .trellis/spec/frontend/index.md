# Godot Client Guidelines

The Godot client has an implemented M1–M7 Forward+ vertical slice under
`godot/client/`. It includes the documented motion transport, SY205 visual
presentation, Godot-first deterministic-enough world state, excavation loop,
local tracked-chassis locomotion, hybrid Jolt/kinematic excavation coupling, and
release-candidate checks. The client consumes Python motion authority only in
explicit compatibility/shadow profiles. Default `jolt_authoritative` selects one dynamic Jolt
chassis writer, bounded kinematic work equipment, query-only bucket proxies,
idempotent local soil transactions, and local hybrid truth.

## Guideline

- [Client Boundary](./client-boundary.md) — ownership, transport, derived terrain, and local physics rules.
- [Godot MCP Development Tool](./godot-mcp.md) — connection checks, safe editor automation, and cross-layer boundaries.
- [Godot Motion Transport](./motion-transport.md) — WebSocket handshake, JSON normalization, generation guards, input safety, and visual parity.
- [Validation Budget](./validation-budget.md) — risk-based Agent checks, human-owned visual/runtime review, escalation triggers, and rerun limits.

Before changing or extending client code, read `docs/godot-integration.md` and
the current protocol schemas. Do not copy React/Babylon scene code into the
Godot project.
