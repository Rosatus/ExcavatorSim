# Design — product usability and visual experience polish

## Workstream architecture

The parent task is an acceptance program, not one monolithic implementation.
Six ordered children own evidence, HUD/onboarding, cameras, site presentation,
feedback/audio, and final validation. Each child makes an atomic local commit,
runs its focused and regression gates, and records before/after evidence before
the next child builds on it.

Authoritative simulation state remains in ProductSession, the Jolt controllers,
BucketSoilState, TerrainState, and existing model contracts. New presentation
controllers may observe signals/snapshots and keep ephemeral UI/effect state;
they may not mutate physics results, soil volume, terrain identity, or backend
compatibility to obtain a prettier result.

## Evidence contract

The standard core evidence matrix is model × low/balanced/high quality ×
carry/dump/terrain/bucket-ground-support at 1920×1080. Balanced additionally
captures startup, controls-visible, travel, dig, and reset/recovery so the
carry/dump cells complete a seven-checkpoint operator journey. Each artifact
records commit, Godot version, model, quality, resolution, authority profile,
lifecycle, checkpoint, error-log outcome, and a comparable performance sample.
Capture framing is deterministic; interactive operator smoke supplements rather
than replaces scripted evidence. The baseline rubric scores discoverability,
hierarchy, camera, model framing, site composition, lighting/materials, soil
feedback, audio, and recovery.

## Presentation boundaries

- `OperatorUI` (or extracted presenters) owns product HUD/onboarding and an
  opt-in diagnostic panel.
- `CameraRig` owns view modes, framing profiles, transitions, collision probes,
  and input; model data supplies framing hints without changing model authority.
- construction-site/environment code owns dressing, materials, scale cues, and
  quality-bounded presentation outside the logical terrain region.
- soil/effect/audio presenters consume authoritative events and telemetry through
  rate-limited pools/buses. Missing presentation assets fail soft and never stop
  simulation.

## Compatibility and rollback

Every workstream retains the offline default and optional gateway path. Feature
controllers must clear transient state on reset, model switch, authority epoch,
and teardown. Each child can be reverted independently; evidence and specs remain
useful even if an individual visual experiment is rolled back.
