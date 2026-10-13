# Urban spawn from live debug vehicle

User requested the urban spawn match their current debug vehicle position,
with heading snapped to the nearest world coordinate axis.

Captured via local Godot AI MCP (ExcavatorSim, Godot 4.7.2 custom):
SY135 position (37.3515778, 1.1701427, 29.2454090), yaw 90.891383 degrees.
Ground ray hits VoxelTerrain at y=1.1025. Marker uses authored grade 1.1,
same XZ, and yaw 90 degrees / -X. Both urban pack copies rebuilt.

Cold-start tests revealed the dynamic chassis fell into the not-yet-ready
voxel surface and was pushed off spawn. Added initial-support wait in
TrackedChassisController._connect_runtime only for static-map spawns inside
an enabled voxel zone. Existing unrelated controller changes preserved.

Validation:
- urban_pack_test: PASS; settled XZ=(37.35158,29.24541), y=1.170867;
  grounded voxel support, -X heading, forward travel 5.648 m.
- map_view_distance_test: PASS after this guard, including optional-map
  teardown while initialization is pending and subsequent training startup.
- Scoped git diff --check passed.
- Logs under artifacts/urban-map/spawn-ready-test and
  spawn-map-transition-test; failed diagnostic evidence retained separately.

Runtime note: a temporary read-only game_eval probe used mixed indentation,
causing a debugger parser break. Resume did not advance the game loop; user
was informed to stop/restart Debug, which also loads the rebuilt pack.

Implementation complete, uncommitted; pending user restart/visual inspection.
