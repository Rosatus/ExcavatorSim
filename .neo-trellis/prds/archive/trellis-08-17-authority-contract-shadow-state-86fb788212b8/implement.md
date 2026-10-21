# Implementation Plan

- [x] Capture local Godot 4.7.1 Jolt capability/stability probe evidence under this
      task's `research/` directory.
- [x] Define authority profile, rig descriptor, truth snapshot, coordinate, clock,
      and lifecycle contracts before product code.
- [x] Add schemas/version manifest entries and shared fixtures for valid/invalid
      SY205/SY135 identities.
- [x] Implement Godot descriptor validation and immutable truth snapshot builder.
- [x] Implement canonical Z-up publisher and negotiated shadow transport.
- [x] Implement Python decoder, latest-value slot, rate/size/order guards, health
      diagnostics, and clean lifecycle shutdown.
- [x] Add tests proving observational-only behavior, coordinate parity, stale/error
      handling, reconnect/reset/model switch, and both models.
- [x] Run `pixi run verify`, backend smoke, Godot standalone matrix, and Godot MCP
      shadow smoke; capture baseline tick and message costs.
- [x] Update protocol, frontend/backend authority specs, and architecture docs for
      the new profile while clearly retaining Python product authority.

## Rollback Point

Remove/disable the negotiated shadow capability and descriptor loader. No product
transform, terrain, payload, or default-profile migration is permitted in this task.
