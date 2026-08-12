# Godot/Pinocchio RRD Profile V1

Profile id: `godot-pinocchio/rrd-v1`. Producer/reader SDK: exactly `rerun-sdk==0.35.0`. The Godot/Pinocchio service
accepts this profile only; arbitrary Rerun recordings are out of scope. The profile stays motion-only:
the importer accepts producer metadata `protocol_version` `godot-pinocchio-v2` or `godot-pinocchio-v3`, but
terrain entities remain forbidden and do not change RRD v1 semantics.

Every temporal row has the duration timeline `recording_time` (`duration[ns]`) and sequence timeline
`sample_sequence`. `/godot_pinocchio/metadata` is one static AnyValues row containing profile, protocol,
state, model, calibration, software and Rerun versions, exact joint order, SI declaration, sample
count/range and source mode.

Required temporal entities are:

- `/godot_pinocchio/signals/joints/{joint}/{position|velocity|acceleration}` as float64 Scalars in rad,
  rad/s, or rad/s² for `swing_joint`, `boom_joint`, `arm_joint`, and `bucket_joint`;
- `/godot_pinocchio/signals/simulation_time` as float64 Scalars in seconds;
- `/godot_pinocchio/state/source_sequence` as exact uint64 AnyValues;
- `/godot_pinocchio/state/last_input_sequence` as nullable uint64 AnyValues;
- `/godot_pinocchio/events/lifecycle` as StateChange strings;
- `/godot_pinocchio/events/quality` as sorted JSON TextLog snapshots.

Exactly one recording store is accepted. Import fails closed on missing paths or indexes, incompatible
metadata, duplicate/misaligned timestamps, non-finite telemetry, invalid ordering, more than 360,000
samples, or files larger than 256 MiB. Exact integer/event/version fields and float64 telemetry must
round-trip exactly; replay FK matrices must agree within `1e-9`.
