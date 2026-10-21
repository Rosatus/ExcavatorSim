# Implementation Status

## Accepted verification boundary

The QML/reference repository is the immutable semantic authority. This task's
final gate is code-path and mathematical parity, not a native or live QML run.
The local machine has no usable C++/Qt compiler or prebuilt reference binary,
and the user explicitly accepted source-level tracing as sufficient.

## Closed contracts

- The historical 5,770-frame CSV and replay parser agree on CAN ID, DLC and
  payload bytes.
- Godot pose truth is taken from the authoritative post-step `upper` and link
  transforms. The headless checkpoint locks neutral adjacent rotations to
  swing `0`, boom `+35`, arm `-90`, bucket `-50` degrees.
- The Python profile mapper implements the inverse of the reference
  `ProtocolParser -> GuidancePeriodicService -> lib_kin` body and joint path.
- QML main antenna position follows `GNSSA = O - Exca * GO`; successive main
  antenna samples determine velocity.
- QML A800 is signed big-endian; the other covered payloads keep their
  field-specific order. Extended raw CAN IDs receive `CAN_EFF_FLAG`.
- Profile/calibration loading, pose projection and family emission fail closed;
  a profile mapping error cannot fall back to legacy values or emit a partial
  family.

## Deliberate limits

- The bundled calibration is the reference repository's deterministic
  ground-truth fixture, byte-bound by SHA-256. A deployment-specific calibration
  may replace it only when its exact bytes and expected hash are supplied.
- The vice antenna offset is explicit synthetic profile data because field mount
  geometry is unavailable. It does not affect the QML 3D excavator pose path.
- No QML/reference source files were modified.
