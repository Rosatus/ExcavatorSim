# Design — integration release candidate

## Test seam

`release_candidate_test.gd` instantiates `main.tscn`, disables automatic socket
dialing, injects a fake WebSocket transport, then drives the existing
`MotionClient` hello/view-state seams. The test observes `MotionPresentation`,
`ExcavationWorld` and `SoilEffects` in one scene; it does not duplicate server
authority or bypass protocol normalization.

The sequence is: connect/hello, accept an asymmetric authoritative pose, cut a
contact brush, deposit at clearance, reconnect to a new simulation epoch, assert
pose/inventory/effect generation cleanup, and reset the local world. Existing
backend tests remain the source of truth for real aiohttp/WebSocket capability
and optional-route behavior.

## Release boundary

Motion kinematics, input safety and lifecycle remain Python-owned. Godot local
terrain, bucket convenience and effects remain presentation/gameplay support;
none are sent back. The legacy Python terrain/recording/replay service is kept
for compatibility and is not removed or silently deprecated by M7.
