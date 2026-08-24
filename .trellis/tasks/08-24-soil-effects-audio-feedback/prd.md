# Soil effects and audio feedback

## Goal

Give every important machine and soil action a coherent visual and audible
response so digging feels physical rather than silent and spherical/placeholder.

## Requirements

- Replace close-range sphere-looking soil flow/clods with shape, size, color,
  lighting, motion, and lifetime variation that still uses bounded pools.
- Improve bucket fill shading/geometry and transitions for capture, partial/full,
  carry, spill, dump, absorption, overflow, and settle.
- Add rate-limited dust/debris/contact accents driven by authoritative cut,
  resistance, parcel, track, impact, and lifecycle signals; never create soil
  volume from effects.
- Add runtime audio buses and layered feedback for engine/drivetrain, tracks,
  hydraulics/joints, digging resistance, soil/parcel impacts, dump/settle,
  warnings, pause/reset, with smooth gain/pitch parameters and no event chatter.
- Provide master/effects/machine UI controls or config, mute-safe state feedback,
  quality budgets, graceful missing-device/assets behavior, and provenance for
  every external recording.
- Clear loops/voices/effect state on pause, reset, model switch, focus loss, and
  teardown; support both offline and optional gateway authority.

## Acceptance criteria

- [ ] A blinded observer can distinguish travel, hydraulic work, active digging,
      carrying/dumping soil, impacts, warning, pause, and reset from feedback.
- [ ] Close dig/carry/dump evidence no longer reads as identical rigid spheres or
      an unlit flat bucket fill.
- [ ] Soil visual volume, bucket ledger, and terrain commits remain conserved and
      unchanged by presentation settings or audio availability.
- [ ] Voice/particle/clod concurrency and rate limits are explicit for all quality
      profiles; balanced 1080p retains the parent performance target.
- [ ] Audio has no stuck loops, clicks, runaway pitch/gain, or warning spam across
      pause/focus/reset/model switch.
- [ ] Provenance, focused lifecycle/mix/effects tests, visual review, and full
      regression gates pass for both models.

## Out of scope

Force-feedback hardware, licensed branded engine recordings without redistribution
rights, physically synthesized granular audio research, and simulation tuning to
manufacture effect triggers.
