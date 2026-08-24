# Camera workflow presets

## Goal

Turn the current single mouse orbit into dependable views for driving, digging,
close inspection, and presentation on both excavator models.

## Requirements

- Provide operator/cab, chase-orbit, work-tool, and inspection modes with explicit
  names, discoverable switching, reset-view action, and smooth bounded transitions.
- Use model-specific framing hints derived from each visual contract/bounds; keep
  the machine, active tool, and work area readable during typical articulation.
- Add terrain/machine occlusion prevention and near-clip safety without affecting
  simulation collision.
- Support existing mouse orbit/zoom plus keyboard and gamepad view switching;
  suppress camera input while UI consumes it.
- Reset transient view state on model switch/generation and choose a safe fallback
  if a model anchor is absent.
- Respect low/balanced/high far distance and performance budgets.

## Acceptance criteria

- [ ] All four modes work on SY205 and SY135 and report the active mode in HUD.
- [ ] Standard travel/dig/carry/dump paths show no terrain or machine clipping and
      recover after temporary occlusion.
- [ ] Work-tool view retains bucket/ground context through boom/arm/bucket limits;
      chase view preserves travel direction; inspection remains freely orbitable.
- [ ] Mouse/keyboard/gamepad controls and reset are covered by deterministic tests.
- [ ] Model switching never follows a freed node or retains the previous model's
      incompatible framing.
- [ ] Balanced 1080p camera probes introduce no material frame-time regression.

## Out of scope

VR, cinematic timeline editing, free-fly level editor controls, and changing
machine articulation to improve a shot.
