from __future__ import annotations

import math

import numpy as np
import pytest

from babylon_sim.terrain import (
    MAX_TERRAIN_BYTES,
    TerrainSpecError,
    default_terrain_spec,
    generate_terrain,
    terrain_snapshot_bytes,
)


def _base(kind: str) -> dict[str, object]:
    spec = default_terrain_spec()
    spec["kind"] = kind
    return spec


def test_default_flat_grid_is_deterministic_and_bounded() -> None:
    first = generate_terrain(default_terrain_spec())
    second = generate_terrain(default_terrain_spec())

    assert (first.domain.rows, first.domain.columns) == (81, 81)
    assert first.domain.origin_x_m == first.domain.origin_y_m == -10.0
    assert first.domain.point_count == 6_561
    assert len(terrain_snapshot_bytes(first)) == 6_561 * 4
    assert len(terrain_snapshot_bytes(first)) <= MAX_TERRAIN_BYTES
    assert first.snapshot_sha256 == second.snapshot_sha256
    assert first.snapshot_sha256 == (
        "0969661ea1f132601a8bc7e2c0e80813d8f3364d917ca2f964011fae0ca8d18e"
    )
    assert np.all(first.heights == np.float32(0.0))
    assert not first.heights.flags.writeable


def test_seeded_noise_depends_on_world_coordinates_not_grid_indices() -> None:
    coarse_spec = default_terrain_spec()
    coarse_spec.update({"spacing_m": 0.5, "seed": 17, "noise_amplitude_m": 0.4})
    fine_spec = {**coarse_spec, "spacing_m": 0.25}
    coarse = generate_terrain(coarse_spec)
    fine = generate_terrain(fine_spec)

    np.testing.assert_array_equal(coarse.heights, fine.heights[::2, ::2])
    changed = generate_terrain({**coarse_spec, "seed": 18})
    assert changed.snapshot_sha256 != coarse.snapshot_sha256


@pytest.mark.parametrize(
    ("positive", "negative", "axis"),
    [("north", "south", 0), ("east", "west", 1)],
)
def test_slope_directions_are_centered_mirrors(
    positive: str, negative: str, axis: int
) -> None:
    spec = _base("slope")
    spec.update({"angle_deg": 15.0, "direction": positive})
    first = generate_terrain(spec)
    second = generate_terrain({**spec, "direction": negative})

    np.testing.assert_allclose(first.heights + second.heights, 0.0, atol=1e-6)
    center = first.heights[first.domain.rows // 2, first.domain.columns // 2]
    assert center == 0.0
    delta = (
        first.heights[first.domain.rows // 2 + (1 - axis), first.domain.columns // 2 + axis]
        - center
    )
    assert math.isclose(float(delta), 0.25 * math.tan(math.radians(15)), abs_tol=1e-6)


def test_trench_default_position_is_centered_and_symmetric() -> None:
    spec = _base("trench")
    spec.update(
        {
            "position": 0.5,
            "top_width_m": 4.0,
            "bottom_width_m": 2.0,
            "trench_depth_m": 2.0,
            "wall_steepness": 0.8,
        }
    )
    terrain = generate_terrain(spec)

    np.testing.assert_array_equal(terrain.heights, np.flip(terrain.heights, axis=0))
    center_row = terrain.domain.rows // 2
    assert np.all(terrain.heights[center_row] == np.float32(-2.0))
    assert np.all(terrain.heights[0] == np.float32(0.0))


def test_profile_rasterizes_a_corridor_and_uses_explicit_outside_elevation() -> None:
    spec = _base("profile")
    spec.update(
        {
            "alignment_xy_m": [[-8.0, 0.0], [8.0, 0.0]],
            "section_uv_m": [[-2.0, 0.0], [0.0, -1.0], [2.0, 0.0]],
            "outside_elevation_m": 0.5,
        }
    )
    terrain = generate_terrain(spec)
    center_row = terrain.domain.rows // 2

    assert terrain.heights[center_row, terrain.domain.columns // 2] == np.float32(-1.0)
    assert terrain.heights[0, 0] == np.float32(0.5)
    assert terrain.snapshot_sha256 == (
        "690bad8deaf85cd8c38d37e14b3a5d66e7a7181b0578e17ed0b7eedb3773b595"
    )


@pytest.mark.parametrize(
    "update",
    [
        {"width_m": 20.1},
        {"width_m": 50.0, "depth_m": 50.0, "spacing_m": 0.2},
        {"noise_amplitude_m": float("nan")},
        {"unexpected": True},
    ],
)
def test_invalid_or_over_budget_specs_are_rejected(update: dict[str, object]) -> None:
    with pytest.raises(TerrainSpecError):
        generate_terrain({**default_terrain_spec(), **update})


def test_trench_relationships_and_profile_degeneracy_are_rejected() -> None:
    trench = _base("trench")
    trench.update(
        {
            "position": 0.5,
            "top_width_m": 2.0,
            "bottom_width_m": 4.0,
            "trench_depth_m": 2.0,
            "wall_steepness": 0.5,
        }
    )
    with pytest.raises(TerrainSpecError, match="bottom_width"):
        generate_terrain(trench)

    profile = _base("profile")
    profile.update(
        {
            "alignment_xy_m": [[0.0, 0.0], [0.0, 0.0]],
            "section_uv_m": [[-1.0, 0.0], [1.0, 0.0]],
            "outside_elevation_m": 0.0,
        }
    )
    with pytest.raises(TerrainSpecError, match="zero-length"):
        generate_terrain(profile)
