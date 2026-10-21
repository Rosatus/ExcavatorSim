# SY135 Model Switching Design

## 1. Design Goals

1. Treat a model as one reviewed descriptor, not independent GLB and URDF choices.
2. Keep Python/Pinocchio authoritative for motion and keep Godot visual adaptation presentation-only.
3. Change models only at a fresh simulation-session boundary.
4. Preserve SY205 as the default and preserve its current identifiers and behavior.
5. Fail closed on unknown identities, import-contract drift, active-session conflicts, or visual/backend disagreement.

This remains one Trellis task because the backend selection, wire identity, Godot asset activation, and lifecycle clearing form one atomic user-visible contract; none is independently shippable.

## 2. Model Descriptor Contract

Add a versioned structured model registry under `assets/model/`. Each descriptor contains:

- stable `model_id` and display name;
- `model_version` and `visual_model_version`;
- repository-relative URDF path and expected SHA-256;
- Godot GLB path/SHA, visual manifest path, and parity fixture path;
- the calibration path/version used by the backend;
- capability/policy fields such as passive linkage mode and excavation contact contract.

The initial descriptors are:

| Model | Model ID | Backend model version | URDF | Visual policy |
|---|---|---|---|---|
| SY205 | `sy205` | existing `sy205-glb-urdf-v4` | existing active URDF | existing combined GLB, four-bar linkage, existing tooth offset |
| SY135 | `sy135` | new `sy135-reference-urdf-v1` | preserved `library/sy135_reference.urdf` | supplied combined GLB, no passive linkage unless import evidence proves one, validated `REF_BUCKET_TIP` |

`paths.py` keeps compatibility aliases for the default SY205 paths. A typed backend resolver validates the registry and returns a complete immutable descriptor. A Godot-local catalog binds the same IDs/versions/hashes to `res://` resources. Automated parity checks compare both catalogs so either side cannot drift silently.

`protocol/version-manifest.json` remains the default/global version source, with SY205 values preserved. Runtime hello/state/recording builders override the two model-specific version fields from the selected descriptor. The protocol schema accepts the selected model identity structurally; application validation requires an exact known descriptor match.

## 3. Backend Session Manager

Introduce a small `RuntimeSessionManager` above `RuntimeController`. It owns:

- the model registry and selected descriptor;
- construction of `ExcavatorModel`, calibration, `RuntimeController`, replay, recording, and exchange state;
- start/stop lifecycle for the current runtime;
- an incrementing selection generation and active WebSocket session count;
- atomic selection under one lock.

`RuntimeController` remains a single-model authority object. It does not grow a hot-reload method.

Selection rules:

1. CLI starts with `--model sy205` by default and may select a reviewed model explicitly.
2. Godot includes `requested_model_id` in `hello`.
3. If it matches the current descriptor, handshake proceeds normally.
4. If it differs and no established session remains, the manager stops/disposes the old runtime, builds and starts a fresh runtime, then acknowledges the new descriptor.
5. If another session remains active, the server returns `model_switch_busy` and closes the attempted session. It never changes the process model underneath an active peer.
6. Unknown/unavailable/desynchronized descriptors return a stable non-recoverable selection error.

All request handlers resolve the current runtime/descriptor through the manager. `/api/model`, `/health`, hello versions, live state, recording/replay metadata, and import validation therefore use the same selection. Legacy recording buffers are newly constructed on every model session and cross-model RRD import remains rejected.

## 4. Protocol And Reconnect Sequence

The existing v3 transport gains additive model-selection fields rather than a parallel control channel:

- client `hello.requested_model_id`;
- server `hello_ack.model_id` plus descriptor-specific versions;
- state/status continue to carry and validate the selected model version;
- stable `unknown_model`, `model_unavailable`, `model_switch_busy`, and `model_contract_mismatch` errors.

Godot changes a model by storing the desired ID, sending a final zero input when possible, closing the current WebSocket, clearing its pose/command/input generation, and reconnecting. It does not switch the visual before a matching `hello_ack` is validated.

