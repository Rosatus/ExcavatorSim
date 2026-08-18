# Jolt Authority Cutover And Legacy Retirement Boundary

## Goal

Make the validated Jolt-authoritative profile the product default, prove that Godot
is the only runtime motion/contact authority, and retain the old Python kinematic
runtime only as an explicit compatibility profile with documented rollback.

## Dependency

Requires accepted sensor/gateway delivery from
`08-17-sensor-telemetry-python-gateway` and all earlier roadmap children.

## Requirements

- Switch default product startup/profile/UI to `jolt_authoritative` only after all
  parent and child acceptance gates pass.
- Stop Python `Simulator`/Pinocchio view snapshots from entering the Jolt product
  presentation path; Python remains gateway/lifecycle/telemetry integration.
- Keep `python_kinematic` behind an explicit compatibility launcher/selection with
  separate session, schema, and authority identity.
- Remove or disable obsolete Jolt-mode kinematic chassis, visual ground-lift, pose
  feedback, and duplicate contact paths without changing legacy behavior.
- Complete reset/disconnect/model/profile switch, stale transport, unavailable
  gateway, invalid rig, and terrain lifecycle acceptance with no mixed writers.
- Establish performance budgets, soak evidence, operational diagnostics, migration
  notes, rollback procedure, and updated source-of-truth documentation.
- Do not delete legacy recording/replay/terrain/Pinocchio code in this task; later
  removal requires a separate inventory and approval.

## Acceptance Criteria

- [ ] Default startup reaches Jolt authority for SY205 and SY135 and exposes one
      authority epoch/tick source across visuals, truth, sensors, terrain, payload,
      and contacts.
- [ ] Runtime assertions/tests detect any Python or legacy Godot transform writer in
      the Jolt profile.
- [ ] Full operator scenarios cover tracks, mixed articulation, loaded digging,
      support/lift, dump, reset, reconnect, model switch, and gateway loss.
- [ ] Fixed-step overruns, frame performance, contacts/bodies, queues, telemetry
      drops, and long-run stability meet recorded release budgets.
- [ ] Explicit legacy startup still passes its compatibility suite and rollback
      requires a clean session/profile rebuild.
- [ ] Architecture, specs, README/start commands, protocol/version manifests, and
      release-candidate evidence describe the shipped authority accurately.

## Out Of Scope

- Deleting legacy Python subsystems, production hardware rollout, engineering
  certification, or adding new sensor families.

