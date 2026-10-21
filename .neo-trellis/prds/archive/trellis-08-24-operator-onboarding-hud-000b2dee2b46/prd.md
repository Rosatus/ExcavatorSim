# Operator onboarding and HUD

## Goal

Make the offline-first product understandable at launch and keep operator state,
soil state, warnings, and recovery readable during work without exposing
engineering diagnostics as the default experience.

## Requirements

- Consume the selected soil authority's versioned ledger/response snapshot; do
  not infer fill or action state from visible particle counts or legacy parcels.

- Present a concise first-run/recallable control guide for lifecycle, independent
  tracks, swing/boom/arm/bucket, camera, model selection, pause, and reset.
- Replace the fixed diagnostic stack with an operator hierarchy: model/lifecycle,
  current control/view hints, bucket fill and dig/carry/dump feedback, warnings,
  and recovery actions.
- Move gateway, authority IDs, epoch/generation/revision, ACK, penetration,
  engagement, velocities, and focus diagnostics behind an Advanced panel toggle.
- Explain that excavation is physical/automatic; do not restore manual Dig or
  Deposit product controls.
- Warn before destructive reset/model switch and clearly report their completion;
  focus loss, pause, unavailable gateway, and input re-arm remain visible and safe.
- Work at 1280×720 through 4K with keyboard/mouse and gamepad-readable prompts;
  preserve the optional gateway path and both models.

## Acceptance criteria

- [ ] A newcomer can find every essential control in-product and dismiss/reopen
      the guide without blocking operation.
- [ ] Default HUD contains no epoch/revision/ACK/penetration-style engineering
      values; all remain accessible through Advanced diagnostics.
- [ ] Start/pause/reset, focus loss, model switch, bucket empty/partial/full,
      cutting/carrying/dumping, and warning states have distinct readable feedback.
- [ ] Soil phase/fill UI clears at authority generation boundaries and shows no
      stale legacy parcel state after active-mode cutover or fallback.
- [ ] Reset/model switch consequences are clear and generation-safe.
- [ ] Layout tests cover 1280×720 and 1920×1080, both models, local/gateway states,
      and keyboard/gamepad prompt variants.
- [ ] Offline product, model switch, gameplay, visual, and standalone gates pass.

## Out of scope

Mission objectives, scoring/economy, key rebinding UI, localization beyond
centralizing user-facing strings, and changes to control physics.
