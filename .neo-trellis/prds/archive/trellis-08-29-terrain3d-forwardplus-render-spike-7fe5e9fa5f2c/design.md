# Design — Forward+ compatibility probe

Use a dedicated test runner/scene that instantiates the production adapter with
one accepted snapshot but does not mutate `main.tscn` defaults. Run it once with
the known demo material and once with Terrain3D's minimum shader override to
separate clipmap/height rendering from texture/material complexity.

The probe records renderer name, device, Godot version, addon version, native
class status, material resource status, queue/applied identity, map dimensions,
native/fallback visibility, and bounded current-run errors. A rendered capture
is evaluated for nonblank/non-uniform luminance and finite terrain silhouette;
the evidence does not claim subjective material quality.

Keep fixes behind the isolated probe seam until a real frame passes. If only an
addon/binary change resolves the issue, stop and return to parent planning.
