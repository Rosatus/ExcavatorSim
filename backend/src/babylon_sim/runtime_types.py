"""Pinocchio-free lifecycle and runtime value types shared by gateway and simulator."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

LifecycleCommand = Literal["start", "pause", "reset"]
RuntimeProfile = Literal["legacy", "motion-only", "gateway-only"]
COMMAND_CACHE_CAPACITY = 128
BUCKET_FEEDBACK_CAPABILITY = "bucket_load_feedback_v1"


class RuntimeCommandError(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class CommandResult:
    id: str
    command: LifecycleCommand
    lifecycle: str
    state_sequence: int


@dataclass(frozen=True)
class RuntimeStatus:
    simulation_hz: float
    state_hz: float
    render_target_hz: float
    overruns: int
    dropped_snapshots: int
    controller_source: str | None
    stale: bool
