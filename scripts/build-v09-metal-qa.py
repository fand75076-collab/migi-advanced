#!/usr/bin/env python3
"""Validate and assemble installed-size Metal captures for Migi v0.9."""

from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFont


PROJECT_DIR = Path(__file__).resolve().parents[1]
QA_DIR = PROJECT_DIR / "QA" / "fullbody-v0.9.0"
CAPTURE_DIR = QA_DIR / "metal"
CAPTURE_SIZE = (230, 270)  # 115 x 135 logical points at Retina scale 2.

ORDERED_CAPTURES = [
    "idle-left-gaze-left",
    "idle-right-gaze-right",
    "patrol-left",
    "patrol-right",
    "turn-left-mid",
    "turn-right-mid",
    "laptop-left",
    "laptop-right",
    "phone-left",
    "phone-right",
    "book-left",
    "book-right",
    "rapid-notes",
    "fine-motor",
    "sharpen-tip-peak",
]


def checker(size: tuple[int, int], block: int = 12) -> Image.Image:
    image = Image.new("RGBA", size, (248, 248, 248, 255))
    draw = ImageDraw.Draw(image)
    for y in range(0, size[1], block):
        for x in range(0, size[0], block):
            if (x // block + y // block) % 2:
                draw.rectangle(
                    (x, y, x + block - 1, y + block - 1),
                    fill=(226, 226, 226, 255),
                )
    return image


def normalized_alpha_difference(left: Image.Image, right: Image.Image) -> float:
    reflected = left.getchannel("A").transpose(Image.Transpose.FLIP_LEFT_RIGHT)
    right_alpha = right.getchannel("A")
    difference = ImageChops.difference(reflected, right_alpha)
    changed = sum(
        count
        for value, count in enumerate(difference.histogram())
        if value >= 10
    )
    union = ImageChops.lighter(reflected, right_alpha)
    visible = sum(
        count
        for value, count in enumerate(union.histogram())
        if value >= 10
    )
    return changed / max(visible, 1)


def main() -> None:
    captures: dict[str, Image.Image] = {}
    errors: list[str] = []
    frame_report: dict[str, object] = {}
    for name in ORDERED_CAPTURES:
        path = CAPTURE_DIR / f"{name}.png"
        if not path.is_file():
            errors.append(f"missing:{name}")
            continue
        image = Image.open(path).convert("RGBA")
        captures[name] = image
        if image.size != CAPTURE_SIZE:
            errors.append(f"size:{name}:{image.size}")
        bbox = image.getchannel("A").getbbox()
        if bbox is None:
            errors.append(f"empty:{name}")
            continue
        if bbox[0] <= 0 or bbox[1] <= 0 or bbox[2] >= image.width or bbox[3] >= image.height:
            errors.append(f"clipped:{name}:{bbox}")
        frame_report[name] = {
            "path": str(path),
            "pixel_size": list(image.size),
            "alpha_bbox": list(bbox),
            "visible_size": [bbox[2] - bbox[0], bbox[3] - bbox[1]],
        }

    mirror_differences: dict[str, float] = {}
    for name in ("laptop", "phone", "book"):
        left = captures.get(f"{name}-left")
        right = captures.get(f"{name}-right")
        if left is None or right is None:
            continue
        difference = normalized_alpha_difference(left, right)
        mirror_differences[name] = round(difference, 4)
        if difference > 0.14:
            errors.append(f"direction-pair:{name}:{difference:.4f}")

    columns = 4
    label_height = 24
    gap = 10
    rows = (len(ORDERED_CAPTURES) + columns - 1) // columns
    sheet_size = (
        columns * CAPTURE_SIZE[0] + (columns + 1) * gap,
        rows * (CAPTURE_SIZE[1] + label_height) + (rows + 1) * gap,
    )
    sheet = checker(sheet_size)
    draw = ImageDraw.Draw(sheet)
    font = ImageFont.load_default()
    for index, name in enumerate(ORDERED_CAPTURES):
        image = captures.get(name)
        if image is None:
            continue
        column = index % columns
        row = index // columns
        x = gap + column * (CAPTURE_SIZE[0] + gap)
        y = gap + row * (CAPTURE_SIZE[1] + label_height + gap)
        draw.rectangle(
            (x, y, x + CAPTURE_SIZE[0], y + label_height - 1),
            fill=(24, 24, 24, 255),
        )
        draw.text((x + 6, y + 7), name, fill=(255, 255, 255, 255), font=font)
        tile = checker(CAPTURE_SIZE)
        tile.alpha_composite(image)
        sheet.alpha_composite(tile, (x, y + label_height))

    contact_path = QA_DIR / "metal-contact.png"
    sheet.convert("RGB").save(contact_path, optimize=True)
    result = {
        "ok": not errors,
        "logical_display_size": [115, 135],
        "retina_capture_size": list(CAPTURE_SIZE),
        "errors": errors,
        "mirrored_prop_alpha_differences": mirror_differences,
        "frames": frame_report,
        "contact_sheet": str(contact_path),
    }
    report_path = QA_DIR / "metal-validation.json"
    report_path.write_text(
        json.dumps(result, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(result, indent=2, ensure_ascii=False))
    if errors:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
