"""The two production CAN frames intentionally outside the shipped DBCs."""

from __future__ import annotations

from can_channel import CanChannel

TIMED_CAN_ID = 0x18FFF100
TIMED_CAN_CHANNEL: CanChannel = "ch3"
TIMED_CAN_PAYLOAD = bytes.fromhex("01 00 00 00 00 00 00 00")
TIMED_CAN_FREQUENCY_HZ = 50

TRAVEL_CAN_CHANNEL: CanChannel = "ch0"
