"""Root-only, no-argument entry point for fixed can0 preparation."""

from __future__ import annotations

import sys

from can0_setup import Can0SetupError, configure_can0


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if args:
        print("CAN0_SETUP_FAILED: this helper accepts no arguments", file=sys.stderr)
        return 64
    try:
        # Normal Gateway prepare invokes this helper only for an unready
        # interface. Direct standalone Web restart intentionally invokes the
        # same no-argument helper even when ready, so the helper always cycles.
        snapshot = configure_can0(force=True)
    except Can0SetupError as exc:
        print(f"{exc.code}: {exc}", file=sys.stderr)
        return 1
    print(
        "CAN0_READY: "
        f"bitrate={snapshot.bitrate} restart_ms={snapshot.restart_ms} "
        f"tx_queue_len={snapshot.tx_queue_len} state={snapshot.controller_state}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
