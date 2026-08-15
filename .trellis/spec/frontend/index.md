# Godot Client Guidelines

The Godot client has an implemented M1–M7 Forward+ vertical slice under
`godot/client/`. It includes the documented motion transport, SY205 visual
presentation, Godot-first deterministic-enough world state, excavation loop,
local tracked-chassis locomotion, and release-candidate checks. Further
production physics and model work remains
separate from the current presentation slice. The client must consume Python
motion authority through the documented transport boundary.

## Guideline

- [Client Boundary](./client-boundary.md) — ownership, transport, derived terrain, and local physics rules.
- [Godot MCP Development Tool](./godot-mcp.md) — connection checks, safe editor automation, and cross-layer boundaries.
- [Godot Motion Transport](./motion-transport.md) — WebSocket handshake, JSON normalization, generation guards, input safety, and visual parity.

Before changing or extending client code, read `docs/godot-integration.md` and
the current protocol schemas. Do not copy React/Babylon scene code into the
Godot project.
