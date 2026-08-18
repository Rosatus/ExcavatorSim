# Sensor Telemetry Gateway

The `sensor_telemetry_v1` capability is an observational Godot-to-Python
gateway. Godot produces samples from the accepted fixed-tick hybrid truth; the
Python gateway validates, orders, rate-limits, stores a bounded latest batch,
and reports freshness. It never calls `Simulator.step()` or Pinocchio FK to
reconstruct a sample.

Every batch carries session/simulation/model/rig/calibration identity,
authority epoch, physics tick, monotonic sample clock, batch sequence and the
`godot_fixed_tick` source. Samples carry sensor/frame identity, stream sequence,
units, canonical Z-up basis, validity, quality, raw value, and noise metadata.

The transport is latest-value and may drop batches. The bounded store expires
after one second, rejects duplicate or stale batch/stream sequences, and clears
on disconnect, stop, reset epoch, or model switch. Legacy RRD columns remain
unchanged; telemetry is not silently projected into recording data.

The initial producer set is four encoders, four declared IMUs, GNSS, combined
track/contact, and bucket payload/load. The default noise profile is explicitly
zero sigma with raw and observed values both retained; later tuning may add
bounded noise without changing the truth contract.

Kind layouts are part of the gateway contract: encoder values are
`[position_rad, velocity_rad_s, effort_n]`; IMU values are 15 numbers containing
the row-major canonical rotation matrix, angular velocity, and specific force;
GNSS values are position followed by velocity; track/contact has six values and
payload has four. The gateway rejects a batch whose value length or unit string
does not match its kind.
