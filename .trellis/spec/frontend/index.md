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

### Model maintenance priority (2026-09-10)

SY135 is the primary maintained product model. Future features, performance work,
fixes and representative validation should target SY135 by default. SY205 does
not require dedicated maintenance or a parallel validation matrix unless the
user explicitly requests it. Preserve its existing behavior when editing shared
code; this policy does not authorize removing SY205 or deliberately breaking it.



- [Game Menu and Driving HUD](./game-menu-hud.md) — automatic entry, modal input/pause ownership, controller navigation and hardware supervision.

- [Client Boundary](./client-boundary.md) — ownership, transport, derived terrain, and local physics rules.
- [Godot MCP Development Tool](./godot-mcp.md) — connection checks, safe editor automation, and cross-layer boundaries.
- [Godot Motion Transport](./motion-transport.md) — WebSocket handshake, JSON normalization, generation guards, input safety, and visual parity.
- [Validation Budget](./validation-budget.md) — risk-based Agent checks, human-owned visual/runtime review, escalation triggers, and rerun limits.
- [Soil Release Visuals](./soil-release-visuals.md) — stable deposit ledger, decorative release events, retired modes, and shared soil resources.

Before changing or extending client code, read `docs/godot-integration.md` and
the current protocol schemas. Do not copy React/Babylon scene code into the
Godot project.
