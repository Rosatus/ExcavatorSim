# Construction site visual polish

## Goal

Make the environment read as a purposeful excavator worksite with believable
scale, materials, depth, and machine-ground integration while preserving
determinism and terrain authority.

## Requirements

- Consume persistent-field/active-patch dirty snapshots from the separate soil
  rebuild after that contract stabilizes; site presentation never owns material.

- Establish a clear work area, dig face, spoil zone, travel space, boundaries, and
  distant composition using quality-bounded props and terrain dressing.
- Improve logical/fallback terrain materials with readable loose soil, compacted
  ground, damp/low-area variation, macro color breakup, normals, and distance
  behavior; Terrain3D success must not define a different product identity.
- Add scale cues such as barriers, stakes/signage, tire/track context, aggregate
  piles, and site equipment chosen from code-native or provenanced assets.
- Tune fixed daytime lighting, contact shadows, fog/depth, color, and exposure so
  both yellow machines separate from terrain without dynamic weather/time.
- Improve contact presentation around tracks, bucket, and disturbed soil without
  writing back to authoritative terrain or physics.
- Blend active disturbed soil and newly settled loose terrain into Terrain3D and
  fallback surfaces without seams, double piles, or a different product identity.
- Preserve low/balanced/high budgets, deterministic placement, offline packaging,
  and asset provenance.

## Acceptance criteria

- [ ] Screenshots clearly communicate work zones and excavator scale without text.
- [ ] Loose/disturbed, compacted, damp, and background terrain remain distinct at
      work distance and close range on Terrain3D and fallback paths.
- [ ] SY205/SY135 silhouettes, bucket, tracks, and contact areas remain readable
      under the fixed baseline lighting.
- [ ] Props never obstruct spawn, acceptance journeys, camera presets, or Jolt
      collision unless a separate explicit collider contract exists.
- [ ] Balanced 1080p meets the 60 FPS target; low/high profiles enforce documented
      dressing, shadow, fog, and texture budgets.
- [ ] Provenance, visual pass, terrain, offline, and standalone gates pass.

## Out of scope

Dynamic weather/day-night, large open world streaming, authoritative prop
collision gameplay, replacement machine assets, and soil authority changes
inside this presentation task.
