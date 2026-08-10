# M6 research notes

- Godot project is Windows Forward+ with Jolt/D3D12 defaults; the imported
  SY205 combined GLB and five-frame manifest are already validated by M2.
- Existing scene has an empty `WorldEnvironment`, a directional key light, a
  fixed camera, derived terrain mesh and local excavation signal. M6 should
  configure these presentation nodes rather than replace motion/terrain code.
- The client boundary allows camera, lighting, PBR materials and disposable
  particles. Effects must be bounded, generation-gated and cleared on reset or
  authority changes; Python remains motion/input/lifecycle authority.
- A 60 FPS/1920×1080 target is a visual review gate, not a simulation clock.
