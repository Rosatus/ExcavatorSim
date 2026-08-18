from __future__ import annotations

from pathlib import Path

import pytest

from babylon_sim.calibration import MachineCalibration
from babylon_sim.model import ExcavatorModel
from babylon_sim.paths import CALIBRATION_PATH, URDF_PATH


@pytest.fixture(scope="session")
def model() -> ExcavatorModel:
    return ExcavatorModel.from_urdf(URDF_PATH)


@pytest.fixture(scope="session")
def calibration() -> MachineCalibration:
    return MachineCalibration.from_json(CALIBRATION_PATH)


@pytest.fixture(scope="session")
def fixture_root() -> Path:
    return Path(__file__).resolve().parents[1] / "fixtures"
