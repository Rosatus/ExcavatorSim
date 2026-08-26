"""CANape-style CSV writer matching docs/can_spin_test_fixed.csv dialect.

Columns: 序号,系统时间,时间标识,CAN通道,传输方向,ID号,帧类型,帧格式,长度,数据
Encoding: UTF-8 with BOM (utf-8-sig), consumed by dev_arch2.0
tools/can_replay/csv_parser.read_can_csv().
"""

from __future__ import annotations

import time
from pathlib import Path


class CanapeCsvWriter:
    def __init__(self, path: Path) -> None:
        self._path = Path(path)
        self._row_count = 0
        self._sequence = 0
        self._fp = self._path.open("w", encoding="utf-8-sig", newline="", buffering=1)
        header = ",".join(
            ["序号", "系统时间", "时间标识", "CAN通道", "传输方向", "ID号", "帧类型", "帧格式", "长度", "数据"]
        )
        self._fp.write(header + "\r\n")

    @property
    def path(self) -> Path:
        return self._path

    @property
    def row_count(self) -> int:
        return self._row_count

    def append(self, can_id: int, payload: bytes) -> None:
        if len(payload) != 8:
            raise ValueError(f"CAN payload must be 8 bytes, got {len(payload)}")
        extended = can_id > 0x7FF
        now = time.localtime()
        system_time = '="%02d:%02d:%02d.%03d"' % (
            now.tm_hour,
            now.tm_min,
            now.tm_sec,
            int(time.time() * 1000) % 1000,
        )
        row = ",".join(
            [
                f"{self._sequence:05d}",
                system_time,
                hex(self._sequence),
                "ch3",
                "接收",
                f"0x{can_id:08X}" if extended else f"0x{can_id:03X}",
                "数据帧",
                "扩展帧" if extended else "标准帧",
                "0x08",
                "x| " + payload.hex(" ").upper(),
            ]
        )
        self._fp.write(row + "\r\n")
        self._sequence += 1
        self._row_count += 1

    def close(self) -> None:
        self._fp.flush()
        self._fp.close()
