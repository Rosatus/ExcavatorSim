# Implementation plan

1. [x] Add a scene-level release candidate test using the existing MotionClient
   fake transport and authority-generation signal seams.
2. [x] Ensure reconnect/epoch callbacks clear bucket and particle state while
   stale pose data remains rejected.
3. [x] Add the complete Godot headless test matrix and a concise test README;
   preserve the backend motion-only and legacy suites.
4. [x] Run MCP scene/UI/runtime smoke, `pixi run verify`, and review retention
   decision/docs before archiving the parent milestone.

Exit gate: [x]

## Scope guard

No protocol version change, remote terrain authority inversion, GLB replacement,
dynamic rigid-body authority, replay rewrite or automatic legacy cleanup.
