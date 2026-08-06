from __future__ import annotations

from babylon_sim.cli import _application_url, _loopback_host


def test_loopback_urls_support_ipv4_ipv6_and_localhost() -> None:
    assert _application_url(_loopback_host("127.0.0.1"), 8765) == "http://127.0.0.1:8765/"
    assert _application_url(_loopback_host("::1"), 8765) == "http://[::1]:8765/"
    assert _application_url(_loopback_host("localhost"), 8765) == "http://localhost:8765/"
