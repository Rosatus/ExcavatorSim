# Implementation plan — Forward+ compatibility probe

1. Record the exact Godot, renderer, GPU, Terrain3D, and GDExtension baseline.
2. Add an isolated rendered probe and bounded status/log capture.
3. Reproduce with the existing demo material and current adapter ordering.
4. Bisect material/texture/configuration versus minimum shader/map/clipmap path.
5. Implement the smallest project-owned compatibility fix.
6. Run real Forward+/D3D12 capture plus deliberate-failure fallback check.
7. Run relevant terrain/adapter state tests and repository verification.
8. Write a research result with cause, fix, unsupported alternatives, and Phase
   1 material interface. Do not change the product default.

Stop if the solution requires unplanned vendored C++/binary replacement.
