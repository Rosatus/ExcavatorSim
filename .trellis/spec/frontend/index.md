# Godot Client Guidelines

The Godot client is under incremental development. Its Forward+ project foundation lives under `godot/client/`; transport, deterministic world state, and final visual assets land through separate Trellis milestones. The client must consume Python motion authority through the documented transport boundary.

## Guideline

- [Client Boundary](./client-boundary.md) — ownership, transport, derived terrain, and local physics rules.
- [Godot MCP Development Tool](./godot-mcp.md) — connection checks, safe editor automation, and cross-layer boundaries.
- [Godot Motion Transport](./motion-transport.md) — WebSocket handshake, JSON normalization, generation guards, input safety, and visual parity.

Before client implementation, read `.trellis/tasks/08-06-excavator-sim-bootstrap/docs/godot-integration.md` and the current protocol schemas. Do not copy React/Babylon scene code into the Godot project.
