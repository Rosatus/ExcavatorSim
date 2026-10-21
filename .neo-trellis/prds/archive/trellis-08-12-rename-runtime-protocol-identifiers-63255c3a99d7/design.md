# Technical Design

## Boundary

The protocol family string is owned by the repository version manifest and
consumed by the Python decoder/encoder, HTTP handlers, RRD adapter, Godot
`MotionProtocol`, JSON schemas, tests, and transport documentation. The
Python package directory is intentionally outside this migration boundary.

## Canonical identifiers

| Contract | Canonical value |
|---|---|
| WebSocket protocol | `godot-pinocchio-v3` |
| State schema | `godot-pinocchio-state-v2` |
| RRD profile | `godot-pinocchio/rrd-v1` |
| Session header | `X-Godot-Pinocchio-Session` |
| Terrain MIME | `application/vnd.godot-pinocchio.terrain-f32le` |
| RRD entity root | `/godot_pinocchio/...` |
| Schema namespace | `https://godot-pinocchio.local/...` |

The numeric suffixes stay unchanged because this is a naming migration, not a
payload or semantic version migration.

## Data flow

```text
version-manifest.json
  -> backend protocol.py / web.py / rrd.py
  -> WebSocket hello_ack, HTTP headers/body, RRD metadata
  -> Godot MotionProtocol and presentation client
```

The schemas and fixtures are updated in the same change so every consumer is
validated against one source of truth. Old Babylon identifiers are not
accepted as aliases; version/profile validation remains strict.

## Compatibility and rollback

This is an intentionally breaking wire-name change. A stale client receives
the existing incompatible-protocol or schema/profile error. Rollback is a
single commit revert, restoring the prior manifest/schema filename and all
consumers together; no data migration is required for deterministic motion
state.

## Historical references

References in migration inventory, provenance, source-rights, package names,
and license notices remain because they describe origin rather than the live
protocol. Current integration/spec examples are changed to the canonical
Godot/Pinocchio identifiers.
