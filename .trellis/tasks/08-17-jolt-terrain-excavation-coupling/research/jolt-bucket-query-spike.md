# Godot 4.7.1 / Jolt Bucket Query Spike

## Environment

- Godot: `4.7.1.stable.mono.official.a13da4feb`
- Physics engine: `Jolt Physics`
- Permanent regression: `godot/client/tests/jolt_bucket_query_spike.gd`

## Observed API Behavior

- `PhysicsDirectSpaceState3D.cast_motion()` returns safe/unsafe translational
  travel fractions against the generated `TerrainCollider`.
- `intersect_shape()` supplies collider identity and shape index.
- `get_rest_info()` supplies the contact point and normal near the unsafe
  transform.
- Initial overlap must be queried separately; it is surfaced as ineligible
  evidence rather than silently treated as a new cut/support event.
- A mismatched applied terrain generation/revision fails closed.
- The query path needs no bucket `PhysicsBody3D`; the test asserts no scene body
  is created by a sweep.
- A repeated 100-query headless sample on this Windows/Godot 4.7.1 environment
  measured 218-221 microseconds median and 326-392 microseconds p95 for all five
  proxies. Applying the 64x64 logical terrain collider measured 3.111 ms. The
  permanent regression keeps a conservative 10 ms p95 ceiling; this is a local
  bounded-fixture budget, not a production hardware guarantee.
- The permanent chassis/track scenario measured 0.623-0.818 ms SY205 and
  0.641-0.700 ms SY135 peak hybrid fixed steps across two runs, below its 10 ms
  bounded-scene gate.
- Final quality runs measured 212-214 microseconds median / 222-298 microseconds
  p95 for all five proxies, 3.034-3.204 ms collider apply, and 0.529-0.988 ms
  dual-model hybrid fixed-step peaks.

## Godot AI MCP Evidence

- Godot editor session `client@cf76` ran the main scene under the temporary
  `jolt_authoritative` setting and restored `python_kinematic` afterward.
- Live SY205 truth reported one chassis body, four accepted kinematic frames,
  four logical joints, full query epoch/tick/terrain/motion identity, and a soil
  batch key derived from the same identity.
- Live SY205-to-SY135 activation rebuilt controller/runtime/truth for SY135 and
  replaced the bucket grid with 175 cells / 35 fill-profile columns. The MCP
  path exposed and verified fixes for transient grid reads, teardown safety,
  and stable runtime naming. Actual cutting/support contact mechanics remain
  covered by the permanent real-Jolt headless tests rather than debugger input.

## Rotation Decision

Godot documents the `motion` field as translation and does not promise continuous
rotation sweep. Product queries therefore interpolate previous-to-candidate
bucket transforms into bounded translation/rotation segments. Each segment uses
`cast_motion` for translation and an endpoint `intersect_shape` for the rotated
pose. The earliest blocking fraction across cutting, shell, and rear support
owns the accepted articulation fraction.

## Product Boundary

The selected mechanism is query-only. Query evidence may scale the kinematic
joint step, classify soil, or queue a capped later-tick chassis wrench. It never
creates a kinematic bucket body that can inject uncapped impulses into the
dynamic chassis.
