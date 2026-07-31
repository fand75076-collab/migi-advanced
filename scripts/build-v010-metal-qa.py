#!/usr/bin/env python3
"""Validate and assemble installed-size Metal captures for Migi v0.10."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


PROJECT_DIR = Path(__file__).resolve().parents[1]
QA_DIR = PROJECT_DIR / "QA" / "fullbody-v0.10.0"
CAPTURE_DIR = QA_DIR / "metal"
CAPTURE_SIZE = (230, 270)  # 115 x 135 logical points at Retina scale 2.
INSTALLED_APP = Path("/Users/fdk/Applications/Migi Advanced.app")
INSTALLED_BUNDLE = (
    INSTALLED_APP
    / "Contents"
    / "Resources"
    / "MigiAdvanced_MigiAdvanced.bundle"
)
SOURCE_BUNDLE = PROJECT_DIR / "Sources" / "MigiAdvanced" / "Resources"

ORDERED_CAPTURES = [
    "normal-hand",
    "palm-observer",
    "signal-sampling",
    "calm-diagnosis",
    "storage-pocket",
    "recovery-care",
    "detached-scout-return",
    "complete-sleep",
    "protective-shield",
]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


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
        if (
            bbox[0] <= 0
            or bbox[1] <= 0
            or bbox[2] >= image.width
            or bbox[3] >= image.height
        ):
            errors.append(f"clipped:{name}:{bbox}")
        frame_report[name] = {
            "path": str(path),
            "pixel_size": list(image.size),
            "alpha_bbox": list(bbox),
            "visible_size": [bbox[2] - bbox[0], bbox[3] - bbox[1]],
        }

    resource_hashes: dict[str, dict[str, str]] = {}
    for filename in ("migi-v4-atlas.png", "migi-v4-atlas.json"):
        source = SOURCE_BUNDLE / filename
        installed = INSTALLED_BUNDLE / filename
        if not source.is_file() or not installed.is_file():
            errors.append(f"missing-resource:{filename}")
            continue
        source_hash = sha256(source)
        installed_hash = sha256(installed)
        resource_hashes[filename] = {
            "source": source_hash,
            "installed": installed_hash,
        }
        if source_hash != installed_hash:
            errors.append(f"installed-resource-mismatch:{filename}")

    columns = 3
    label_height = 26
    gap = 12
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
            (x, y, x + CAPTURE_SIZE[0] - 1, y + label_height - 1),
            fill=(24, 24, 24, 255),
        )
        draw.text(
            (x + 6, y + 8),
            name,
            fill=(255, 255, 255, 255),
            font=font,
        )
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
        "resource_hashes": resource_hashes,
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
