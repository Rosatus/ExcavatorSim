# Implementation Plan

## 0. Characterization Gate

- [x] Record the reference ground-truth `calibration.toml` SHA-256 in the QML
      canonical contract; implementation will copy/verify the approved bytes.
- [x] Run Godot SY135 neutral plus one positive checkpoint per joint; verify
      authoritative frames, telemetry packet frames and joint scalars agree.
- [x] Trace the same checkpoints through the unmodified reference source
      equations and lock QML neutral/sign joint alignment in a versioned profile.
- [x] Confirm bucket target range lies in one monotonic four-bar branch.
- [x] Stop before product mapping changes if any frame/pivot alignment is not
      uniquely identified.

## 1. Profile And Pure Mapping Tests

- [x] Add a strict TOML profile/calibration loader using Python 3.11 `tomllib`.
- [x] Validate schema/target/model, required keys, finite values and calibration
      hash; add fail-closed tests for every rejection class.
- [x] Add pure rigid-basis conversion and QML Euler extraction helpers.
- [x] Lock identity and `+/-90 degree` Godot Y-yaw cardinal cases and gimbal
      policy.
- [x] Add QML root calibration inverse and `GNSSA=O-Exca*GO` round-trip tests.
- [x] Add adjacent-frame twist extraction with neutral/off-axis validation.
- [x] Add boom/arm closed-form inverse and bucket bracketed inverse with forward
      substitution tests over legal limits.

## 2. Gateway Mapping

- [x] Inject the loaded profile into `MachineState`/frame emission without
      changing legacy no-profile behavior.
- [x] Use `upper` as body IMU/root/RTK source in profile mode.
- [x] Generate body reported R/P and A900 by inverting the active QML calibration.
- [x] Generate main GNSS A from the upper slew-center pose and QML GO inverse.
- [x] Derive velocity from successive GNSSA/tick samples and vice antenna from
      the explicit mount offset.
- [x] Generate boom/arm/bucket pitch from relative twist and `Sensor2Ang`
      inverse; reject invalid branches with actionable diagnostics.
- [x] Emit QML-stable RTK status for valid synthetic data and retain invalid
      fixture behavior.
- [x] Replace legacy compensation assertions in profile tests with QML-oracle
      assertions; retain legacy tests only for legacy mode.

## 3. Transport Consumability

- [x] Fix raw `can_frame` packing to distinguish standard and extended IDs.
- [x] Update the existing test that currently expects 29-bit truncation.
- [x] Add PC001 and SocketCAN packing tests for A900, four Ruifen IDs, slew and
      standard `0x256` travel.
- [x] Re-run the 5770-frame CSV -> reference replay audit and require zero ID,
      DLC and payload mismatches.

## 4. Godot Launch And Fixture Seam

- [x] Add explicit project/export settings for compatibility profile and QML
      calibration paths and pass them to source/packaged gateway launches.
- [x] Fail visibly when configured resources are missing; do not silently launch
      legacy mode under a QML-profile setting.
- [x] Extend the Godot CAN E2E/standalone test to record same-tick five-frame
      transforms, four joint scalars, tick/model identity and CTN1 packet bytes.
- [x] Prove checkpoint transforms equal authoritative post-step truth before
      using them as cross-repository fixtures.

## 5. Cross-Repository Source And Mathematical Oracle

- [x] Generate deterministic cases: flat neutral, chassis yaw, pure slew,
      slope+slew, each joint `+/-`, combined motion and near limits.
- [x] Encode through gateway and assert CSV/reference replay byte identity.
- [x] Trace the unmodified reference `ProtocolParser + GuidanceCore/lib_kin`
      source path and encode its parser/service/calibration equations as pure
      inverse tests; do not modify QML product code.
- [x] Compare decoded fields, QML root angles, three joints and O at the design
      tolerances; retain the profile and calibration hash with the fixtures.
- [x] Record that native/live QML execution is intentionally out of scope for
      this environment; the accepted gate is source and mathematical parity.

## 6. Packaging And Regression

- [x] Bundle or explicitly locate the approved profile/calibration in Windows
      onefile and supported Linux builds; log profile version/hash on startup.
- [x] Run `python -m unittest discover -s tools/can_gateway/tests`.
- [x] Run focused Godot headless parity and existing CAN gateway E2E tests.
- [x] Run `pixi run verify` and relevant focused Godot standalone suites; record
      unrelated Windows symlink/temp cleanup limitations separately.
- [x] Build and smoke-test the final Windows gateway used by Godot.
- [x] Preserve Linux resource bundling; native Linux build smoke is not required
      by the supported Windows product path in this task.
- [x] Confirm legacy no-profile behavior and rollback switch still work.

## Risk And Rollback Points

- Do not proceed past Step 0 if QML neutral/sign alignment is ambiguous. The
  locked Godot checkpoint established `+35/-90/-50` adjacent neutral rotations.
- Keep source packet version unchanged; a wire change requires a separate
  cross-layer protocol task.
- Keep each profile-mode mapping behind explicit configuration; source and
  mathematical oracle parity is the acceptance gate for this task.
- The EFF packing change is independent: if it fails transport regression, roll
  it back separately without reverting pose math/profile work.
- Never write to the sibling reference working tree; use temporary build/fixture
  locations and leave its existing dirty state untouched.
