# Implementation Plan: Align Godot With SY205 URDF v4

1. [x] Update the Godot model-version constant and fake handshakes.
2. [x] Regenerate/update the Godot parity fixture and visual-manifest fixture hash.
3. [x] Update tests that encode the old model identity or old backend transforms.
4. [x] Run focused motion/pivot/linkage tests.
5. [x] Run the normal standalone matrix and one MCP runtime smoke.
6. [x] Archive the child tasks and complete the parent integration review.

Exit gate: Godot accepts and presents the active SY205 backend model under ordinary automated and
runtime smoke checks.
