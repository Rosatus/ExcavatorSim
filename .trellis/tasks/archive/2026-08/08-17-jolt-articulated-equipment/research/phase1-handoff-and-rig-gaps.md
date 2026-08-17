# Phase 1 Handoff And Rig Gaps

## Accepted Foundation

- `JoltChassisTrackRuntime` is the Phase 1 physical owner and currently creates
  only the chassis body. Extend this owner rather than composing a parallel rig.
- `TrackedChassisController` owns profile/model/terrain lifecycle and synchronizes
  the presentation root from the physical chassis.
- `SimulationTruthPublisher` has an authoritative local-truth path, but Phase 1
  still fills upper/equipment bodies and joints from frozen placeholders.
- Both rig descriptors already declare five bodies and four joints, with
  provisional mass, inertia, collision, and actuator parameters.

## Contract Gaps To Close First

- Add explicit body rest transforms and parent/child joint anchors. The current
  `frame` name alone is insufficient to construct a non-ambiguous Jolt joint.
- Validate unique names, exact topology, unit axes, ordered finite limits, frame
  ownership, and catalog/model/rig identity before creating nodes.
- Derive anchors from validated visual-manifest rest transforms offline, then bind
  them in the versioned descriptor. Do not consume legacy `frame_map.pivot_axis`
  as runtime authority.
- SY205 calibration remains less mature than SY135; controlled rest and signed
  single-axis parity must gate actuator tuning.

## Runtime Boundaries

- Sample the existing four work-equipment axes once per fixed tick and pass the
  accepted sequence to the physical owner.
- Capture one immutable post-step snapshot. Presentation and truth publishing must
  consume the same snapshot rather than reading different node graphs.
- Keep the SY205 four-bar visual-only: physical arm/bucket angles are inputs; only
  passive visual nodes are outputs.
- Disable the legacy kinematic bucket lift path in Jolt-authoritative mode. Terrain
  mutation and soil transactions remain Phase 3 work.
- Rebuild the complete chain for reset, authority epoch, model, and profile changes;
  clear contacts/actuators/payload caches and require neutral re-arm.

## Minimum Evidence

- Descriptor negative tests and rest/axis parity for both models.
- Positive/negative isolated joint motion and hard-limit convergence for all four
  joints on both models.
- Mixed-axis, loaded holding/slowdown, chassis reaction, and long-run finite tests.
- SY205 passive-linkage length/plane/branch/last-valid invariants with no added
  physical linkage body or joint.
- Lifecycle tests proving no residual bodies/joints across reset, disconnect,
  invalid descriptor, epoch, model, and profile transitions.