On success, model activation occurs before the connection becomes ready. If the bundled Godot descriptor, GLB, manifest, or selected server identity does not match, the client enters fault and renders no fallback excavator.

## 5. Godot Model Activation

`PresentationRoot` becomes an empty owner for exactly one active model instance. `MotionPresentation` receives the selected catalog entry and performs an atomic activation:

1. load and instantiate the selected `PackedScene` under a stable `ActiveExcavator` node;
2. load the selected manifest and zero/parity fixture;
3. resolve all five semantic frames and validate parents, rest origins/scales, runtime axes, and source identity;
4. configure optional passive linkage from the manifest (`godot_visual_four_bar` for SY205, `none` for SY135 unless validated otherwise);
5. configure a model-specific excavation contact proxy;
6. only then free the previous active instance and emit `model_activated`.

Activation failure frees the candidate, retains no cross-model fallback, reports a stable contract error, and leaves motion not-ready. Rest-local transforms remain model-specific and are never calibrated by overwriting nested world transforms.

`CameraRig` retargets to the active `base_link` on `model_activated`. `ExcavationWorld` asks `MotionPresentation` for the validated bucket contact transform instead of applying a global SY205 constant.

## 6. SY135 Import Contract And Human Gate

The requested source copy is authorized by the user's import request, but source bytes remain immutable. After copying and headless import:

- exact Godot node paths and parent-local rest transforms become observed/validated manifest values;
- the semantic map uses the sole candidate chain matching the five authority frames;
- Godot runtime axes are validated by isolated positive joint poses, not copied from Blender extras;
- the existing Python-Z-up to Godot-Y-up conversion remains the only coordinate conversion;
- imported pivot origins are approved only if controlled poses rotate the intended subtree about each pin without origin drift;
- `REF_BUCKET_TIP` becomes the SY135 excavation proxy only after its imported relationship to `bucket_link` is validated.

The GLB declares no passive linkage nodes, so SY135 uses `passive_linkage.mode = "none"`. If import inspection reveals a closed chain or incorrect pivots, implementation stops and requests re-authoring rather than synthesizing mechanics.

## 7. State Invalidation

Backend model selection constructs a new runtime, stream epoch, recording epoch, simulator, replay model, input router, queues, and caches.

Godot model selection clears:

- accepted/pending pose, input, and command state;
- presentation rest/zero/frame maps, linkage solver continuity, and diagnostics;
- camera target cache;
- bucket inventory, previous tooth sweep, soil particles, and generation-gated derived work.

The logical `TerrainState` stable/loose Float32 layers and their current heightfield are preserved. The authority generation change prevents old excavation work from applying after the switch.

## 8. Compatibility, Rollback, And Failure Policy

- No explicit model means SY205 everywhere.
- Existing `URDF_PATH` and SY205 fixtures remain compatibility defaults.
- The SY135 reference bytes remain unchanged and remain forbidden as an SY205 rollback/replay model.
- Reverting the feature restores the fixed SY205 resolver; no data migration is required because model-specific recordings carry their identity.
- Unknown IDs, digest drift, missing resources, active-session conflict, or contract mismatch fail explicitly. There is no silent fallback to SY205 after the user requests SY135.

## 9. Verification Design

- Asset identity: source/repository SHA and bytes, Godot import hierarchy/resources/bounds.
- Mechanics: zero, four isolated positive poses, asymmetric pose, zero restore, axis/sign/subtree/origin/scale checks.
- Backend: registry resolution, CLI default/explicit selection, fresh runtime construction, active-session conflict, dynamic `/api/model`, hello/state versions, replay/recording model isolation.
- Godot: both catalog entries, single active instance, contract loading, reconnect selection, camera retarget, contact proxy, no passive SY135 solver, `SY205 -> SY135 -> SY205` lifecycle.
- Full gates: Ruff, mypy, pytest, provenance, backend smoke, Godot standalone matrix, Forward+ runtime smoke, and screenshots/visual review for both models.
