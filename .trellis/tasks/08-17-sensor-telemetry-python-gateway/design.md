# Design

## Producers

After each physics step, an immutable truth snapshot is captured. Per-sensor
schedulers sample/interpolate only from accepted truth history and declared sensor
mount frames. Sensor clocks use simulation monotonic time; wall/device receive time
is gateway metadata, not the sample clock.

## Initial Sensors

- Encoders: actual joint position/velocity and target/saturation diagnostics.
- IMUs: orientation, angular velocity, and specific force at four declared frames;
  gravity convention and derivative filter are explicit.
- GNSS: canonical position/velocity and validity/noise.
- Track/contact: side speed, slip, contact state/load summaries.
- Payload/load: mass, local COM, fill, resistance, and quality.

Truth and noisy observation are distinct message kinds or explicitly tagged fields.
Noise configuration has a version/hash and seeded behavior for tests without making
full Jolt replay deterministic.

## Transport And Gateway

Use versioned negotiated message families, bounded batch size/rate, and one shared
decoder per payload. Latest-value high-rate telemetry may drop with counters;
recording batches preserve explicit sample sequence and gap markers. Legacy RRD is
not extended silently.

Python exposes health/freshness, bounded recording/export, and subscriber/device
adapter interfaces. External commands carry source, sequence, lease, and client
time; Godot revalidates them and owns expiry.

## Rollback

Disable telemetry/sensor capabilities without affecting Jolt authority. The Python
gateway may be absent for local keyboard operation; missing telemetry transport is
observable but cannot stop the local physics loop unless a selected external-control
policy explicitly requires it.

