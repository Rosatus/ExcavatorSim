# Design: Align Godot With SY205 URDF v4

## Alignment Set

Update the Godot model-version constant, fake handshake data, parity fixture, and fixture hash in the
SY205 visual manifest. No new coordinate conversion or presentation layer is introduced.

Godot continues to:

- convert Python transforms once at the transport boundary;
- apply adjacent parent-child rotation deltas to imported local pivots;
- preserve imported local origins and scales;
- solve the passive four-bar linkage after driven pivots.

## Validation

Use the existing automated motion/pivot/linkage tests, the normal standalone test matrix, and a
single MCP runtime smoke at zero plus an asymmetric pose. Additional release-style visual approval
is not required for this URDF replacement.
