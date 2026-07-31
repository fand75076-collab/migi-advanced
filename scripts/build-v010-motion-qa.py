#!/usr/bin/env python3
"""Validate the v0.10 atlas semantics and build focused motion QA artifacts."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


PROJECT_DIR = Path(__file__).resolve().parents[1]
RESOURCE_DIR = PROJECT_DIR / "Sources" / "MigiAdvanced" / "Resources"
ATLAS_PATH = RESOURCE_DIR / "migi-v4-atlas.png"
MANIFEST_PATH = RESOURCE_DIR / "migi-v4-atlas.json"
QA_DIR = PROJECT_DIR / "QA" / "fullbody-v0.10.0"
GIF_DIR = QA_DIR / "gifs"
STRIPS_DIR = PROJECT_DIR.parent / "work" / "migi-v010-20260730" / "strips"

EXPECTED_CLIPS = {
    "normal-hand": (13, 0, 4, [0, 1, 1, 0], False),
    "calm-diagnosis": (13, 4, 4, [1, 3, 3, 1], False),
    "palm-observer": (14, 0, 6, [1, 1, 2, 2, 1, 1], False),
    "signal-sampling": (15, 0, 6, [1, 2, 4, 5, 3, 1], False),
    "storage-pocket": (16, 0, 6, [1, 1, 1, 1, 1, 1], True),
    "recovery-care": (17, 0, 6, [1, 2, 1, 2, 1, 1], True),
    "detached-scout-return": (18, 0, 8, [1, 1, 2, 1, 1, 1, 2, 1], False),
    "complete-sleep": (19, 0, 8, [1, 1, 0, 0, 0, 0, 1, 1], False),
    "complete-sleep-wake": (19, 6, 2, [1, 1], False),
    "protective-shield": (20, 0, 6, [2, 1, 1, 1, 1, 2], False),
}

SOURCE_FILES = {
    "normal-hand": "normal-hand-transparent.png",
    "calm-diagnosis": "calm-diagnosis-transparent.png",
    "palm-observer": "palm-observer-transparent.png",
    "signal-sampling": "signal-sampling-transparent.png",
    "storage-pocket": "storage-pocket-transparent.png",
    "recovery-care": "recovery-care-transparent.png",
    "detached-scout-return": "detached-scout-return-transparent.png",
    "complete-sleep": "complete-sleep-transparent.png",
    "protective-shield": "protective-shield-transparent.png",
}


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


def fit_frame(frame: Image.Image, size: tuple[int, int]) -> Image.Image:
    output = checker(size)
    bbox = frame.getchannel("A").getbbox()
    if bbox is None:
        return output
    sprite = frame.crop(bbox)
    scale = min(
        (size[0] - 12) / sprite.width,
        (size[1] - 12) / sprite.height,
        1,
    )
    sprite = sprite.resize(
        (
            max(1, round(sprite.width * scale)),
            max(1, round(sprite.height * scale)),
        ),
        Image.Resampling.LANCZOS,
    )
    output.alpha_composite(
        sprite,
        ((size[0] - sprite.width) // 2, (size[1] - sprite.height) // 2),
    )
    return output


def main() -> None:
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    atlas = Image.open(ATLAS_PATH).convert("RGBA")
    errors: list[str] = []
    clips = manifest.get("clips", {})
    columns = manifest.get("columns")
    rows = manifest.get("rows")
    cell_width = manifest.get("cell_width")
    cell_height = manifest.get("cell_height")

    if (
        manifest.get("version") != 4
        or columns != 8
        or rows != 21
        or cell_width != 448
        or cell_height != 448
    ):
        errors.append("manifest-shape")
    if atlas.size != (columns * cell_width, rows * cell_height):
        errors.append(f"atlas-size:{atlas.size}")
    if len(clips) != 29:
        errors.append(f"clip-count:{len(clips)}")

    frame_report: dict[str, list[dict[str, object]]] = {}
    used_slots: set[tuple[int, int]] = set()
    for name, (row, column, count, eye_counts, contains_prop) in EXPECTED_CLIPS.items():
        clip = clips.get(name)
        if not isinstance(clip, dict):
            errors.append(f"missing:{name}")
            continue
        actual_shape = (
            clip.get("row"),
            clip.get("column_offset"),
            clip.get("frame_count"),
        )
        if actual_shape != (row, column, count):
            errors.append(f"shape:{name}:{actual_shape}")
        if clip.get("mirror_policy") != "never":
            errors.append(f"mirror:{name}")
        if bool(clip.get("contains_prop")) != contains_prop:
            errors.append(f"prop:{name}")
        if len(clip.get("frame_durations", [])) != count:
            errors.append(f"durations:{name}")
        actual_eye_counts = [len(anchors) for anchors in clip.get("eyes", [])]
        if actual_eye_counts != eye_counts:
            errors.append(f"eyes:{name}:{actual_eye_counts}")
        if contains_prop and not clip.get("rigid_zones"):
            errors.append(f"rigid-zone:{name}")

        reports = []
        for relative_column in range(count):
            slot = (row, column + relative_column)
            if name != "complete-sleep-wake":
                if slot in used_slots:
                    errors.append(f"overlap:{name}:{slot}")
                used_slots.add(slot)
            frame = atlas.crop(
                (
                    slot[1] * cell_width,
                    slot[0] * cell_height,
                    (slot[1] + 1) * cell_width,
                    (slot[0] + 1) * cell_height,
                )
            )
            bbox = frame.getchannel("A").getbbox()
            if bbox is None:
                errors.append(f"empty:{name}:{relative_column}")
            elif (
                bbox[0] <= 0
                or bbox[1] <= 0
                or bbox[2] >= cell_width
                or bbox[3] >= cell_height
            ):
                errors.append(f"clipped:{name}:{relative_column}:{bbox}")
            reports.append(
                {
                    "frame": relative_column,
                    "alpha_bbox": list(bbox or ()),
                    "eye_count": actual_eye_counts[relative_column],
                }
            )
        frame_report[name] = reports

    sleep = clips.get("complete-sleep", {})
    if sleep.get("loop_range") != [4, 5]:
        errors.append("complete-sleep-loop")
    wake = clips.get("complete-sleep-wake", {})
    if wake.get("playback_mode") != "once":
        errors.append("complete-sleep-wake-mode")

    source_hashes = manifest.get("source_sha256", {})
    for name, filename in SOURCE_FILES.items():
        source = STRIPS_DIR / filename
        if not source.is_file():
            errors.append(f"source-missing:{name}")
        elif source_hashes.get(name) != sha256(source):
            errors.append(f"source-hash:{name}")

    QA_DIR.mkdir(parents=True, exist_ok=True)
    GIF_DIR.mkdir(parents=True, exist_ok=True)
    tile_size = (224, 224)
    label_height = 26
    columns_count = 4
    ordered = list(EXPECTED_CLIPS)
    total_frames = sum(EXPECTED_CLIPS[name][2] for name in ordered)
    rows_count = (total_frames + columns_count - 1) // columns_count
    sheet = checker(
        (
            columns_count * tile_size[0],
            rows_count * (tile_size[1] + label_height),
        )
    )
    draw = ImageDraw.Draw(sheet)
    font = ImageFont.load_default()
    sheet_index = 0
    gif_paths: dict[str, str] = {}
    for name in ordered:
        row, column, count, _, _ = EXPECTED_CLIPS[name]
        frames = []
        durations = clips[name]["frame_durations"]
        for frame_index in range(count):
            frame = atlas.crop(
                (
                    (column + frame_index) * cell_width,
                    row * cell_height,
                    (column + frame_index + 1) * cell_width,
                    (row + 1) * cell_height,
                )
            )
            fitted = fit_frame(frame, tile_size)
            frames.append(fitted.convert("RGB"))
            sheet_column = sheet_index % columns_count
            sheet_row = sheet_index // columns_count
            x = sheet_column * tile_size[0]
            y = sheet_row * (tile_size[1] + label_height)
            draw.rectangle(
                (x, y, x + tile_size[0] - 1, y + label_height - 1),
                fill=(24, 24, 24, 255),
            )
            draw.text(
                (x + 6, y + 8),
                f"{name} [{frame_index}]",
                fill=(255, 255, 255, 255),
                font=font,
            )
            sheet.alpha_composite(fitted, (x, y + label_height))
            sheet_index += 1
        gif_path = GIF_DIR / f"{name}.gif"
        frames[0].save(
            gif_path,
            save_all=True,
            append_images=frames[1:],
            duration=[max(40, round(value * 1000)) for value in durations],
            loop=0,
            disposal=2,
        )
        gif_paths[name] = str(gif_path)

    contact_path = QA_DIR / "new-clips-contact.png"
    sheet.convert("RGB").save(contact_path, optimize=True)
    result = {
        "ok": not errors,
        "errors": errors,
        "atlas": str(ATLAS_PATH),
        "atlas_sha256": sha256(ATLAS_PATH),
        "manifest": str(MANIFEST_PATH),
        "manifest_sha256": sha256(MANIFEST_PATH),
        "clip_count": len(clips),
        "new_clip_frames": frame_report,
        "contact_sheet": str(contact_path),
        "gifs": gif_paths,
    }
    report_path = QA_DIR / "motion-validation.json"
    report_path.write_text(
        json.dumps(result, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(result, indent=2, ensure_ascii=False))
    if errors:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
