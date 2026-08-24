# Game feel digging response

## Goal and user value

Make soil contact and bucket loading feel weighty through readable, bounded
motion response without implementing a professional hydraulic simulation.

## Dependency

Requires the versioned response inputs and ledger from
`08-24-conservative-soil-material-lifecycle`.

## Requirements

- Derive normalized phase/intensity from semantic tool role, accepted displaced
  volume/rate, material preset, fill ratio, overflow, motion direction, and
  persistent/active contact state.
- Apply smooth work-equipment command speed scaling only where the current motion
  works against soil. Free/retracting motion must recover promptly.
- Use an explicit safe nonzero clamp, attack/release rates, hysteresis, and
  blocked-state escape so soil cannot permanently trap the controls.
- Expose stable phase/intensity/flow/fill telemetry for VFX, audio, camera, HUD,
  and tests. These consumers cannot feed values back into the ledger.
- Tune SY205 and SY135 through data profiles while preserving identical response
  semantics and neutral/reset/model-switch behavior.
- Do not publish fabricated pump pressure, cylinder force, engine torque,
  structural stress, or engineering force values.

## Acceptance criteria

- [ ] Free motion, contact, scrape, productive cut, near-full loading, overflow,
      dump, and blocked motion produce distinct recorded response curves on both
      models.
- [ ] Productive cutting visibly slows compared with free motion; disengagement
      returns to normal smoothly, and moving away from resistance is never
      incorrectly slowed as if cutting deeper.
- [ ] Speed scale remains inside its documented safe range, contains no one-tick
      spikes/chatter, and cannot prevent reset, neutral, model switch, or a
      bounded operator escape from contact.
- [ ] Identical fixed-step inputs produce deterministic phase/intensity and
      response curves independent of rendering/audio quality.
- [ ] Muting or disabling presentation does not change motion scale, material
      transactions, or payload.
- [ ] Focused response, neutral/re-arm, both-model, lifecycle, and standalone
      regression tests pass with balanced 60 FPS evidence.

## In scope

Normalized game-feel contract, work-equipment speed scaling, material/model
profiles, smoothing and recovery, presentation telemetry, tuning evidence,
tests, and specs.

## Out of scope

Hydraulic circuits, pump/valve/cylinder simulation, calibrated force or torque,
joystick force feedback, chassis/track resistance redesign, or final audio/VFX
asset production.
