# Design — operator onboarding and HUD

## Product information hierarchy

`MotionOperatorUI` remains a read-only presenter over `ProductSession`,
`MotionClient`, `TrackedChassisController`, and the selected soil-authority
snapshot. The always-visible panel leads with model and lifecycle, then current
operation, bucket fill, context-sensitive controls, warnings, and recovery.
Connection, authority identity, generation/revision, ACK, penetration,
engagement, velocity, and focus details move into an explicitly opened Advanced
section.

The HUD never derives payload from particles or legacy parcel nodes. Fill and
material generation come from `ExcavationWorld.get_selected_soil_payload_snapshot()`;
operation comes from the corresponding selected status and normalized digging
response. A world/material/ledger generation change clears transient operation
copy before the new selected snapshot is shown.

## Onboarding and controls

A centered, non-modal control guide is shown on first launch and can be reopened
from the HUD. Its dismissed state is stored in `user://operator_ui.cfg`; failure
to read or write preferences fails soft. User-facing copy is centralized in one
script and covers lifecycle, independent tracks, swing/boom/arm/bucket, camera,
model choice, reset, and the fact that digging/dumping is automatic physical
interaction rather than a separate command.

Keyboard/mouse and gamepad prompt variants use the established runtime input
contracts. The current prompt variant follows the most recently observed input
device, while a deterministic test seam can select either variant. Because
track and camera gamepad bindings do not yet exist, the guide states those
controls honestly instead of advertising unsupported mappings.

## Destructive actions and recovery

Reset and model changes stage an explicit confirmation that explains stopped
motion, cleared terrain/payload, and required neutral input re-arm. Only confirm
dispatches the local or gateway command. Completion is reported after the
authoritative generation/model transition is observed; cancellation restores
the authoritative model selection.

Focus loss, pause/stopped state, optional gateway unavailability, session error,
and neutral re-arm are mapped to short operator warnings. Diagnostics remain
available for troubleshooting without becoming the normal product experience.

## Layout and compatibility

The HUD uses container-driven minimum sizing, a bounded upper-left panel, a
centered guide, and native dialogs. It must remain within a 1280×720 safe frame
and scale through 4K. The same presenter supports SY205/SY135 and local/gateway
authority paths. No UI action mutates soil or physics directly.

## Validation strategy

Use one focused headless HUD contract for hierarchy, guide persistence seam,
prompt variants, confirmation behavior, soil generation clearing, and 720p/
1080p bounds. Reuse offline product/model-switch coverage for integration and
run the broader verification gate once at completion. Subjective visual review
is deferred to the final product-experience task for human evaluation.
