# Automatic waypoint driving

The product uses Godot-local fixed-tick guidance. `WaypointDriver` produces normalized commands; `TrackedChassisController` arbitrates manual/automatic input; the existing Jolt body remains the only chassis pose writer. Python and MCP are not runtime dependencies. There is no obstacle planner. Surface excavation jobs can request tracked reverse travel for station transfers; the training square retains forward travel.

## Use

In the training map, select SY135 or SY155W and press **T** (gamepad Y). Choose **训练场正方形自动驾驶** and confirm with Enter/gamepad A, or click the entry. A cyan square and waypoint crosses appear. The status at the upper left reports the target index, distance and state. The route has an approach target plus four sides: XZ `(-6,-8) → (6,-8) → (6,4) → (-6,4) → (-6,-8)`; side length is 12 m. Reset to the original spawn before repeating the acceptance route.

SY135 stops and pivots at each corner. SY155W uses continuous forward Ackermann steering with lookahead derived from wheelbase and maximum steering angle. Intermediate corners are pass-through regions, not exact stopping positions; it stops only at the final goal. The initial approach may include a forward U-turn because the default training spawn faces away from the first target. No route is guaranteed collision-free after excavation or scene changes.

Opening a menu, pausing or losing focus latches navigation pause. Closing the menu/refocusing does **not** resume driving. Use **恢复自动驾驶** in T to resume, or **取消自动驾驶** to discard the route. Manual travel, braking, equipment or attachment-axis input cancels navigation. Enabling equipment assists cancels navigation; starting/resuming navigation disables those assists. Reset/model/attachment/map changes retire the old route. Race mode is incompatible with automatic driving. The square action is unavailable outside training.

## API and control

`TrackedChassisController.start_navigation(PackedVector3Array)` accepts world-coordinate targets; `resume_navigation()`, `cancel_navigation()` and `navigation_snapshot()` expose control/status. Up to 256 finite points are accepted. XZ is the navigation plane; Y is only used for route presentation. Jolt handles terrain height and attitude. Caller-supplied points must be on a usable driving surface. The public API is also usable outside training; only the built-in square action is training-specific.

Tracked guidance follows a fixed straight segment using forward lookahead and heading/yaw-rate feedback. Tracked cruise demand is 3.1 m/s, bounded by the configured belt speed. The tracked distance-based braking envelope uses 0.9 m/s²; wheel braking remains unchanged. It slows using the remaining-distance braking envelope, with a continuous approach ramp and the original distance-proportional precision crawl inside the final 25 cm, braking within 3 cm. Large-angle pivots allow up to 0.8 rad/s requested yaw with stronger heading feedback; small-angle alignment retains gentle feedback and the same settling gates. Switching to the next edge requires settled planar speed below 0.025 m/s; coasting outside 5 cm fails the task instead of advancing the waypoint. After pivoting, the chassis must also remain within 5 cm of the next edge before translating. No chassis pose is corrected artificially. Wheel guidance retains its 0.28 m arrival radius and uses a bicycle-model curvature command, bounded steering, measured speed feedback and explicit braking. Multiple wheel waypoints must be separated by at least twice the selected lookahead (about 9 m for SY155W); very short routes are rejected rather than silently skipping corners. This is a conservative first release, not a general manoeuvre planner.

Tracked pivot entry while driving uses a 0.65 rad (~37.2°) error against the fixed next-segment bearing. Initial start/resume and each stopped waypoint also enter alignment. Pivot completion uses that segment bearing, not the diagonally offset lookahead target: translation remains zero until heading error is at most 1°, yaw rate is at most 0.035 rad/s (~2°/s), and planar speed is below 0.08 m/s for 0.2 s. The controller first brakes residual translation before pivoting. Once aligned, ordinary moving path tracking can gently correct lateral error. The square regression independently measures actual heading and yaw rate at every alignment-to-driving transition.

Commands are produced from the last accepted physics snapshot. Epoch changes, nonfinite state, stale ticks, sustained unsupported motion and no progress stop the task. Alignment has its own progress watchdog, and each segment has an overall timeout. Neutral rearming is explicit for both drive types. No transforms, velocities, force constants or COM values are overwritten by guidance.

## Automated acceptance

Run with the project's pinned Godot/Jolt executable (on the current machine `C:\apps\godot_voxel\godot.windows.editor.x86_64.exe`):

```powershell
& $godot --headless --path godot/client --fixed-fps 60 --script res://tests/navigation_square_test.gd
& $godot --headless --path godot/client --fixed-fps 60 --script res://tests/navigation_square_test.gd -- --wheeled
& $godot --headless --path godot/client --fixed-fps 60 --script res://tests/navigation_lifecycle_test.gd
& $godot --headless --path godot/client --fixed-fps 60 --script res://tests/track_straight_drive_test.gd
```

Square acceptance loads the actual main scene and uses the production navigation API, with isolated UI preferences. It requires route completion, all four edge midpoints visited within 1.5 m, final distance below 0.05 m for tracks / 0.55 m for wheels, final speed below 0.12 m/s, and distance from the square perimeter below 0.65 m for tracks / 3 m for wheels. Every tracked alignment-to-driving transition additionally checks heading, yaw rate and distance to the next edge (at most 5 cm). Perimeter error is measured against all four edges because a wheel's front-looking target changes sides before the body finishes rounding the corner. The approach to the first corner is excluded from perimeter measurements. Lifecycle checks include early-stop rejection at 25 cm, crawl speed, settling before waypoint advance, pivot drift rejection, input takeover, focus/menu pause, explicit neutral resume, reset, assist exclusion, epoch changes, stale data and blocked alignment.

2026-10-15 latest measured headless results: SY135 final error 0.0192 m, perimeter error 0.0190 m, maximum departure offset from the next edge 0.0193 m, maximum departure angle 0.854°, 77.07 s including approach (previous precision version: 107.17 s, a 28.1% reduction); SY155W unchanged: final error 0.2629 m, perimeter error 2.2400 m, 69.57 s. Both visited the four side midpoints and stopped. Earlier rendered MCP checks exercised the initial product path; the subsequent precision and responsiveness refinements were validated headlessly. The tracked square regression retains all geometry/settling checks and additionally requires completion within 95 s, reporting time by control phase. Headless logs include existing interpolation-deprecation warnings; an intermittent one-object shutdown warning is not treated as visual acceptance. Human review still owns steering feel and HUD/route readability.

## Equal-input drift investigation

Closed on 2026-10-15: the user confirmed the drift no longer exists and requested no further investigation. The diagnostic findings below are retained for reference; no compensating physics changes were introduced.

The reported SY135 drift has **not yet been reproduced without contact or terrain disturbances**. No physics correction or model-specific steering bias has been applied.

The shared straight-drive regression tests SY135, SY80U and SY205 at two headings on a large flat static surface, with equal full forward commands for 10 s (~30 m). All pass 0.1 m lateral / 0.5 degree heading limits; measured lateral error is below 0.00011 m. Main-scene training tests, including normal bucket contact mode and the terrain/voxel seam, also remain straight. Rendered MCP input through the actual left/right actions confirms equal commands and negligible yaw at spawn. SY135's configured transverse COM is zero.

The optional diagnostics `track_straight_drive_test.gd -- --training --normal [--construction|--urban]` log commands' physical effects, contact sources, support loads and equipment reaction wrenches; these exploratory map runs are not drift pass/fail gates. Urban traversal encountered a real equipment contact with a scene object and a substantial yaw torque. That contact must not be hidden by a universal heading lock. A specific map/location, equipment pose and preceding manoeuvre are still needed to reproduce the user's reported case and select an evidence-based shared fix.
