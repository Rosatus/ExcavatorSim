# Generate SY205 URDF from GLB

## Goal

Create a deterministic offline generator and candidate URDF/evidence artifacts from the unchanged
SY205 GLB without changing the backend runtime default.

## Requirements

- Validate the exact source GLB digest before extraction.
- Resolve nodes by full node-index path and the approved visual manifest, not by mesh centers or
  ambiguous names.
- Decode supported POSITION accessors and transform vertices into each owning link's local Python
  Z-up frame.
- Emit the four active joints and every required fixed frame with stable existing names.
- Use the approved GLB rest pose as joint zero and preserve current joint sign/range semantics.
- Emit conservative primitive visual/collision geometry and positive finite inertials from a
  checked-in estimation parameter set.
- Emit a JSON evidence manifest that distinguishes observed, validated, estimated, and retained
  provisional values and contains all input/output hashes.
- Preserve the byte-identical old URDF as `assets/model/library/sy135_reference.urdf` for future
  SY135 GLB work. It is not an SY205 runtime, replay, or rollback artifact.
- Do not modify the GLB, Godot import metadata, protocol constants, runtime paths, or default URDF.

## Acceptance Criteria

- [x] Two generation runs produce byte-identical candidate URDF and evidence JSON.
- [x] Invalid digest, malformed graph/accessor, non-finite data, missing pivot, non-unit moving scale,
      or invalid estimate fails without partial output.
- [x] Candidate URDF parses as XML and loads in Pinocchio with four DOF and all required names.
- [x] Generated joint origins/axes match the approved coordinate table exactly within float format
      tolerance.
- [x] All generated bounds, masses, centers, inertias, and collision dimensions are finite and
      positive, and provisional fields are identified in the evidence JSON.
- [x] Tooth/GNSS/IMU estimates are deterministic and attached to their intended parent link.

## Out of Scope

- Activating the candidate in production.
- Updating protocol/model version or parity fixtures.
- Dynamic validation of estimated physical fields.
- Modifying or re-exporting the GLB.
