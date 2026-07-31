#!/usr/bin/env python3
"""Build focused deterministic QA for the v0.8.1 red-muscle blade clip."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFont


PROJECT_ROOT = Path(__file__).resolve().parents[1]
ATLAS_PATH = (
    PROJECT_ROOT
    / "Sources"
    / "MigiAdvanced"
    / "Resources"
    / "migi-v4-atlas.png"
)
MANIFEST_PATH = ATLAS_PATH.with_suffix(".json")
BASELINE_ATLAS_PATH = (
    PROJECT_ROOT / "backups" / "atlas-v0.8.0" / "migi-v4-atlas.png"
)
BASELINE_MANIFEST_PATH = BASELINE_ATLAS_PATH.with_suffix(".json")
QA_ROOT = PROJECT_ROOT / "QA" / "fullbody-v0.8.1"
CELL_SIZE = 448
ROW = 4
COLUMN_OFFSET = 4
FRAME_COUNT = 4
LABELS = (
    "1  Intact skin",
    "2  Muscle exposure",
    "3  Blade + muscle sheath",
    "4  Retraction",
)
METAL_FILENAMES = tuple(
    f"blade-metal-{index}.png" for index in range(FRAME_COUNT)
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def font(size: int) -> ImageFont.ImageFont:
    for candidate in (
        Path("/System/Library/Fonts/SFNS.ttf"),
        Path("/System/Library/Fonts/Helvetica.ttc"),
    ):
        if candidate.exists():
            return ImageFont.truetype(str(candidate), size=size)
    return ImageFont.load_default()


def checker(size: tuple[int, int], cell: int) -> Image.Image:
    image = Image.new("RGBA", size, (244, 244, 244, 255))
    draw = ImageDraw.Draw(image)
    for y in range(0, size[1], cell):
        for x in range(0, size[0], cell):
            if (x // cell + y // cell) % 2:
                draw.rectangle(
                    (
                        x,
                        y,
                        min(x + cell - 1, size[0] - 1),
                        min(y + cell - 1, size[1] - 1),
                    ),
                    fill=(224, 224, 224, 255),
                )
    return image


def extract_frames(atlas: Image.Image) -> list[Image.Image]:
    frames = []
    top = ROW * CELL_SIZE
    for index in range(FRAME_COUNT):
        left = (COLUMN_OFFSET + index) * CELL_SIZE
        frames.append(
            atlas.crop(
                (left, top, left + CELL_SIZE, top + CELL_SIZE)
            ).convert("RGBA")
        )
    return frames


def red_region_metrics(frame: Image.Image) -> dict[str, object]:
    alpha = frame.getchannel("A")
    bbox = alpha.getbbox()
    pixels = frame.load()
    red_points: list[tuple[int, int]] = []
    for y in range(frame.height):
        for x in range(round(frame.width * 0.56), frame.width):
            red, green, blue, opacity = pixels[x, y]
            if (
                opacity >= 96
                and red >= 105
                and red >= green * 1.28
                and red >= blue * 1.18
            ):
                red_points.append((x, y))
    red_bbox = None
    if red_points:
        xs = [point[0] for point in red_points]
        ys = [point[1] for point in red_points]
        red_bbox = [min(xs), min(ys), max(xs) + 1, max(ys) + 1]
    return {
        "red_pixels": len(red_points),
        "red_bbox": red_bbox,
    }


def muscle_metrics(frame: Image.Image) -> dict[str, object]:
    alpha_bbox = frame.getchannel("A").getbbox()
    full = red_region_metrics(frame)
    desktop = red_region_metrics(
        frame.resize((110, 110), Image.Resampling.LANCZOS)
    )
    return {
        "alpha_bbox": list(alpha_bbox) if alpha_bbox else None,
        "muscle_red_pixels_right_side": full["red_pixels"],
        "muscle_red_bbox_right_side": full["red_bbox"],
        "muscle_red_pixels_approx_desktop": desktop["red_pixels"],
        "muscle_red_bbox_approx_desktop": desktop["red_bbox"],
    }


def changed_cells(
    baseline: Image.Image,
    current: Image.Image,
) -> list[list[int]]:
    changed: list[list[int]] = []
    for row in range(9):
        for column in range(8):
            box = (
                column * CELL_SIZE,
                row * CELL_SIZE,
                (column + 1) * CELL_SIZE,
                (row + 1) * CELL_SIZE,
            )
            difference = ImageChops.difference(
                baseline.crop(box),
                current.crop(box),
            )
            if difference.getbbox() is not None:
                changed.append([row, column])
    return changed


def build_contact(frames: list[Image.Image]) -> None:
    label_height = 46
    title_height = 62
    sheet = Image.new(
        "RGBA",
        (CELL_SIZE * FRAME_COUNT, title_height + CELL_SIZE + label_height),
        (250, 250, 250, 255),
    )
    draw = ImageDraw.Draw(sheet)
    draw.text(
        (18, 16),
        "Migi Advanced v0.8.1 — attached blade with exposed red muscle",
        fill=(28, 28, 28, 255),
        font=font(26),
    )
    for index, (frame, label) in enumerate(zip(frames, LABELS)):
        tile = checker((CELL_SIZE, CELL_SIZE), 28)
        tile.alpha_composite(frame)
        sheet.alpha_composite(tile, (index * CELL_SIZE, title_height))
        label_box = draw.textbbox((0, 0), label, font=font(20))
        label_width = label_box[2] - label_box[0]
        draw.text(
            (
                index * CELL_SIZE + (CELL_SIZE - label_width) / 2,
                title_height + CELL_SIZE + 10,
            ),
            label,
            fill=(34, 34, 34, 255),
            font=font(20),
        )
    sheet.convert("RGB").save(QA_ROOT / "blade-atlas-contact.png", optimize=True)


def build_actual_size(frames: list[Image.Image]) -> None:
    tile_size = (115, 135)
    sprite_size = (110, 110)
    margin = 12
    label_height = 26
    title_height = 42
    cell_width = tile_size[0] + margin * 2
    cell_height = tile_size[1] + label_height + margin
    sheet = Image.new(
        "RGBA",
        (
            cell_width * FRAME_COUNT,
            title_height + cell_height,
        ),
        (250, 250, 250, 255),
    )
    draw = ImageDraw.Draw(sheet)
    draw.text(
        (margin, 11),
        "Approximate desktop-size QA — each tile is 115 × 135 px",
        fill=(28, 28, 28, 255),
        font=font(18),
    )
    for index, (frame, label) in enumerate(zip(frames, LABELS)):
        tile = checker(tile_size, 8)
        sprite = frame.resize(sprite_size, Image.Resampling.LANCZOS)
        tile.alpha_composite(sprite, ((tile_size[0] - sprite_size[0]) // 2, 13))
        x = index * cell_width + margin
        y = title_height
        sheet.alpha_composite(tile, (x, y))
        short_label = label.split("  ", maxsplit=1)[1]
        label_box = draw.textbbox((0, 0), short_label, font=font(12))
        label_width = label_box[2] - label_box[0]
        draw.text(
            (
                x + (tile_size[0] - label_width) / 2,
                y + tile_size[1] + 6,
            ),
            short_label,
            fill=(34, 34, 34, 255),
            font=font(12),
        )
    sheet.convert("RGB").save(
        QA_ROOT / "blade-actual-size-contact.png",
        optimize=True,
    )


def build_animation(frames: list[Image.Image]) -> None:
    rendered = []
    for frame in frames:
        background = checker((CELL_SIZE, CELL_SIZE), 28)
        background.alpha_composite(frame)
        rendered.append(background.convert("RGB"))
    rendered[0].save(
        QA_ROOT / "blade-sequence.gif",
        save_all=True,
        append_images=rendered[1:],
        duration=[220, 220, 440, 220],
        loop=0,
        disposal=2,
        optimize=False,
    )


def build_metal_contact(frames: list[Image.Image]) -> None:
    image_size = (230, 270)
    label_height = 38
    title_height = 54
    sheet = Image.new(
        "RGBA",
        (
            image_size[0] * FRAME_COUNT,
            title_height + image_size[1] + label_height,
        ),
        (250, 250, 250, 255),
    )
    draw = ImageDraw.Draw(sheet)
    draw.text(
        (16, 14),
        "Installed Metal renderer — 115 × 135 pt captured @2x",
        fill=(28, 28, 28, 255),
        font=font(22),
    )
    for index, (frame, label) in enumerate(zip(frames, LABELS)):
        if frame.size != image_size:
            raise SystemExit(
                f"{METAL_FILENAMES[index]}: expected {image_size}, got {frame.size}"
            )
        tile = checker(image_size, 12)
        tile.alpha_composite(frame)
        x = index * image_size[0]
        sheet.alpha_composite(tile, (x, title_height))
        short_label = label.split("  ", maxsplit=1)[1]
        label_box = draw.textbbox((0, 0), short_label, font=font(14))
        label_width = label_box[2] - label_box[0]
        draw.text(
            (
                x + (image_size[0] - label_width) / 2,
                title_height + image_size[1] + 8,
            ),
            short_label,
            fill=(34, 34, 34, 255),
            font=font(14),
        )
    sheet.convert("RGB").save(
        QA_ROOT / "blade-metal-contact.png",
        optimize=True,
    )


def main() -> None:
    QA_ROOT.mkdir(parents=True, exist_ok=True)
    atlas = Image.open(ATLAS_PATH).convert("RGBA")
    if atlas.size != (CELL_SIZE * 8, CELL_SIZE * 9):
        raise SystemExit(f"unexpected atlas size: {atlas.size}")
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    baseline_atlas = Image.open(BASELINE_ATLAS_PATH).convert("RGBA")
    baseline_manifest = json.loads(
        BASELINE_MANIFEST_PATH.read_text(encoding="utf-8")
    )
    clip = manifest["clips"]["sharpen-tip"]
    if (
        clip["row"] != ROW
        or clip["column_offset"] != COLUMN_OFFSET
        or clip["frame_count"] != FRAME_COUNT
    ):
        raise SystemExit(f"unexpected sharpen-tip layout: {clip}")
    frames = extract_frames(atlas)
    if any(frame.getchannel("A").getbbox() is None for frame in frames):
        raise SystemExit("empty sharpen-tip frame")
    changes = changed_cells(baseline_atlas, atlas)
    expected_changes = [[ROW, column] for column in range(4, 8)]
    if changes != expected_changes:
        raise SystemExit(f"unexpected changed atlas cells: {changes}")
    unchanged_clips = {
        name: clip_data
        for name, clip_data in manifest["clips"].items()
        if name != "sharpen-tip"
    }
    baseline_unchanged_clips = {
        name: clip_data
        for name, clip_data in baseline_manifest["clips"].items()
        if name != "sharpen-tip"
    }
    if unchanged_clips != baseline_unchanged_clips:
        raise SystemExit("non-sharpen clip metadata changed")
    build_contact(frames)
    build_actual_size(frames)
    build_animation(frames)
    metal_paths = [QA_ROOT / filename for filename in METAL_FILENAMES]
    metal_frames: list[Image.Image] = []
    if all(path.is_file() for path in metal_paths):
        metal_frames = [
            Image.open(path).convert("RGBA") for path in metal_paths
        ]
        build_metal_contact(metal_frames)
    frame_metrics = [muscle_metrics(frame) for frame in frames]
    desktop_red = [
        int(metrics["muscle_red_pixels_approx_desktop"])
        for metrics in frame_metrics
    ]
    red_readability_ok = (
        desktop_red[1] >= desktop_red[0] + 12
        and desktop_red[2] >= desktop_red[0] + 65
        and desktop_red[3] >= desktop_red[0] + 5
    )
    if not red_readability_ok:
        raise SystemExit(
            f"red muscle is not readable at approximate desktop size: {desktop_red}"
        )
    validation = {
        "ok": True,
        "atlas_size": list(atlas.size),
        "cell_size": CELL_SIZE,
        "clip": {
            "row": ROW,
            "column_offset": COLUMN_OFFSET,
            "frame_count": FRAME_COUNT,
            "frame_duration": clip["frame_duration"],
        },
        "frames": [
            {"index": index, **metrics}
            for index, metrics in enumerate(frame_metrics)
        ],
        "red_muscle_readable_at_approx_desktop_size": red_readability_ok,
        "changed_cells_vs_v0_8_0": changes,
        "expected_changed_cells": expected_changes,
        "unchanged_clip_metadata_preserved": True,
        "metal_frames": [
            {
                "index": index,
                "size": list(frame.size),
                **muscle_metrics(frame),
            }
            for index, frame in enumerate(metal_frames)
        ],
        "atlas_sha256": sha256(ATLAS_PATH),
        "manifest_sha256": sha256(MANIFEST_PATH),
        "source_sha256": manifest["source_sha256"]["sharpen-tip"],
    }
    (QA_ROOT / "blade-validation.json").write_text(
        json.dumps(validation, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(validation, indent=2))


if __name__ == "__main__":
    main()
