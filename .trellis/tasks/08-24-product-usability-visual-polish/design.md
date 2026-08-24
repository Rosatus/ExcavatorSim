# Design — product usability and visual experience polish

## Workstream architecture

The parent task is an acceptance program, not one monolithic implementation.
Six visual children own evidence, HUD/onboarding, cameras, site presentation,
feedback/audio, and final validation. A separate prerequisite parent,
`08-24-gameplay-soil-interaction-rebuild`, owns the new soil authority and its
five migration stages. Each child makes an atomic local commit and runs focused
and regression gates; visual soil integration waits for stable read contracts.

Authoritative simulation state remains in ProductSession, the Jolt controllers,
and the selected soil-authority generation. During migration that generation is
either legacy `BucketSoilState`/`TerrainState`/parcels or the new persistent-
field/active-patch/material-ledger owner—never both. New presentation controllers
may observe signals/snapshots and keep ephemeral UI/effect state; they may not
mutate physics results, soil volume, terrain identity, or backend compatibility
to obtain a prettier result.

## Evidence contract

The standard core evidence matrix is model × low/balanced/high quality ×
carry/dump/terrain/bucket-ground-support at 1920×1080. Balanced additionally
captures startup, controls-visible, travel, dig, and reset/recovery so the
carry/dump cells complete a seven-checkpoint operator journey. Each artifact
records commit, Godot version, model, quality, resolution, authority profile,
soil-authority mode, lifecycle, checkpoint, error-log outcome, and a comparable
performance sample. Capture framing is deterministic; interactive operator smoke supplements rather
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
- soil/effect/audio presenters consume accepted transfer, active-patch, ledger,
  and normalized response snapshots through rate-limited pools/buses. Missing
  presentation assets fail soft and never stop simulation. Legacy parcels are
  primary transport only in legacy mode and optional hero clods in the new mode.

## Compatibility and rollback

Every workstream retains the offline default and optional gateway path. Feature
controllers must clear transient state on reset, model switch, authority epoch,
and teardown. Soil authority changes require a clean generation and are owned by
the separate soil parent. Each visual child can be reverted independently;
evidence and specs remain useful even if an experiment is rolled back.
