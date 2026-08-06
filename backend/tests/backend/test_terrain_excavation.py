from __future__ import annotations

import math

import numpy as np
import pytest

import babylon_sim.terrain_excavation as excavation
from babylon_sim.terrain import generate_terrain
from babylon_sim.terrain_excavation import (
    BUCKET_CAPACITY_M3,
    MAX_CUT_FILL_M,
    MAX_DIRTY_CELLS,
    MAX_RELAXATION_PASSES,
    REPOSE_ANGLE_DEG,
    REPOSE_HEIGHT_TOLERANCE_M,
    TerrainEditInput,
    TerrainEditResult,
    TerrainHistoryError,
    TerrainState,
    TerrainTimeline,
    _make_terrain_state,
    _relax_loose,
    apply_terrain_edit,
    initial_terrain_state,
    layered_state_digest,
    normalized_joint,
    snapshot_digest,
)


def _baseline():
    return generate_terrain(
        {
            "terrain_spec_version": "terrain-spec-v1",
            "kind": "flat",
            "width_m": 5.0,
            "depth_m": 5.0,
            "spacing_m": 0.25,
            "elevation_m": 0.0,
            "seed": 0,
            "noise_amplitude_m": 0.0,
            "noise_scale_m": 4.0,
        }
    )


def _edit(
    sample: int,
    *,
    posture: float,
    z: float,
    start_x: float = -0.5,
    end_x: float = 0.5,
    recording_time_ns: int | None = None,
) -> TerrainEditInput:
    previous = (
        (start_x, -0.25, z),
        (start_x, 0.0, z),
        (start_x, 0.25, z),
    )
    current = (
        (end_x, -0.25, z),
        (end_x, 0.0, z),
        (end_x, 0.25, z),
    )
    return TerrainEditInput(
        recording_epoch="recording",
        sample_sequence=sample,
        recording_time_ns=sample * 40_000_000 if recording_time_ns is None else recording_time_ns,
        stream_epoch="stream",
        previous_teeth=previous,
        current_teeth=current,
        bucket_joint_normalized=posture,
    )


def _assert_repose_converged(result: TerrainEditResult) -> None:
    spacing = 0.25
    limit = math.tan(math.radians(REPOSE_ANGLE_DEG)) * spacing
    limit += REPOSE_HEIGHT_TOLERANCE_M + 2e-6
    rows, columns = result.heights.shape
    for row in range(rows):
        for column in range(columns):
            for row_delta, column_delta in ((0, 1), (1, 0)):
                neighbor_row = row + row_delta
                neighbor_column = column + column_delta
                if neighbor_row >= rows or neighbor_column >= columns:
                    continue
                difference = float(result.heights[row, column]) - float(
                    result.heights[neighbor_row, neighbor_column]
                )
                if difference > limit and result.loose_depths[row, column] > 1e-7:
                    raise AssertionError("positive repose slope did not converge")
                if (
                    difference < -limit
                    and result.loose_depths[neighbor_row, neighbor_column] > 1e-7
                ):
                    raise AssertionError("negative repose slope did not converge")


def test_cut_is_bounded_volume_based_and_deterministic() -> None:
    baseline = _baseline()
    initial = initial_terrain_state(baseline.heights)
    first = apply_terrain_edit(baseline, initial, 0, _edit(4, posture=0.2, z=-0.1))
    second = apply_terrain_edit(baseline, initial, 0, _edit(4, posture=0.2, z=-0.1))

    assert first.event is not None
    assert first.patch is not None
    assert first.event.operation == "cut"
    assert first.event.cut_volume_m3 == pytest.approx(first.bucket_volume_m3, abs=1e-8)
    assert 0.0 < first.bucket_volume_m3 <= BUCKET_CAPACITY_M3
    assert first.event.changed_cells <= MAX_DIRTY_CELLS
    assert first.event.snapshot_sha256 == snapshot_digest(first.heights)
    assert first.event.layered_state_sha256 == layered_state_digest(first.state)
    assert first.event == second.event
    assert first.patch == second.patch
    assert first.heights.tobytes() == second.heights.tobytes()
    assert first.stable_heights.tobytes() == second.stable_heights.tobytes()
    assert first.loose_depths.tobytes() == second.loose_depths.tobytes()
    np.testing.assert_array_equal(
        first.heights,
        np.add(first.stable_heights, first.loose_depths, dtype=np.float32),
    )
    assert not first.heights.flags.writeable
    assert not first.stable_heights.flags.writeable
    assert not first.loose_depths.flags.writeable
    assert float(np.min(first.heights - baseline.heights)) >= -MAX_CUT_FILL_M


