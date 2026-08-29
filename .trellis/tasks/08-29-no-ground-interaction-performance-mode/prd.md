# Bucket pass-through performance mode

## Goal

Add an explicit in-game performance mode in which the excavator bucket passes
through visible terrain without collision response, cutting, loading, dumping,
or any other bucket-ground interaction. The mode must eliminate avoidable
bucket/soil work while keeping the machine driveable, the terrain visible, and
ordinary gameplay unchanged when the mode is off.

## Background

- Product terrain presentation defaults to Terrain3D, while gameplay terrain
  truth remains project-owned `TerrainState`, the selected soil authority, and
  the project `TerrainCollider`.
- Terrain3D native collision is already disabled. The bucket is a bounded
  kinematic mechanism whose project-owned proxy queries clamp articulation and
  may generate chassis support wrenches; track/chassis support is a separate
  query and heightfield-fallback path.
- Cutting and digging resistance read the authoritative heightfield directly,
  so bypassing only the proxy query would still deform soil and stall equipment.
- The current `automatic_soil_enabled` switch is not sufficient: the active
  soil authority and patch continue stepping when it is false.
- Active-patch representative integration, material transactions, synchronous
  terrain commits, collider chunk rebuilding, and soil effects are the main
  avoidable workloads identified for this mode.

## Requirements

### R1 — Product mode and controls

- Provide two explicit product states: `normal` and `bucket_passthrough`.
- Default to `normal` on every application launch. Do not persist the selection
  to `user://` or project settings.
- Provide a game UI toggle labelled clearly as bucket pass-through/performance
  mode, with a tooltip stating that enabling it clears current bucket and
  transient soil material.
- Accept a toggle request immediately and commit it at one fixed-tick boundary;
  expose requested, active, and transition/error state so the UI cannot claim a
  mode that failed to apply.
- Keep the selected mode across start/pause, reset, reconnect, model switch,
  Test Grid, Terrain3D fallback, and Terrain3D recovery for the current process.
  A new process always starts in `normal`.

### R2 — Bucket pass-through behavior

- In `bucket_passthrough`, accept the normal operator articulation commands but
  do not run bucket/terrain proxy sweeps, clamp articulation against terrain,
  probe cut penetration, generate/apply bucket support wrenches, or submit the
  legacy bucket ground-lift response.
- The bucket must be able to visibly cross below and through the authoritative
  terrain surface without physical correction or digging resistance.
- Continue track/chassis terrain collision, support probes, heightfield
  fallback, traction, attitude stabilization, and locomotion unchanged.
- Keep Terrain3D/fallback terrain rendering, the project terrain collider, site
  dressing, camera, controls, and non-soil telemetry operational.

### R3 — Soil and material bypass

- Do not classify, cut, scrape, grade, compact, load, spill, dump, settle, or
  otherwise mutate terrain/material state from bucket motion in pass-through
  mode.
- Do not step `SoilInteractionAuthority`, `ActiveSoilPatch`, legacy soil/parcels,
  bucket-cell settlement, bucket-generated terrain commits, or dynamic soil
  effects while bypassed.
- Entering the mode deliberately clears bucket payload, active/released soil,
  parcels, pending bucket material transfers/brushes, payload feedback, pose
  history, and interaction/support state. This loss is accepted and is not
  recorded as a conservation transfer.
- Do not revert terrain edits that were committed before mode entry.
  `TerrainState.world_generation`, terrain revision, and persistent field bytes
  remain as they were at the transition; the separate material/soil authority
  generation advances to a new empty ledger.
- Exiting the mode starts ordinary interaction from an empty, clean material
  generation; no suppressed work, stale support request, pose sweep, or material
  transfer may replay after exit.
- Existing reset/model-switch/reconnect cleanup semantics remain authoritative
  and apply normally while the mode stays selected.

### R4 — Diagnostics and performance evidence

- Expose mode identity and monotonic submitted/executed/bypassed counters for
  bucket query, support response, soil-authority/patch step, terrain commit, and
  soil-effects work without logging every tick.
- Advanced UI diagnostics must show the active mode, whether payload was
  cleared at the last transition, and the relevant bypass counters.
- Add deterministic tests proving expensive work is skipped rather than merely
  hidden, plus paired warmed performance runs comparing identical normal and
  pass-through command traces.
- Preserve current standalone/release ceilings. For both production models at
  balanced quality, the median of repeated paired pass-through runs must have a
  lower fixed-step p95 than the corresponding normal digging trace; record raw
  and comparative results as task evidence.

## Acceptance Criteria

- [ ] A visible in-game toggle changes `normal -> bucket_passthrough -> normal`
  at a fixed-tick boundary and reports the real active state; a restart returns
  to `normal`.
- [ ] For SY205 and SY135, the bucket crosses through terrain under normal
  equipment input with full accepted motion, zero bucket support response, zero
  cut resistance, and no chassis lift caused by the bucket.
- [ ] Track/chassis support, traction, steering, terrain identity, and ordinary
  driving remain valid while the bucket is below the terrain.
- [ ] Entering pass-through clears all selected bucket payload and transient
  active/released material without changing already-committed terrain bytes,
  `TerrainState.world_generation`, terrain revision, or persistent terrain field
  state; `_material_generation`/soil authority generation advances and the
  selected soil ledger starts empty.
- [ ] Across a fixed pass-through trace, terrain digest/revision and persistent
  material state stay unchanged; cut/load/dump/settle transactions remain zero;
  bucket payload stays empty; relevant executed counters do not advance and
  bypass counters do.
- [ ] Exiting pass-through cannot replay pre-toggle support, pose history,
  transfer, or brush work; a subsequent ordinary dig produces the existing
  query/contact/cut/payload/terrain behavior.
- [ ] Start/pause, reset, reconnect, model switch, Test Grid, Terrain3D
  fallback/recovery, and focus loss preserve the selected mode and maintain
  their existing safety/lifecycle behavior.
- [ ] The full focused and standalone regression suites pass in ordinary mode,
  and source/export smoke tests report equivalent pass-through behavior.
- [ ] Repeated paired balanced-quality runs for both models meet existing
  release ceilings and show lower median fixed-step p95 in pass-through mode;
  work counters demonstrate elimination of the targeted soil/query workload.

## Out of Scope

- Making the whole excavator fall through terrain or disabling track/chassis
  ground support.
- Hiding terrain, changing Terrain3D/fallback selection, material appearance,
  site dressing, plants, lighting, or camera quality.
- Replacing Terrain3D, `TerrainState`, the selected soil owner, Jolt authority,
  or the project terrain collider architecture.
- Preserving, transferring, settling, or restoring payload/transient soil when
  the mode is enabled.
- Persisting the mode across application restarts, adding a command-line/API
  setting, or changing CAN/ICT/Gateway behavior.
- Changing CAN IDs/payloads, telemetry wire schemas, or Python motion authority.

## Key Decisions

- The mode is bucket-only; track/chassis terrain support remains enabled.
- It is a runtime interaction policy, not a Terrain3D backend, visual-quality
  profile, soil-owner mode, or simulation-authority profile.
- Mode changes apply at a fixed-tick boundary and are process-local.
- Enabling the mode intentionally discards all bucket/transient soil material
  and starts a clean material generation without reverting persistent terrain.
- Normal mode remains the launch default and the existing product behavior.
