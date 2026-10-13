"""Derive SY155W from the owner-supplied SY135C_RT DBC snapshots."""

import re
from pathlib import Path


def main() -> None:
    root = Path(__file__).resolve().parent / "resources" / "dbc"
    reference = root / "sy135c_rt_reference"
    source = (reference / "can3.sy135c_RT.dbc").read_text(encoding="utf-8")
    boom = re.search(r"BO_ 2565931008 .*?\n(.*?)(?=\nBO_)", source, re.S)
    assert boom is not None
    frame_id = 0x98F40000
    replacement = f"BO_ {frame_id} MSG_18F40000: 8 IMU_BOOM2\n" + boom[1] + "\n"
    result = source.replace("BU_: IMU_BODY", "BU_: IMU_BOOM2 IMU_BODY")
    result = result.replace("CM_ BO_", replacement + "CM_ BO_", 1)
    result += f'\nCM_ BO_ {frame_id} "channel=can3;SY155W second-boom RT attitude IMU";\n'
    target = root / "sy155w"
    target.mkdir(exist_ok=True)
    (target / "can3.sy155w.dbc").write_text(result, encoding="utf-8", newline="\n")
    (target / "can4.sy155w.dbc").write_bytes((reference / "can4.sy135c_RT.dbc").read_bytes())


if __name__ == "__main__":
    main()
