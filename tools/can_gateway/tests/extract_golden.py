"""One-shot extractor: pull golden fixture rows from the real CANape capture."""

from __future__ import annotations

import csv
import json
from collections import defaultdict
from pathlib import Path

CAPTURE = Path("E:/projects/ExcavatorSim/docs/can_spin_test_fixed.csv")
TARGET_IDS = {
    "18FF3A00", "18FF3B00", "18FF3C00", "18FF3D00",
    "18FFF000",
    "0CFDA000", "0CFDA100", "0CFDA200", "0CFDA300", "0CFDA400",
    "0CFDA500", "0CFDA600", "0CFDA700", "0CFDA800", "0CFDA900",
}
PER_ID_LIMIT = 24


def main() -> None:
    buckets: dict[str, list[str]] = defaultdict(list)
    with CAPTURE.open("r", encoding="utf-8-sig", newline="") as fp:
        for row in csv.DictReader(fp):
            can_id = (row.get("ID号") or "").replace("0x", "").upper()
            if can_id not in TARGET_IDS:
                continue
            if len(buckets[can_id]) >= PER_ID_LIMIT:
                continue
            data = (row.get("数据") or "").strip()
            if data.startswith("x|"):
                data = data[2:].strip()
            buckets[can_id].append(data.replace(" ", ""))
    out_dir = Path(__file__).parent / "fixtures"
    out_dir.mkdir(exist_ok=True)
    payload = {can_id.lower(): rows for can_id, rows in sorted(buckets.items())}
    out = out_dir / "golden_capture.json"
    out.write_text(json.dumps(payload, indent=1), encoding="utf-8")
    print(f"wrote {out}: " + ", ".join(f"{k}x{len(v)}" for k, v in payload.items()))


if __name__ == "__main__":
    main()
