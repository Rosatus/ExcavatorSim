# Roadmap: Hybrid Jolt Authoritative Simulation

The phases are ordered dependencies. A phase may start only after the previous
phase's exit gate is recorded. Parent/child linkage does not itself enforce this
ordering; each child repeats its dependency explicitly.

The product direction changed after Phase 2 evaluation: the dynamic Jolt chassis
is retained, while product work-equipment motion moves to a bounded kinematic
state machine with bucket-only collision queries. The archived Phase 2 result is
historical evidence and a comparison baseline, not the final runtime target.

## Phase 0: Authority Contract And Shadow State - Completed

Child: `08-17-authority-contract-shadow-state`

Delivered the versioned authority/profile contract, Godot fixed-tick truth
envelope, single-writer seams, physics descriptor foundation, and isolated shadow
transport.

Preserved gate: invalid identity or stale shadow data cannot write product state.

## Phase 1: Jolt Chassis And Track Authority - Completed

Child: `08-17-jolt-chassis-track-authority`

Delivered the dynamic chassis, simplified distributed crawler traction, bounded
acceleration/braking, terrain contact, lifecycle rebuild, and single chassis writer
for both models.

Preserved gate: Python and legacy locomotion cannot overwrite the Jolt chassis in
the authoritative profile.

## Phase 2: Articulated Jolt Prototype And Decision Gate - Completed, Superseded

Child: `08-17-jolt-articulated-equipment`

Delivered and validated a five-body/four-joint Jolt prototype with actuator
shaping, payload coupling, one post-step snapshot, visual following, and truth
publication. It proved important Jolt, frame, lifecycle, and model-switch seams.

Decision gate: complete articulated dynamics is not the product target because it
permanently expands mass, inertia, anchor, motor, collision, and solver tuning. The
prototype remains available as evidence; later phases must not preserve its body
counts or physical-joint claims merely for compatibility.

## Phase 3: Hybrid Work Equipment And Excavation Coupling

Child: `08-17-jolt-terrain-excavation-coupling`

Replace dynamic upper/boom/arm/bucket bodies with one Godot fixed-step kinematic
articulation state using joint limits, velocity, acceleration, braking, optional
jerk, and load-response tuning. Drive visual FK and bucket-only cutting/shell/
support sweep proxies from the same accepted state. Convert eligible support
evidence into a capped later-tick chassis wrench, and route eligible cutting/
carry/dump evidence into exactly one TerrainState/BucketSoilState transaction.

Exit gate: both models have smooth bounded four-axis motion without physical
work-equipment bodies; bucket queries cannot act as an uncontrolled kinematic
pusher; rear/shell support can lift/tilt the dynamic chassis within caps; teeth-first
cutting changes terrain and payload exactly once; stale collider identities cannot
affect motion, chassis, or soil.

## Phase 4: Sensor Telemetry And Python Gateway

Child: `08-17-sensor-telemetry-python-gateway`

Publish canonical Z-up hybrid truth and initial sensor streams from the Godot fixed
tick. Dynamic chassis signals and kinematically derived work-equipment frame signals
must be distinguished by type/quality. Python validates, rate-limits, records,
diagnoses, and exports them without reconstructing pose.

Exit gate: chassis state, declared-frame IMUs, GNSS, kinematic encoders,
contact/track, payload, and applied-wrench samples have documented clocks,
frame/calibration identity, source semantics, quality, sequence/gap behavior, and
cross-language contract tests.

## Phase 5: Authority Cutover And Legacy Retirement Boundary

Child: `08-17-jolt-authority-cutover`

Run full integration/performance acceptance, make the hybrid profile the product
default, stop Python motion snapshots from entering the authoritative presentation
path, and retain the old runtime only behind an explicit legacy selection.

Exit gate: release-candidate tests prove one dynamic chassis writer and one
kinematic articulation writer under all lifecycle paths; the Python gateway has no
pose-reconstruction dependency; the archived five-body prototype is not selected
implicitly; rollback and shipped documentation match the final boundary.

## Cross-Phase Gates

- Every model value is labelled measured, declared, derived, estimated, or tuned.
- No phase introduces a second chassis, joint-state, terrain, or bucket writer.
- Every state crossing a process boundary carries version, model, epoch, sequence,
  monotonic time, coordinate frame, and quality.
- Dynamic body state and kinematic frame state are distinct schema concepts.
- Bucket proxy queries carry terrain collider revision and physics tick identity.
- Support feedback is a bounded queued wrench, not a direct transform offset or
  uncontrolled kinematic-body impulse.
- Terrain collider revision and physics tick participation are observable.
- Performance evidence includes fixed-step overruns and dynamic body, query,
  contact, and transaction counts.
- A phase can be disabled without corrupting TerrainState or BucketSoilState.

## Principal Risks

| Risk | Mitigation |
|---|---|
| Kinematic bucket behaves as an infinite-mass pusher | Prefer sweep/query evidence, clamp candidate motion, and apply one capped chassis wrench |
| Contact resistance and joint motion create a feedback loop | Previous-to-candidate sweep, one accepted motion fraction, and later-tick reaction |
| Bucket proxies do not match either model | Asset evidence, controlled proxy visualization, and both-model angle scenarios |
| Dynamic chassis and legacy lift both write reaction | Disable transform lift in authoritative mode and assert one wrench path |
| Stale rebuilt heightfield affects motion or soil | Tick-boundary collider transaction and exact generation/revision gate |
| Python and Godot both write pose | Explicit profile and single-writer assertions |
| Track friction feels arcade-like or unstable | Distributed traction probes, force caps, slip telemetry, and tuning scenarios |
| Derived IMU semantics are mistaken for rigid-body measurements | Typed dynamic/kinematic sources and explicit quality flags |
| Sensor timestamps/axes disagree across processes | One publisher conversion and one monotonic clock contract |
