# Implementation plan

1. [x] Centralize operator-facing copy and replace the diagnostic-first scene
       hierarchy with responsive operator, warning, action, guide, and Advanced
       sections.
2. [x] Present lifecycle/model state, selected-authority bucket fill, and
       cut/carry/dump feedback without leaking engineering diagnostics by
       default.
3. [x] Add keyboard/mouse and gamepad-readable onboarding with first-run
       dismissal and an always-available reopen action.
4. [x] Add confirmation and authoritative completion feedback for reset/model
       switch, including focus/pause/gateway/input re-arm recovery messages.
5. [x] Add a focused HUD contract covering 720p/1080p layout, both models,
       local/gateway state, prompt variants, generation clearing, and default vs
       Advanced information.
6. [x] Run focused/offline regression, one completion verification gate, update
       the frontend boundary, commit, and archive the child. Defer subjective
       visual approval to the final product-experience task.

## Risk and rollback

- `main.tscn` is shared; keep the change scoped to `OperatorUI` descendants.
- Confirmation state is presentation-only and must resynchronize from the
  authoritative model/lifecycle snapshot after cancellation, failure, reset,
  or model change.
- Preference I/O must not block offline startup.
