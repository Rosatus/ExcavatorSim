from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[4]
SOURCE = ROOT / "artifacts/benchmark/visual-evidence"
OUTPUT = Path(__file__).resolve().parent / "visual-contact-sheet.png"
CELLS = (
    ("SY205 / LOW", "sy205-low-carry.png", "Loaded carry"),
    ("SY205 / BALANCED", "sy205-balanced-dump.png", "Dump posture"),
    ("SY205 / HIGH", "sy205-high-support.png", "Ground support"),
    ("SY135 / LOW", "sy135-low-carry.png", "Loaded carry"),
    ("SY135 / BALANCED", "sy135-balanced-dump.png", "Dump posture"),
    ("SY135 / HIGH", "sy135-high-support.png", "Ground support"),
)


def main() -> None:
    cell_width = 640
    image_height = 360
    label_height = 62
    sheet = Image.new("RGB", (cell_width * 3, (image_height + label_height) * 2), "#11161c")
    draw = ImageDraw.Draw(sheet)
    title_font = ImageFont.truetype("arialbd.ttf", 22)
    detail_font = ImageFont.truetype("arial.ttf", 17)
    for index, (title, filename, detail) in enumerate(CELLS):
        column = index % 3
        row = index // 3
        x = column * cell_width
        y = row * (image_height + label_height)
        image = Image.open(SOURCE / filename).convert("RGB")
        image.thumbnail((cell_width, image_height), Image.Resampling.LANCZOS)
        crop_x = max(0, (image.width - cell_width) // 2)
        crop_y = max(0, (image.height - image_height) // 2)
        image = image.crop((crop_x, crop_y, crop_x + cell_width, crop_y + image_height))
        sheet.paste(image, (x, y))
        draw.rectangle((x, y + image_height, x + cell_width, y + image_height + label_height), fill="#11161c")
        draw.text((x + 16, y + image_height + 8), title, font=title_font, fill="#f2f4f5")
        draw.text((x + 16, y + image_height + 34), detail, font=detail_font, fill="#a9bac7")
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(OUTPUT, optimize=True)


if __name__ == "__main__":
    main()
