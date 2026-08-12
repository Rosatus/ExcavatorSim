"""Shared recording, playback, and exchange contract constants."""

from __future__ import annotations

from enum import StrEnum

from .constants import ACTIVE_JOINT_NAMES


class SourceMode(StrEnum):
    LIVE = "live"
    IMPORTED = "imported"


class PlaybackState(StrEnum):
    FOLLOWING = "following"
    PAUSED = "paused"
    PLAYING = "playing"
    COMPLETE = "complete"


RECORDING_CHUNK_SAMPLES = 100
RECORDING_MAX_CHUNKS = 3_600
RECORDING_MAX_SAMPLES = RECORDING_CHUNK_SAMPLES * RECORDING_MAX_CHUNKS
RECORDING_RANGE_MAX_BUCKETS = 4_096
RECORDING_UPLOAD_MAX_BYTES = 256 * 1024 * 1024
IMPORT_TOKEN_TTL_SECONDS = 5 * 60
REPLAY_VIEW_HZ = 30

RRD_PROFILE = "godot-pinocchio/rrd-v1"
RRD_SDK_VERSION = "0.35.0"
RRD_RECORDING_TIMELINE = "recording_time"
RRD_SAMPLE_TIMELINE = "sample_sequence"

JOINT_SIGNAL_FIELDS = tuple(
    f"joint_{quantity}.{joint}"
    for quantity in ("position", "velocity", "acceleration")
    for joint in ACTIVE_JOINT_NAMES
)
SERIES_FIELDS = (*JOINT_SIGNAL_FIELDS, "simulation_time_s")
