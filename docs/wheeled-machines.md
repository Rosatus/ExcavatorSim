# Reusable wheeled machines

`WheeledLocomotionState` is a force-only suspension/tire solver. One existing
`RigidBody3D` remains the sole chassis pose authority. It accepts 2–16 wheel
stations; the supplied steering geometry is front Ackermann with an unsteered
rear axle. It is not an articulated-steering or four-wheel-steering solver.

## Product controls

SY155W automatically selects the wheel solver in the authoritative runtime:
G = forward, V = left, B = reverse, N = right; Space = brake.
Gamepad: RT = forward, LT = reverse, LB/RB = left/right steering. The two-piece
boom fold axis (E/U on keyboard) rides the pad layer: hold D-pad Up and push
the right stick up/down to unfold/fold; while held, the base boom axis is
masked.
Released travel input applies a bounded parking brake. Steering alone cannot
pivot the machine. Work equipment controls remain unchanged. Focus loss,
menus, pause and reset clear commands and require neutral before resuming.
Legacy Python-authority mode retains its compatibility tracked approximation.

## Standalone use

Open `res://scenes/wheeled_vehicle_demo.tscn` in Godot and run the current scene
(F6). G/V/B/N drive forward/left/reverse/right; Space brakes. The demo uses explicit
keyboard opt-in, separate from the product machine controls.

Add `WheeledVehicleController` under a `RigidBody3D` with appropriate hulls,
mass, center of mass and inertia. Provide `wheel_stations` dictionaries:

```gdscript
{"mount": Vector3(-1.05, 0, -1.4), "radius_m": 0.5,
 "steered": true, "driven": true}
```

Units are metres, seconds, kilograms and newtons; +Y up, -Z forward, +X right.
Mounts are suspension upper anchors in body coordinates. Default coefficients
are in `WheeledLocomotionState.DEFAULTS`; change spring/damper, wheel inertia,
force, friction, dimensions and speed limits for the machine. Static sag is
approximately `mass * gravity / (wheel_count * spring_n_m)` and must remain
inside suspension travel. Positive throttle is forward; positive steer right.
The controller's `set_commands(throttle, brake, steer)` accepts normalized
inputs; `set_enabled(false)` disarms; `reset_motion()` clears wheel state after
the owning scene resets its body. The generic controller brakes when disarmed,
but otherwise zero throttle coasts (product runtime adds automatic parking).

`WheelVisualAnimator` consumes the solver snapshot. Each wheel needs a distinct
steering/suspension pivot with a rolling child. Its two path arrays have the
same station order. Preserve imported rest transforms; configure per-asset
roll/steer axes and `rest_suspension_lengths_m` for already assembled wheels.
The animator sets absolute physical roll angles, so repeated snapshots do not
advance animation twice. It never drives chassis pose or edits mesh vertices.

## Existing excavator runtime / future imports

Add a model entry in `resources/physics/wheeled_machine_profiles.json`, copying
the SY155W structure and replacing validated asset SHA, node paths, rest
transforms, suspension mounts, radius, hulls and physical coefficients. The
profile is separate from the legacy physics-rig-v1 work-equipment descriptor.
`JoltChassisTrackRuntime` selects it, reuses the terrain readiness filter, and
publishes `wheeled_locomotion`. `MotionPresentation` binds and validates exact
imported pivot transforms before activating wheel animation. Missing/invalid
profile data or imported pivot drift fails activation. The existing model
catalog, articulation rig and equipment controls are still required for an
excavator; a standalone vehicle only needs the generic component.

Raw GLB SHA-256 is a source/build-time provenance check. Run
`pixi run verify-model-sources` after changing model assets or contracts and
before exporting manually from Godot. `tools/build_release_dist.ps1` and
`pixi run verify` run this check automatically. Manual Godot exports use the
standard exporter without a custom plugin; they do not run the external source
check automatically. At runtime, ResourceLoader loads imported scenes and the
existing hierarchy, wheel rest-transform, attachment socket and soil geometry
checks validate them. JSON contract/fill-profile hash checks remain active.
Original GLB bytes are not required in the exported pack.
Run `res://tests/sy155w_session_test.gd` against the source project and exported
pack when changing this boundary.

SY155W geometry comes from source wheel centers (+/-1.3,+/-0.972,.535) in
Blender coordinates, independently checked in the imported scene. Source
+X forward is runtime -Z; each imported rolling pivot's local +Z maps to
chassis +X. Its four stations each represent a dual-tire pair. Original GLB
bytes and work-equipment neutral/limits are unchanged. Mass and drive/suspension
coefficients remain provisional simulation tuning, not measured manufacturer
performance. Small suspension travel approximates tire/axle compliance; the
fixed axle housings, steering tie bar and fenders are not a fully articulated
suspension mechanism.

Ground contacts use suspension rays plus permanent wheel/hull colliders for
wall impacts and bottoming. This supports load transfer, slopes, sliding and
loss of propulsion in air; it does not model deformable tires, differential
gearing, engine/transmission, rolling over every sharp curb, or independent
axle oscillation. Surface `wheel_friction` metadata multiplies tire friction.
Both braking and cornering consume the same Coulomb friction budget. Future
terrain adapters should pass the optional `accept_hit` callback to reject
stale or unowned ground before applying force. Continuous collision detection
and bounded physics timestep (<=0.1 s; 60/120 Hz tested) are recommended.

## Validation

Run with the repository's Godot/Jolt executable and `--headless --path
godot/client --fixed-fps 60 --script res://tests/<name>.gd`:

- `wheeled_locomotion_test`: acceleration, stop/reverse, Ackermann/yaw, suspension,
  low-grip force budget, slope support, airborne spin/no propulsion, animation,
  reset and neutral rearm. Also run `--fixed-fps 120 ... -- --hz120`.
- `sy155w_wheeled_test`: actual 15t runtime, imported dual-wheel pivots, steering,
  braking, reset and original pivot preservation.
- `sy155w_session_test`: main scene routes input and physics snapshots through
  model switching, attachments, wheel presentation, local fold and hydraulics.
- `sy155w_import_test`, `control_input_hud_test`: existing import/UI regressions.

Jolt force application follows the [Godot RigidBody3D contract](https://docs.godotengine.org/en/stable/classes/class_rigidbody3d.html):
forces are applied per physics step, with world-space offsets from body origin.
Automated checks do not certify subjective handling or manufacturer fidelity.
