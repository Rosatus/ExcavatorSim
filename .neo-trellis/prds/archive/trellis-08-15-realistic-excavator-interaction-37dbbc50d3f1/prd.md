# Realistic excavator interaction final acceptance

## Goal

Close the historical realistic-interaction roadmap against the current product
architecture. Produce reproducible release endurance and quality-tier evidence for
SY205 and SY135, then archive this parent without reopening the already delivered
locomotion, excavation, or support-reaction implementations.

## Background

- The three original children are complete and archived: tracked chassis
  locomotion (`07301c7`), automatic soil interaction (`864bd7e`), and bucket
  ground reaction (`98c0cce`).
- The archived `08-17-jolt-authoritative-simulation` roadmap supersedes the old
  authority split. The product default is now one dynamic Jolt chassis plus one
  fixed-step kinematic work-equipment state, with Python acting as gateway and
  telemetry consumer rather than a competing pose writer.
- `TerrainState` and `BucketSoilState` remain the terrain-volume and bucket-payload
  semantic owners. Terrain3D, visual soil, and query collision remain derived.
- The 90-second rendered quick soak passed for both models. The documented
  15-minute-per-model release soak has not been run.
- Low, balanced, and high visual quality controls have isolated tests, but the
  complete loaded cut/carry/spill/dump/support scenario has not been exercised as
  a two-model quality matrix or captured for visual review.

## Requirements

### R1. Preserve current authority and lineage

Planning and evidence must describe the current hybrid Jolt product path from
`docs/architecture/engineering.md`. No work in this task may restore Python pose
authority, direct chassis transform lift, dynamic work-equipment rigid bodies, or
multiple terrain/payload writers. The old child outcomes remain historical
milestones, not implementation targets.

### R2. Run the release endurance gate

Run the existing release soak for 15 minutes per model against a fresh
`gateway-only` backend. SY205 and SY135 must independently satisfy the published
fixed-step, render, memory, telemetry, identity, single-runtime, track,
articulation, cut/load/dump/support, reset, and reconnect budgets.

### R3. Add an explicit quality-tier integration matrix

Extend the soak boundary so each result has an explicit `low`, `balanced`, or
`high` quality identity. Run a 90-second scenario for every model/tier pair. The
matrix must reuse the same product interaction path and must not maintain a second
quality-specific state machine.

### R4. Preserve compatibility of existing soak commands

`pixi run soak-jolt-quick` and `pixi run soak-jolt-release` must remain valid and
default explicitly to the balanced quality profile. Add one discoverable command
for the full quality matrix. Report schema/version changes must be validated by
backend tests rather than silently widening untyped JSON.

### R5. Record reproducible visual evidence

Use Godot AI MCP to inspect both models at each quality tier during loaded
interaction. Capture readable carry, dump/deposit, terrain scar/pile, and support
states. Commit a compact contact sheet and an evidence note that maps every capture
to model, quality profile, authority profile, and scenario state. Automated
counters alone do not satisfy this requirement.

### R6. Keep lifecycle and cleanup in the matrix

Every matrix cell must cover reset and reconnect, retain exactly one Jolt runtime,
and leave bounded telemetry history and visual-effect pools. Switching models or
quality profiles must not retain prior payload, particles, clods, or authority
identity.

### R7. Fail without expanding scope

Contract or harness defects discovered by these gates may be fixed in this task.
Material visual retuning, new physics features, or architecture changes require a
separate approved task. A failed evidence cell keeps this parent open and records
the failure instead of weakening thresholds.

## Acceptance Criteria

- [x] The parent planning artifacts identify all three archived 08-15 children and
      the archived 08-17 hybrid-Jolt roadmap as the superseding authority source.
- [x] `pixi run soak-jolt-release` passes for SY205 and SY135 at balanced quality,
      with 15 minutes of rendered runtime per model and the existing RC budgets.
- [x] A low/balanced/high by SY205/SY135 90-second quality matrix passes the same
      interaction, lifecycle, identity, memory, telemetry, and runtime-cardinality
      gates.
- [x] Soak reports carry validated model and quality-profile identity, while the
      existing quick/release commands remain compatible.
- [x] A committed contact sheet and evidence note show readable loaded bucket,
      dump flow/deposit, terrain change, and support response for both models at
      all three quality tiers.
- [x] `pixi run verify`, `pixi run backend-smoke`, the Godot standalone matrix,
      focused soak tests, provenance validation, and Trellis validation pass.
- [x] Final documentation describes evidence and current authority without
      claiming hydraulic, per-grain, or engineering-certified fidelity.
- [ ] The parent is archived only after every cell passes or any failed cell has
      been split into an approved follow-up task.

## Out Of Scope

- Reimplementing the three archived 08-15 children.
- Changing the hybrid Jolt authority boundary or adding dynamic work-equipment
  bodies, physics joint motors, hydraulics, per-grain soil, or full momentum chains.
- Production hardware controls, CAN/USB drivers, HMI, or legacy-runtime removal.
- Broad visual redesign or model calibration beyond fixing a demonstrated
  acceptance regression.
