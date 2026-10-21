# Godot Soil Performance Baseline

Captured through Godot AI MCP on 2026-08-15 before automatic-soil changes.

- Session: `client@c72d`
- Godot: `4.7.1-stable`
- Scene: `res://scenes/main.tscn`
- Observed FPS: 145
- Process time: 5.147 ms
- Physics process time: 0.178 ms
- Draw calls: 464
- Rendered objects: 1,710
- Rendered primitives: 66,640
- Active 3D physics objects/pairs/islands: 0 / 0 / 0

## Post-implementation MCP captures

Captured through Godot AI MCP on 2026-08-15 after the automatic-soil path.

Balanced (`client@59ac`): FPS 145, process 3.989 ms, physics 0.078 ms,
draw calls 401, rendered objects 1,883, primitives 23,120, video memory
590,802,944 bytes, active 3D physics objects/pairs 0 / 0.

High (`client@59ac`): FPS 145, process 3.866 ms, physics 0.056 ms, draw calls
426, rendered objects 1,937, primitives 45,124, video memory 591,196,160
bytes, active 3D physics objects/pairs 0 / 0.

The standalone gameplay contract also ran 1,800 fixed steps per model (30 s at
60 Hz) and kept active transfers below `BucketSoilState.MAX_ACTIVE_TRANSFERS`.
The Godot-only gate is therefore covered by both live MCP metrics and the
standalone matrix. The existing Terrain3D deprecation warning remains
non-blocking and is unrelated to the soil solver.
