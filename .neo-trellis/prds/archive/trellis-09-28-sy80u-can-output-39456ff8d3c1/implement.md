# SY80U CAN output — delivered

Goal: sender-only ExcavatorSim/tools/can_gateway model-aware135/80U CAN output; reverse GuideSystem sensor/renderer semantics, preserve joint directions. GuideSystem and can_replay remain unmodified.

Implemented:
- CTN1 telemetry v2 retains176 bytes, header model1=sy135/2=sy80u from active presentation. Unsupported product rigs emit no mislabeled telemetry. Legacyv1 remains accepted with CLI model; control/heartbeats remainv1.
- Isolated hash-bound SY80 DBC catalog, signed zero-offset IMUs with all-zero sentinel handling, two-byte slew, side swing18FF3E00. Existing RTK/travel/PC001 framing reused.
- Profile reverses SY80 extra body VAL axis remap, extracts Ry(side)Rx(boom) and inverses calibrated bucket linkage; side frame sign accounts for parser and QML double negation.
- Runtime atomically prepares new model mapping/catalog before replacement; resets mapper/scheduler, retires timed/custom schedules and queued SocketCAN frames, keeps PC001 connected/FIFO. Console updates DBC semantics; per-model persisted files isolated; return to original legacy135 also restores no-profile mapping.
- SY80 DBC requires valid nonzero CANopen mux branch4112 for generated defaults; general default selection now picks defined branch.
- README and CAN contract updated, source provenance recorded. Main alone implemented. Readonly agents reviewed semantics and lifecycle; both findings fixed.

GuideSystem investigation: ICT_MACHINE_MODEL=SY80U aliasesSY80C6Y5LU; startup environment selection documented ictenvloader.cpp. AppController initServices loads database/calibration.toml OVER factory defaults. Bundled SY80 calibration is byte-for-byte C:/code/x86-linux-debug/database/calibration.toml as of2026-09-28, hash-bound profile. This actual runtime has135-sized CF/FQ/QV4.6543/2.5294/1.1927 vs native80 3.52/2.05/.972. Orientation/direction parity proven; identical lengths/tip locations cannot be achieved by CAN angles alone. No receiver changes or GUI/build run of GuideSystem. No claim of visual mesh identity. Factory80 bucket130 not representable; never silently substitutes factory calibration.

Validation (final implementation; later only top docstring/comment changed):
- .pixi/envs/default/python.exe -m unittest discover -s tools/can_gateway/tests:201 tests, OK,2 platform skips. CAN_POSE_CAPTURE=TEMP/sy80_pose.json enabled real Godot capture test. TEMP/sy80_gateway_final.log.
- Existing standalone process test initially409 because preview preceded custom authority; verified guard exists inHEAD. Reordered test to satisfy existing API; no production behavior change for it.
- test_sy80u: independent raw signed decode -> C++/QML math,135 pose zero conventions, all135/80 main-joint endpoints/combinations, side -51/0/+65, body tilt/heading,135->80->135 stableTCP and console, original legacy135 byte preservation, per-model storage/catalog default validation. Joint angle tolerance.035deg; actual Godot local-quaternion tolerance.04deg.
- Godot can_qml_pose_checkpoint_test: existing135 pass; extended80 neutral, four positive work/main joints, side+65/-51 pass. Actual packets capturedTEMP/sy80_pose.json and fed to mapper/encoder/independent renderer check. TEMP/sy80_pose.log.
- Godot can_gateway_e2e_test PASS process supervision,CSV,PC001 connection/restart; TEMP/sy80_e2e.log.
- Windows onefile built at dist/can_gateway_sy80u/gateway.exe using build_exe.py --skip-web-build; frozen suite7 testsPASS including actual capture and both TCP transition cases. Adjacent model DBC dir included. TEMP/sy80_build_final.log.
- Scoped Ruff changed modules/test PASS (conventions.py preexisting lint issues unchanged); provenance PASS; git diff --check PASS.

No commits/push, no Godot client export, no production process replacement. Source editor runs use updated source gateway. NewWindows gateway artifact linked in handoff. Existing exported client must be rebuilt along with updated gateway for automatic model tags. No unresolved code work. User may verify receiving UI against same reference calibration; geometry differences documented.

