# Design — Terrain3D visible-backend restoration

## 1. Target architecture

```text
fixed-tick soil command
  -> selected SoilInteractionAuthority / TerrainCommitScheduler
  -> TerrainState accepted snapshot (sole height/material truth)
       |-> Terrain3DAdapter -> native Terrain3D clipmap + project soil shader
       |-> TerrainCollider -> identity-gated Jolt queries
       `-> TerrainRenderer -> synchronized fail-open visual fallback
```

Terrain3D owns visible native mesh materialization only. It cannot write
`TerrainState`, ledger volume, bucket payload, chassis pose, or query truth.
Terrain3D native collision remains disabled in the product profile.

## 2. Material composition

Create a project-owned Terrain3D shader override derived from the shipped
minimum/reference shader. Retain Terrain3D's required vertex path: clipmap
snapping, LOD geomorphing, region/height/control lookup, holes, normals, and
private uniforms. Replace only the fragment/PBR classification with the
current `TerrainRenderer` worksite-soil functions and constants.

The procedural palette remains texture-independent: compacted, loose,
disturbed, damp, track-lane, slope, distance breakup, roughness, and specular.
This removes the product dependency on Terrain3D demo grass/ground textures.
Sky3D continues to own horizon and lighting.

## 3. Presentation ownership and fallback

`TerrainWorld` selects one presentation owner at a time:

- approved native: Terrain3D visible, synchronized fallback hidden;
- native pending: keep the last valid native or fallback visible;
- native hard failure: full-sync and expose `TerrainRenderer`;
- Test Grid: native/dressing hidden, current authoritative fallback grid shown;
- leaving Test Grid: reapply the latest copied snapshot and restore the prior
  approved backend only after native success.

No state may show both coincident terrain meshes. Status distinguishes configured
backend, active renderer, material identity, queued/applied snapshot identity,
fallback reason, counters, and excluded dressing state.

## 4. Snapshot lifecycle

Startup, generation/reset/model boundary, stale recovery, material replacement,
or explicit resync use full materialization. A contiguous normal revision uses
dirty-region patching with its halo. A failed patch retains the old native
surface and retries once through full resync. A failed full import activates the
latest synchronized fallback. Stale epoch/generation/revision work never
replaces newer applied state.

## 5. Visual asset boundary

Disable native grass particles, native rock layers, green/grass control zones,
tree/foliage instancing, and infinite background. Keep the sibling
`ConstructionSiteDressing`, Sky3D, soil effect presenter, camera, UI, and
quality controller unchanged. Test mode hides all dressing through the existing
presentation profile.

## 6. Rollout

Phase 0 proves non-black native rendering on the target renderer before product
code switches. Phase 1 establishes material parity. Phase 2 hardens lifecycle
and fallback. Phase 3 proves authority/collider equivalence. Phase 4 alone may
change the product default and validate the exported build.

Rollback is immediate: keep `soil_shader` as an explicit supported backend and
make any native startup/material/map failure select it without restarting the
simulation. No persisted gameplay data migration is involved.
