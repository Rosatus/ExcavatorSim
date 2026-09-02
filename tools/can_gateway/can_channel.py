"""Logical CAN channel contract shared by catalog and transport sinks."""

from __future__ import annotations

from typing import Literal

CanChannel = Literal["ch0", "ch2", "ch3"]

CHANNEL_NUMBERS: dict[CanChannel, int] = {
    "ch0": 0,
    "ch2": 2,
    "ch3": 3,
}


def channel_number(channel: CanChannel) -> int:
    """Return the DHC/PC001 integer representation for a logical channel."""
    return CHANNEL_NUMBERS[channel]


def dbc_channel(comment: object, source_name: str) -> CanChannel:
    """Resolve one non-conflicting DBC family to its DHC output channel."""
    normalized = comment.strip().lower() if isinstance(comment, str) else ""
    lowered_source = source_name.lower().replace(" ", "")
    evidence: set[str] = set()
    if "channel=can3" in normalized:
        evidence.add("can3")
    if "channel=can4" in normalized:
        evidence.add("can4")
    if "channel=" in normalized and not evidence:
        raise ValueError(f"DBC message channel is unknown for {source_name!r}")
    if "can3" in lowered_source:
        evidence.add("can3")
    if "can4" in lowered_source:
        evidence.add("can4")
    if len(evidence) != 1:
        raise ValueError(
            f"DBC message channel is missing or conflicting for {source_name!r}"
        )
    return "ch3" if evidence.pop() == "can3" else "ch2"