def test_bucket_capacity_scales_cut_and_dump_conserves_volume() -> None:
    baseline = _baseline()
    nearly_full = BUCKET_CAPACITY_M3 - 0.001
    cut = apply_terrain_edit(
        baseline,
        initial_terrain_state(baseline.heights, nearly_full),
        0,
        _edit(4, posture=0.2, z=-0.5),
    )
    assert cut.event is not None
    assert cut.bucket_volume_m3 <= BUCKET_CAPACITY_M3
    assert cut.event.cut_volume_m3 <= 0.001 + 1e-7

    dumped = apply_terrain_edit(
        baseline,
        cut.state,
        1,
        _edit(8, posture=0.9, z=1.0, start_x=0.5, end_x=0.5),
    )
    assert dumped.event is not None
    assert dumped.event.operation == "deposit"
    assert dumped.event.relaxation_converged
    assert 0 <= dumped.event.relaxation_passes <= MAX_RELAXATION_PASSES
    assert dumped.event.relaxation_touched_cells <= MAX_DIRTY_CELLS
    assert dumped.event.bucket_residual_m3 == dumped.bucket_volume_m3
    assert dumped.event.deposited_volume_m3 <= cut.bucket_volume_m3
    assert dumped.bucket_volume_m3 == pytest.approx(
        cut.bucket_volume_m3 - dumped.event.deposited_volume_m3, abs=1e-8
    )
    assert np.any(dumped.loose_depths > np.float32(0.0))
    np.testing.assert_array_equal(dumped.stable_heights, cut.stable_heights)
    assert float(np.max(dumped.heights - baseline.heights)) <= MAX_CUT_FILL_M
    cell_area = baseline.domain.spacing_m**2
    before_volume = (
        float(np.sum(cut.loose_depths, dtype=np.float64)) * cell_area + cut.bucket_volume_m3
    )
    after_volume = (
        float(np.sum(dumped.loose_depths, dtype=np.float64)) * cell_area + dumped.bucket_volume_m3
    )
    assert after_volume == pytest.approx(before_volume, abs=1e-6)
    assert float(np.ptp(dumped.loose_depths)) > 0.0
    _assert_repose_converged(dumped)


def test_cut_removes_loose_material_before_stable_substrate() -> None:
    baseline = _baseline()
    loose = np.full(baseline.heights.shape, np.float32(0.2), dtype="<f4")
    loose_state = _make_terrain_state(baseline.heights, loose, 0.0)
    loose_cut = apply_terrain_edit(
        baseline,
        loose_state,
        0,
        _edit(4, posture=0.2, z=-0.5),
        operation="cut",
    )
    assert loose_cut.patch is not None
    np.testing.assert_array_equal(loose_cut.stable_heights, loose_state.stable_heights)
    assert np.any(loose_cut.loose_depths < loose_state.loose_depths)
    assert loose_cut.event is not None
    assert loose_cut.event.relaxation_passes == 0

    shallow_loose = np.full(baseline.heights.shape, np.float32(0.02), dtype="<f4")
    shallow_state = _make_terrain_state(baseline.heights, shallow_loose, 0.0)
    substrate_cut = apply_terrain_edit(
        baseline,
        shallow_state,
        0,
        _edit(4, posture=0.2, z=-0.5),
        operation="cut",
    )
    assert substrate_cut.patch is not None
    changed = substrate_cut.patch.indices
    assert all(substrate_cut.loose_depths.flat[index] == 0.0 for index in changed)
    assert any(
        substrate_cut.stable_heights.flat[index] < shallow_state.stable_heights.flat[index]
        for index in changed
    )


def test_dump_preserves_stable_trench_and_stops_as_a_repose_mound() -> None:
    baseline = _baseline()
    stable = np.array(baseline.heights, dtype="<f4", copy=True)
    trench_column = 2
    stable[:, trench_column] = np.float32(-1.0)
    state = _make_terrain_state(stable, np.zeros(stable.shape, dtype="<f4"), BUCKET_CAPACITY_M3)
    dumped = apply_terrain_edit(
        baseline,
        state,
        0,
        _edit(4, posture=0.9, z=1.0, start_x=1.5, end_x=1.5),
        operation="deposit",
    )
    assert dumped.event is not None
    np.testing.assert_array_equal(dumped.stable_heights, state.stable_heights)
    np.testing.assert_array_equal(dumped.heights[:, trench_column], state.heights[:, trench_column])
    assert float(np.ptp(dumped.loose_depths)) > 0.0
    _assert_repose_converged(dumped)


