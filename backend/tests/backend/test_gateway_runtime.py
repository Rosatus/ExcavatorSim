from __future__ import annotations

from concurrent.futures import Future

import pytest

from babylon_sim.gateway_runtime import GatewayRuntimeController
from babylon_sim.model_registry import load_model_registry
from babylon_sim.runtime import RuntimeCommandError
from babylon_sim.session_manager import RuntimeSessionManager


def test_gateway_runtime_never_constructs_a_python_model() -> None:
    descriptor = load_model_registry().resolve("sy205")
    runtime = GatewayRuntimeController(descriptor)
    assert runtime.profile == "gateway-only"
    assert runtime.publishes_view_state is False
    assert runtime.recording is None
    assert runtime.replay is None
    assert runtime.terrain is None
    assert not hasattr(runtime, "simulator")


def test_gateway_lifecycle_is_idempotent_and_reset_rotates_epoch() -> None:
    descriptor = load_model_registry().resolve("sy205")
    runtime = GatewayRuntimeController(descriptor)
    runtime.start()
    first = runtime.submit_command("session", "start-1", "start")
    assert isinstance(first, Future)
    assert first.result().lifecycle == "running"
    epoch = runtime.stream_epoch
    reset = runtime.submit_command("session", "reset-1", "reset").result()
    assert reset.lifecycle == "stopped"
    assert runtime.stream_epoch != epoch
    assert runtime.submit_command("session", "start-1", "start") is first
    with pytest.raises(RuntimeCommandError, match="another payload"):
        runtime.submit_command("session", "start-1", "pause")
    runtime.stop()


def test_gateway_model_switch_rebuilds_gateway_without_pinocchio() -> None:
    manager = RuntimeSessionManager(model_id="sy205", profile="gateway-only")
    assert manager.runtime.profile == "gateway-only"
    old_runtime = manager.runtime
    manager.start()
    manager.acquire("session", "sy135")
    assert manager.runtime.profile == "gateway-only"
    assert manager.runtime is not old_runtime
    assert manager.model_id == "sy135"
    manager.stop()
