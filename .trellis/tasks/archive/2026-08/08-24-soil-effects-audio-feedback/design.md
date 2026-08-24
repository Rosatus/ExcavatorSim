# Design — soil action presentation and audio feedback

## Read-only feedback snapshot

`ExcavationWorld.get_soil_visual_snapshot()` remains the feedback input and is
extended with selected source/ledger identity, bucket volume/mass, accepted
transaction identity/kind/volume, and interaction-batch identity. All fields are
copies of selected authority, fixed-tick response, and accepted transfer state.
Presentation code cannot queue brushes, move ledger compartments, change Jolt
commands, or manufacture soil events.

## Visual feedback

`SoilEffects` retains bounded flow and hero-clod pools but replaces uniform
spheres/unlit fill with shaded irregular grains/clods, deterministic per-spawn
shape variation, smoother fill visibility, and a second bounded dust/contact
accent driven by normalized contact/scrape/cut/blocked intensity. Generation,
pause, focus loss, and teardown stop emission and recycle every transient.

## Procedural audio runtime

`MachineFeedback` is a read-only presenter over ProductSession, selected soil,
and chassis snapshots. Three prebuilt 11.025 kHz `AudioStreamGenerator` loops
represent engine, tracks, and work equipment. They use bounded gain/pitch from
lifecycle, track speed/slip, raw equipment commands, and normalized digging
intensity—not pressure, flow, cylinders, engine load, or calibrated force.

A fixed `AudioStreamPlayer` pool plays code-generated short PCM cues for
accepted cut/dump/settle, contact/impact, lifecycle, and warnings. Transaction/
batch identities and cooldowns prevent chatter. No external recording is added,
so no new audio provenance dependency exists.

Runtime-created `Machine` and `Effects` buses feed Master. Project settings own
master/machine/effects dB defaults; the HUD exposes mute and mute-safe state.
Missing/dummy audio devices fail soft while state/VFX remain available.

## Lifecycle and quality

Pause, stopped lifecycle, focus loss, reset, model switch, authority generation,
and teardown stop loops, clear generator buffers, recycle voices, clear event
cooldowns, and advance the feedback generation. Low/balanced/high allow 1/3/3
loops, 2/4/6 voices, and explicitly bounded dust/particle/clod rates.

## Validation strategy

One headless feedback contract asserts action mapping, gain/pitch clamps,
transaction cooldown/deduplication, quality caps, mute, and lifecycle cleanup
without judging sound. Existing visual/offline tests cover effects budgets and
authority conservation. Human listening and close-range visual approval are
deferred to final product-experience validation.
