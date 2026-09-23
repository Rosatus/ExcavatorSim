"""Build shared 2K soil textures from the user's Fab yd0jchk texture set.

Requires Pillow. Source JPGs remain untouched. Normal RGB is OpenGL Y+;
the source green channel agrees with the downward image-space height gradient.
"""
import argparse
from pathlib import Path

from PIL import Image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    args = parser.parse_args()
    target = Path(__file__).resolve().parents[1] / "godot/client/assets/terrain/textures/fine03"
    target.mkdir(parents=True, exist_ok=True)

    def read(suffix, mode):
        with Image.open(args.source / f"yd0jchk_4K_{suffix}.jpg") as source:
            return source.convert(mode).resize((2048, 2048), Image.Resampling.LANCZOS)

    read("Basecolor", "RGB").save(target / "albedo.png")
    normal = read("Normal", "RGB").convert("RGBA")
    normal.putalpha(read("Roughness", "L"))
    normal.save(target / "normal_roughness.png")


if __name__ == "__main__":
    main()
