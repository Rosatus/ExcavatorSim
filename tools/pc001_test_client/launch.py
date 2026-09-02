"""PyInstaller-friendly entry point for the PC001 test client."""

import json
import os
import sys
from pathlib import Path

trace_path = os.environ.get("EXCAVATORSIM_PC001_SMOKE_TRACE")


def _trace(stage: str, **extra: object) -> None:
    if not trace_path:
        return
    Path(trace_path).write_text(
        json.dumps(
            {
                "stage": stage,
                "argv": sys.argv,
                "host": os.environ.get("EXCAVATORSIM_PC001_SMOKE_HOST"),
                "port": os.environ.get("EXCAVATORSIM_PC001_SMOKE_PORT"),
                **extra,
            }
        ),
        encoding="utf-8",
    )


def _run() -> int:
    _trace("entry")
    try:
        from pc001_test_client.app import main

        _trace("imported")
        result = main()
        _trace("completed", result=result)
        return result
    except BaseException as exc:
        if trace_path:
            _trace("error", error=repr(exc), error_type=type(exc).__name__)
            return 99
        raise


raise SystemExit(_run())
