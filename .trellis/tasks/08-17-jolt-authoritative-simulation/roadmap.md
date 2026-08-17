# Roadmap: Jolt Authoritative Simulation

The phases are ordered dependencies. A phase may start only after the previous
phase's exit gate is recorded. Parent/child linkage does not itself enforce this
ordering; each child task repeats its dependency explicitly.

## Phase 0: Authority Contract And Shadow State

Child: `08-17-authority-contract-shadow-state`

Deliver a versioned authority/profile contract, Godot fixed-tick state envelope,
single-writer seams, physics-rig descriptor schema, and observational shadow
publisher. Validate the exact Godot 4.7.1 Jolt body/joint APIs locally because the
official documentation endpoint was unavailable during planning.

Exit gate: current product behavior is unchanged, shadow snapshots are ordered and
finite for both models, no shadow result writes transforms, and invalid profile or
rig identity fails explicitly.

## Phase 1: Jolt Chassis And Track Authority

Child: `08-17-jolt-chassis-track-authority`

Create the first dynamic chassis rig with frozen work equipment, compound/convex
collision, multi-point left/right traction, bounded acceleration/braking, and
terrain contact. Jolt becomes the sole chassis writer only in the new profile.

Exit gate: both models pass straight/arc/pivot/slope/obstacle/stop/reset tests and
live MCP inspection without `TrackedLocomotionState` or Python overwriting the body.

## Phase 2: Jolt Articulated Work Equipment

Child: `08-17-jolt-articulated-equipment`

Add physical upper, boom, arm, and bucket bodies/joints plus tunable actuator
targets, limits, damping, and effort saturation. Keep the SY205 passive four-bar
as a visual follower in the first version.

Exit gate: commanded and actual joint states are distinct, bounded, load-sensitive,
and stable for both models; model switching rebuilds the complete rig.

## Phase 3: Terrain And Excavation Contact Coupling

Child: `08-17-jolt-terrain-excavation-coupling`

Introduce bucket cutting/shell/support collision proxies, tick-boundary terrain
collider transactions, contact-derived resistance, and one contact-to-soil
transaction path. Preserve TerrainState/BucketSoilState volume semantics.

Exit gate: physical bucket support can lift/tilt the actual chassis, cutting changes
logical terrain and payload once, stale collider identities cannot mutate soil,
and no visual clod or Terrain3D map becomes authority.

## Phase 4: Sensor Telemetry And Python Gateway

Child: `08-17-sensor-telemetry-python-gateway`

Publish canonical Z-up truth and initial sensor streams from the Godot fixed tick;
validate, rate-limit, record, diagnose, and export them in Python. Provide a safe
external command ingress seam without implementing production CAN drivers.

Exit gate: state, four IMUs, GNSS, encoders, contact/track, and payload samples have
documented clocks, frame/calibration identity, quality, sequence/gap behavior, and
cross-language contract tests.

## Phase 5: Authority Cutover And Legacy Retirement Boundary

Child: `08-17-jolt-authority-cutover`

Run full integration/performance acceptance, make the Jolt profile the product
default, stop Python motion snapshots from entering the Jolt presentation path,
and retain the old runtime only behind an explicit legacy selection.

Exit gate: release-candidate tests prove one authority under all lifecycle paths,
the Python gateway has no pose-reconstruction dependency, rollback is documented,
and architecture/spec documentation matches shipped behavior.

## Cross-Phase Gates

- Every model value is labelled measured, declared, derived, estimated, or tuned.
- No phase introduces a second transform writer.
- Every state crossing a process boundary carries version, model, epoch, sequence,
  monotonic time, coordinate frame, and quality.
- Terrain collider revision and physics tick participation are observable.
- Performance evidence includes fixed-step overruns and body/joint/contact counts.
- A phase can be disabled without corrupting TerrainState or BucketSoilState.

## Principal Risks

| Risk | Mitigation |
|---|---|
| Estimated mass/inertia produces unstable or false behavior | Asset validation spike, bounded tuning, evidence labels, static COM/tip checks |
| Closed-loop bucket linkage destabilizes constraints | Keep four-bar visual-only initially |
| Dynamic bodies contact stale rebuilt heightfields | Tick-boundary collider transaction and revision gate |
| Python and Godot both write pose during migration | Explicit profile and single-writer assertions |
| Track friction feels arcade-like or unstable | Distributed traction probes, force caps, slip telemetry, tuning scenarios |
| Sensor timestamps/axes disagree across processes | One publisher conversion and one monotonic clock contract |