## Follow-up: PC001 disconnect permitted on model switch
User explicitly permits disconnect135/80 switch. Replaced FIFO same-session switch with close old TCP sink (clears queue, shuts down client/candidate socket to wake service thread), reopen same listener endpoint, require newPC001 handshake. New-model frames before handshake are dropped, never queued for later client. Reconnect failure reports transport error. Source and rebuilt Windows artifact updated; receiver remains untouched.
Validation: source test_sy80u7 tests6pass/1 capture-only skip; existing13 pc001 sink testsPASS; frozen test_sy80u same6pass/1skip including135->80->135 EOF/reconnect/frames and original135 mapping restoration. Scoped Ruff/diff checksPASS. Prior unchanged pose math/Godot capture evidence remains valid. README/spec updated to reconnect contract, superseding earlier keep-connected wording. No client export/commit.

## Follow-up: SY135 NEO preserves the SY135 PC001 session
User clarified both visual variants must use the original SY135 sending path and
must not switch/disconnect PC001 when toggling between them. Added sy135neo as
telemetry wire model 1 in the Godot bridge; previously it emitted no telemetry.
Gateway code and the real SY135/SY80U reconnect boundary remain unchanged.
Extended can_gateway_e2e_test with real SY135 -> NEO -> SY135 product switches,
176-byte model-1 packets, new data on the same TCP socket, retained handshake,
active forwarding and stable gateway PID. Test PASS / exit 0 using
C:/apps/godot_voxel/godot.windows.editor.x86_64.exe; log TEMP/sy135neo_can_e2e.log.
Scoped diff check PASS. Engine reported voxel/tree lifecycle diagnostics during
scene setup; all gateway and switch assertions passed. No visual changes or
manual visual acceptance needed. No client export, gateway rebuild or commit.

## Follow-up: invalid telemetry must not crash Gateway
User requested auditing similar failures after slew caused a crash; prefer dropping
invalid data. Existing circular slew rounding retained. Added shared ingress/direct
emission validation for finite physical fields, complete bodies and unit quaternions
(1e-3 norm tolerance). Moved preparation into a side-effect-free helper with a
sample exception boundary; all frames are prepared before sink writes. QML mapper
history is staged in a shallow clone and committed only after successful encoding,
so rejected data cannot poison velocity history. Transport/observer errors remain
outside the sample exception handler, not silently mislabeled as bad input.
Tests cover every consumed float field with NaN/+Inf/-Inf, bad quaternion norms,
late encoder ValueError/OverflowError/ZeroDivisionError/KeyError/RuntimeError,
no partial frames, unchanged history, same-tick recovery and live PC001 recovery
after nonfinite/finite huge-altitude packets.
Validation: source suite 204 tests OK, 3 skips (platform/optional capture);
scoped Ruff and diff check PASS. Godot can_gateway_e2e PASS including 135/NEO
same-socket switches (existing voxel/tree diagnostics still present).
Built dist/can_gateway_hardened/gateway.exe; frozen process rejection/recovery
and SY80 suite 8 tests OK, 1 optional capture skip. Logs in TEMP:
gateway_invalid_final.log, gateway_hardened_build.log,
gateway_hardened_frozen.log, gateway_hardened_godot.log.
No production replacement, client export or commit. New binary is a separate
deliverable; already-running gateways still need replacement/restart to use it.

## Follow-up: simplify excessive defenses
User approved the review recommendation to narrow crash protection. Removed
unit-quaternion admission threshold and duplicate shape/tick/body validation;
fixed-layout parser checks consumed floats for finiteness once. Existing QML
normalization/semantic checks remain. Removed mapper cloning/__dict__ copying:
rollback now restores only the two velocity-history fields on preparation failure.
Numeric/domain rejection stays recoverable; unexpected preparation exceptions
use TelemetryPreparationError and retain a traceback in the owner loop.
Source suite 205 tests OK/3 skipped; new ingress-to-emission scaled-quaternion
regression passes, along with no-partial-send/history rollback/TCP recovery.
Scoped Ruff/diff check PASS. Rebuilt dist/can_gateway_hardened/gateway.exe in
place; no running process replacement or client export.
Frozen rejection/recovery and SY80 regression: 8 tests OK/1 optional capture
skip. Logs TEMP/gateway_simplified_tests.log, gateway_simplified_build.log,
gateway_simplified_frozen.log. This supersedes the stricter validation above.
