# Design: Generate SY205 URDF from GLB

## Generator Shape

Add `backend/scripts/generate_sy205_urdf.py` as a deterministic standard-library-first offline tool.
It may use NumPy already present in the backend environment for matrix and inertia calculations. It
must not import from `.agents/skills/` or use Godot/editor state as generation authority.

Inputs are the GLB, the visual manifest, and a checked-in estimation parameter JSON. Outputs are a
candidate URDF, evidence JSON, and the byte-identical future SY135 reference copy. Final files use
validated temporary sibling replacements.

## Extraction

1. Validate GLB header/chunks, source digest, JSON graph, required pivots, unit scales, and accessors.
2. Resolve the approved rigid visual descendants for base, upper, boom, arm, and bucket.
3. Decode POSITION accessors including byte offsets/stride and transform them into link-local Python
   coordinates.
4. Compute per-link AABB and deterministic candidate landmarks.
5. Render the URDF with stable ordering and float formatting.
6. Reparse the emitted XML and load it with Pinocchio before atomic replacement of candidate files.

## Estimates

The parameter file owns provisional total mass, per-link mass fractions, collision proxy policy,
tooth-front selection tolerance, and sensor landmark rules. Box inertias use the generated local
AABB and parallel-axis theorem. The evidence JSON records parameters and results so later CAD values
can replace estimates without reverse engineering the generator.