def test_repose_dump_is_byte_deterministic() -> None:
    baseline = _baseline()
    initial = initial_terrain_state(baseline.heights, BUCKET_CAPACITY_M3)
    edit = _edit(4, posture=0.9, z=1.0, start_x=0.0, end_x=0.0)
    first = apply_terrain_edit(baseline, initial, 0, edit, operation="deposit")
    second = apply_terrain_edit(baseline, initial, 0, edit, operation="deposit")

    assert first.event == second.event
    assert first.patch == second.patch
    assert first.stable_heights.tobytes() == second.stable_heights.tobytes()
    assert first.loose_depths.tobytes() == second.loose_depths.tobytes()
    assert first.heights.tobytes() == second.heights.tobytes()
    assert layered_state_digest(first.state) == layered_state_digest(second.state)


def test_unplaceable_or_unconverged_dump_keeps_all_material_in_bucket(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    baseline = _baseline()
    ceiling = np.array(baseline.heights + MAX_CUT_FILL_M, dtype="<f4")
    full_state = _make_terrain_state(
        ceiling, np.zeros(ceiling.shape, dtype="<f4"), BUCKET_CAPACITY_M3
    )
    unplaceable = apply_terrain_edit(
        baseline,
        full_state,
        0,
        _edit(4, posture=0.9, z=4.0, start_x=0.0, end_x=0.0),
        operation="deposit",
    )
    assert unplaceable.event is None
    assert unplaceable.state is full_state

    partial_stable = np.array(ceiling, copy=True)
    center = (partial_stable.shape[0] // 2, partial_stable.shape[1] // 2)
    partial_stable[center] = np.float32(0.0)
    partial_state = _make_terrain_state(
        partial_stable,
        np.zeros(partial_stable.shape, dtype="<f4"),
        BUCKET_CAPACITY_M3,
    )
    partial = apply_terrain_edit(
        baseline,
        partial_state,
        0,
        _edit(4, posture=0.9, z=4.0, start_x=0.0, end_x=0.0),
        operation="deposit",
    )
    assert partial.event is not None
    assert 0.0 < partial.bucket_volume_m3 < BUCKET_CAPACITY_M3
    partial_cell_area = baseline.domain.spacing_m**2
    added = float(np.sum(partial.loose_depths, dtype=np.float64)) * partial_cell_area
    assert added + partial.bucket_volume_m3 == pytest.approx(BUCKET_CAPACITY_M3, abs=1e-6)

    monkeypatch.setattr(excavation, "_DEPOSIT_RADIUS_M", 0.1)
    monkeypatch.setattr(excavation, "MAX_RELAXATION_PASSES", 0)
    initial = initial_terrain_state(baseline.heights, BUCKET_CAPACITY_M3)
    unconverged = apply_terrain_edit(
        baseline,
        initial,
        0,
        _edit(4, posture=0.9, z=1.0, start_x=0.0, end_x=0.0),
        operation="deposit",
    )
    assert unconverged.event is None
    assert unconverged.state is initial


def test_relaxation_boundary_rejects_only_executable_outward_flux() -> None:
    baseline = _baseline()
    center_row = baseline.domain.rows // 2
    center_column = baseline.domain.columns // 2
    bounds = (center_row, center_row, center_column, center_column)
    empty = np.zeros(baseline.heights.shape, dtype="<f4")

    stable_cliff = np.array(baseline.heights, dtype="<f4", copy=True)
    stable_cliff[center_row, center_column] = np.float32(1.0)
    zero_flux_outward = _relax_loose(baseline, stable_cliff, empty, bounds)
    assert zero_flux_outward is not None
    np.testing.assert_array_equal(zero_flux_outward[0], empty)

    outside_loose = np.array(empty, copy=True)
    outside_loose[center_row - 1, center_column] = np.float32(1.0)
    inward = _relax_loose(baseline, baseline.heights, outside_loose, bounds)
    assert inward is not None
    np.testing.assert_array_equal(inward[0], outside_loose)

    inside_loose = np.array(empty, copy=True)
    inside_loose[center_row, center_column] = np.float32(1.0)
    assert _relax_loose(baseline, baseline.heights, inside_loose, bounds) is None


def test_non_contact_and_neutral_posture_are_non_mutating() -> None:
    baseline = _baseline()
    initial = initial_terrain_state(baseline.heights)
    no_contact = apply_terrain_edit(baseline, initial, 0, _edit(4, posture=0.2, z=2.0))
    neutral = apply_terrain_edit(baseline, initial, 0, _edit(4, posture=0.5, z=-0.1))
    assert no_contact.event is None
    assert neutral.event is None
    np.testing.assert_array_equal(no_contact.heights, baseline.heights)
    np.testing.assert_array_equal(neutral.heights, baseline.heights)
    assert not np.any(no_contact.loose_depths)
    assert not np.any(neutral.loose_depths)


def test_layer_state_rejects_negative_loose_depth_and_inconsistent_surface() -> None:
    baseline = _baseline()
    stable = np.array(baseline.heights, dtype="<f4", copy=True)
    loose = np.zeros_like(stable)
    loose[0, 0] = np.float32(-0.01)
    invalid_loose = TerrainState(stable, loose, np.array(stable, copy=True), 0.0)
    with pytest.raises(ValueError, match="non-negative"):
        apply_terrain_edit(baseline, invalid_loose, 0, _edit(4, posture=0.5, z=-0.1))

    loose[0, 0] = np.float32(0.01)
    inconsistent = TerrainState(stable, loose, np.array(stable, copy=True), 0.0)
    with pytest.raises(ValueError, match="canonical layers"):
        apply_terrain_edit(baseline, inconsistent, 0, _edit(4, posture=0.5, z=-0.1))


def test_layer_state_construction_rejects_surface_overflow() -> None:
    maximum = np.full((2, 2), np.finfo(np.float32).max, dtype="<f4")
    with pytest.raises(ValueError, match="surface must be finite"):
        _make_terrain_state(maximum, maximum, 0.0)


def test_timeline_reconstructs_exact_revisions_from_checkpoints() -> None:
    baseline = _baseline()
    timeline = TerrainTimeline(baseline, start_sample_sequence=0)
    cut_patch = timeline.apply(_edit(4, posture=0.2, z=-0.1, recording_time_ns=40_000_000))
    assert cut_patch is not None
    cut = timeline.materialize_sample(4)

    dump_patch = timeline.apply(
        _edit(
            8,
            posture=0.9,
            z=1.0,
            start_x=0.5,
            end_x=0.5,
            recording_time_ns=11_000_000_000,
        )
    )
    assert dump_patch is not None
    assert timeline.checkpoint_count == 2
    checkpointed_dump = timeline.materialize_revision(2)
    third_patch = timeline.apply(_edit(12, posture=0.2, z=-0.15, recording_time_ns=11_040_000_000))
    assert third_patch is not None
    dumped = timeline.materialize_revision(2)

    assert cut.revision == 1
    assert cut.snapshot_sha256 == cut_patch.snapshot_sha256
    assert dumped.snapshot_sha256 == dump_patch.snapshot_sha256
    assert dumped.heights.tobytes() == checkpointed_dump.heights.tobytes()
    assert dumped.stable_heights.tobytes() == checkpointed_dump.stable_heights.tobytes()
    assert dumped.loose_depths.tobytes() == checkpointed_dump.loose_depths.tobytes()
    assert dumped.layered_state_sha256 == layered_state_digest(dumped.state)
    timeline.prune_before(8)
    retained = timeline.materialize_sample(8)
    assert retained.layered_state_sha256 == dumped.layered_state_sha256
    assert retained.stable_heights.tobytes() == dumped.stable_heights.tobytes()
    assert retained.loose_depths.tobytes() == dumped.loose_depths.tobytes()
    assert timeline.history_bytes < 128 * 1024 * 1024


def test_timeline_replays_deposit_event_without_a_checkpoint() -> None:
    baseline = _baseline()
    timeline = TerrainTimeline(baseline, start_sample_sequence=0)
    assert timeline.apply(_edit(4, posture=0.2, z=-0.1)) is not None
    cut = timeline.materialize_revision(1)

    dump_edit = _edit(8, posture=0.9, z=1.0, start_x=0.5, end_x=0.5)
    dump_patch = timeline.apply(dump_edit)
    expected_event = timeline.latest_event
    expected = timeline.materialize_revision(2)
    direct = apply_terrain_edit(baseline, cut.state, 1, dump_edit)

    assert dump_patch is not None
    assert expected_event is not None
    assert expected_event.operation == "deposit"
    assert timeline.checkpoint_count == 1
    assert direct.event == expected_event
    assert direct.patch == dump_patch
    assert timeline.apply(_edit(12, posture=0.2, z=-0.15)) is not None

    replayed = timeline.materialize_revision(2)
    assert replayed.snapshot_sha256 == dump_patch.snapshot_sha256
    assert replayed.layered_state_sha256 == expected.layered_state_sha256
    assert replayed.heights.tobytes() == expected.heights.tobytes()
    assert replayed.stable_heights.tobytes() == expected.stable_heights.tobytes()
    assert replayed.loose_depths.tobytes() == expected.loose_depths.tobytes()

    timeline.prune_before(8)
    retained = timeline.materialize_sample(8)
    assert retained.layered_state_sha256 == expected.layered_state_sha256
    assert retained.stable_heights.tobytes() == expected.stable_heights.tobytes()
    assert retained.loose_depths.tobytes() == expected.loose_depths.tobytes()


def test_timeline_budget_failure_rolls_back_the_complete_revision() -> None:
    baseline = _baseline()
    timeline = TerrainTimeline(
        baseline,
        start_sample_sequence=0,
        history_limit_bytes=1,
    )

    with pytest.raises(TerrainHistoryError):
        timeline.apply(_edit(4, posture=0.2, z=-0.1))

    restored = timeline.materialize_revision(0)
    assert timeline.current_revision == 0
    assert timeline.event_count == 0
    assert timeline.checkpoint_count == 1
    assert restored.bucket_volume_m3 == 0.0
    assert restored.heights.tobytes() == baseline.heights.tobytes()
    assert restored.stable_heights.tobytes() == baseline.heights.tobytes()
    assert not np.any(restored.loose_depths)
    assert restored.layered_state_sha256 == layered_state_digest(restored.state)


def test_timeline_unconverged_dump_is_an_atomic_no_op(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    baseline = _baseline()
    timeline = TerrainTimeline(baseline, start_sample_sequence=0)
    assert timeline.apply(_edit(4, posture=0.2, z=-0.1)) is not None
    before = timeline.materialize_revision(1)
    before_events = timeline.event_count

    monkeypatch.setattr(excavation, "_DEPOSIT_RADIUS_M", 0.1)
    monkeypatch.setattr(excavation, "MAX_RELAXATION_PASSES", 0)
    patch = timeline.apply(_edit(8, posture=0.9, z=1.0, start_x=0.0, end_x=0.0))
    after = timeline.materialize_revision(1)

    assert patch is None
    assert timeline.current_revision == 1
    assert timeline.event_count == before_events
    assert after.layered_state_sha256 == before.layered_state_sha256
    assert after.stable_heights.tobytes() == before.stable_heights.tobytes()
    assert after.loose_depths.tobytes() == before.loose_depths.tobytes()
    assert after.bucket_volume_m3 == before.bucket_volume_m3


def test_timeline_reset_and_bucket_clear_preserve_historical_views() -> None:
    baseline = _baseline()
    timeline = TerrainTimeline(baseline, start_sample_sequence=0)
    timeline.apply(_edit(4, posture=0.2, z=-0.1))
    deformed = timeline.materialize_sample(4)
    timeline.clear_bucket(8, 80_000_000)
    cleared = timeline.materialize_sample(8)
    timeline.reset(12, 120_000_000)
    reset = timeline.materialize_sample(12)

    assert deformed.bucket_volume_m3 > 0.0
    assert cleared.bucket_volume_m3 == 0.0
    assert cleared.heights.tobytes() == deformed.heights.tobytes()
    assert cleared.stable_heights.tobytes() == deformed.stable_heights.tobytes()
    assert cleared.loose_depths.tobytes() == deformed.loose_depths.tobytes()
    assert cleared.snapshot_sha256 == deformed.snapshot_sha256
    assert cleared.layered_state_sha256 != deformed.layered_state_sha256
    assert reset.bucket_volume_m3 == 0.0
    assert reset.heights.tobytes() == baseline.heights.tobytes()
    assert reset.stable_heights.tobytes() == baseline.heights.tobytes()
    assert not np.any(reset.loose_depths)
    assert timeline.revision_at(3) == 0
    assert timeline.revision_at(4) == 1
    assert timeline.revision_at(8) == 2
    assert timeline.revision_at(12) == 3


def test_normalized_joint_is_finite_clamped_and_validated() -> None:
    assert normalized_joint(0.0, -1.0, 1.0) == 0.5
    assert normalized_joint(-2.0, -1.0, 1.0) == 0.0
    assert normalized_joint(2.0, -1.0, 1.0) == 1.0
    with pytest.raises(ValueError):
        normalized_joint(math.nan, -1.0, 1.0)
    with pytest.raises(ValueError):
        normalized_joint(0.0, 1.0, 1.0)
