from __future__ import annotations

from babylon_sim.cli import _application_url, _loopback_host, build_parser


def test_loopback_urls_support_ipv4_ipv6_and_localhost() -> None:
    assert _application_url(_loopback_host("127.0.0.1"), 8765) == "http://127.0.0.1:8765/"
    assert _application_url(_loopback_host("::1"), 8765) == "http://[::1]:8765/"
    assert _application_url(_loopback_host("localhost"), 8765) == "http://localhost:8765/"


def test_runtime_profile_is_opt_in_and_defaults_to_legacy() -> None:
    assert build_parser().parse_args([]).runtime_profile == "legacy"
    assert (
        build_parser().parse_args(["--runtime-profile", "motion-only"]).runtime_profile
        == "motion-only"
    )
