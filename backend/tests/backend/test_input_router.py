from __future__ import annotations

import pytest

from babylon_sim.input_router import InputRouter, InputRouterError, InputSnapshot


class Clock:
    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now


def snapshot(
    sequence: int,
    axes: tuple[float, float, float, float],
    *,
    source: str = "browser",
    connected: bool = True,
) -> InputSnapshot:
    return InputSnapshot(source, sequence, connected, axes)


def test_zero_arming_sequence_and_latest_value() -> None:
    clock = Clock()
    router = InputRouter(clock=clock)
    with pytest.raises(InputRouterError) as rejected:
        router.submit(snapshot(0, (1.0, 0.0, 0.0, 0.0)), client_id="client")
    assert rejected.value.code == "not_armed"
    router.submit(snapshot(1, (0.0, 0.0, 0.0, 0.0)), client_id="client")
    router.submit(snapshot(2, (1.0, 0.0, 0.0, 0.0)), client_id="client")
    command = router.command(timestamp=0.0, sequence_number=0)
    assert command.channels == (1.0, 0.0, 0.0, 0.0)
    assert command.input_client_sequence == 2


def test_stale_sequence_is_rejected() -> None:
    router = InputRouter()
    router.submit(snapshot(1, (0.0, 0.0, 0.0, 0.0)), client_id="client")
    with pytest.raises(InputRouterError) as rejected:
        router.submit(snapshot(1, (0.0, 0.0, 0.0, 0.0)), client_id="client")
    assert rejected.value.code == "stale_sequence"


def test_sequence_remains_monotonic_after_same_client_disconnect_snapshot() -> None:
    router = InputRouter()
    router.submit(snapshot(10, (0.0, 0.0, 0.0, 0.0)), client_id="client")
    router.submit(
        snapshot(11, (0.0, 0.0, 0.0, 0.0), connected=False),
        client_id="client",
    )
    with pytest.raises(InputRouterError) as rejected:
        router.submit(snapshot(1, (0.0, 0.0, 0.0, 0.0)), client_id="client")
    assert rejected.value.code == "stale_sequence"


def test_active_source_release_remains_connected_zero() -> None:
    router = InputRouter()
    router.submit(snapshot(0, (0.0, 0.0, 0.0, 0.0)), client_id="client")
    router.submit(snapshot(1, (1.0, 0.0, 0.0, 0.0)), client_id="client")
    assert router.command(timestamp=0.0, sequence_number=0).connected

    router.submit(snapshot(2, (0.0, 0.0, 0.0, 0.0)), client_id="client")
    released = router.command(timestamp=0.01, sequence_number=1)

    assert released.connected
    assert released.channels == (0.0, 0.0, 0.0, 0.0)
    assert released.input_client_sequence == 2


def test_lease_expiry_disconnects_and_requires_rearming() -> None:
    clock = Clock()
    router = InputRouter(clock=clock)
    router.submit(snapshot(0, (0.0, 0.0, 0.0, 0.0)), client_id="client")
    router.submit(snapshot(1, (1.0, 0.0, 0.0, 0.0)), client_id="client")
    assert router.command(timestamp=0.0, sequence_number=0).connected
    clock.now = 0.2
    expired = router.command(timestamp=0.0, sequence_number=1)
    assert expired.connected is False
    assert expired.input_client_sequence == 1
    with pytest.raises(InputRouterError) as rejected:
        router.submit(snapshot(2, (1.0, 0.0, 0.0, 0.0)), client_id="client")
    assert rejected.value.code == "not_armed"


def test_disconnect_client_is_idempotent_and_releases_source() -> None:
    router = InputRouter()
    router.submit(snapshot(0, (0.0, 0.0, 0.0, 0.0)), client_id="first")
    router.submit(snapshot(1, (1.0, 0.0, 0.0, 0.0)), client_id="first")
    router.command(timestamp=0.0, sequence_number=0)
    router.disconnect_client("first")
    router.disconnect_client("first")
    assert router.command(timestamp=0.0, sequence_number=1).connected is False
    with pytest.raises(InputRouterError) as rejected:
        router.submit(snapshot(0, (1.0, 0.0, 0.0, 0.0)), client_id="second")
    assert rejected.value.code == "not_armed"


def test_source_count_is_bounded() -> None:
    router = InputRouter(max_sources=1)
    router.submit(snapshot(0, (0.0, 0.0, 0.0, 0.0), source="a"), client_id="client")
    with pytest.raises(InputRouterError) as rejected:
        router.submit(snapshot(1, (0.0, 0.0, 0.0, 0.0), source="b"), client_id="client")
    assert rejected.value.code == "too_many_sources"
