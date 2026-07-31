#!/usr/bin/env python3
"""Create deterministic actual-size motion QA for Migi Advanced v0.9."""

from __future__ import annotations

import json
import statistics
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFont


PROJECT_DIR = Path(__file__).resolve().parents[1]
RESOURCE_DIR = PROJECT_DIR / "Sources" / "MigiAdvanced" / "Resources"
ATLAS_PATH = RESOURCE_DIR / "migi-v4-atlas.png"
MANIFEST_PATH = RESOURCE_DIR / "migi-v4-atlas.json"
QA_DIR = PROJECT_DIR / "QA" / "fullbody-v0.9.0"
PREVIEW_DIR = QA_DIR / "previews"

APP_SIZE = (115, 135)
DISPLAY_RECT = (2, 6, 113, 129)
REQUIRED_GAZE_CLIPS = {
    "idle",
    "patrol",
    "patrol-left",
    "idle-left",
    "turn-left",
    "turn-right",
    "laptop",
    "phone",
    "book",
    "rapid-notes",
}


def checker(size: tuple[int, int], block: int = 8) -> Image.Image:
    image = Image.new("RGB", size, (246, 246, 246))
    draw = ImageDraw.Draw(image)
    for y in range(0, size[1], block):
        for x in range(0, size[0], block):
            if (x // block + y // block) % 2:
                draw.rectangle(
                    (x, y, x + block - 1, y + block - 1),
                    fill=(229, 229, 229),
                )
    return image


def extract_cell(
    atlas: Image.Image,
    row: int,
    column: int,
    cell_width: int,
    cell_height: int,
) -> Image.Image:
    return atlas.crop(
        (
            column * cell_width,
            row * cell_height,
            (column + 1) * cell_width,
            (row + 1) * cell_height,
        )
    )


def render_app_size(cell: Image.Image) -> Image.Image:
    width = DISPLAY_RECT[2] - DISPLAY_RECT[0]
    height = DISPLAY_RECT[3] - DISPLAY_RECT[1]
    sprite = cell.resize((width, height), Image.Resampling.LANCZOS)
    tile = Image.new("RGBA", APP_SIZE, (0, 0, 0, 0))
    tile.alpha_composite(sprite, (DISPLAY_RECT[0], DISPLAY_RECT[1]))
    return tile


def visible_bbox(image: Image.Image) -> tuple[int, int, int, int]:
    bbox = image.getchannel("A").getbbox()
    if bbox is None:
        raise SystemExit("encountered an empty Migi QA frame")
    return bbox


def normalized_difference(first: Image.Image, second: Image.Image) -> float:
    first_alpha = first.getchannel("A")
    second_alpha = second.getchannel("A")
    difference = ImageChops.difference(first_alpha, second_alpha)
    histogram = difference.histogram()
    changed = sum(count for value, count in enumerate(histogram) if value >= 10)
    union = ImageChops.lighter(first_alpha, second_alpha)
    visible = sum(count for value, count in enumerate(union.histogram()) if value >= 10)
    return changed / max(visible, 1)


def main() -> None:
    QA_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    atlas = Image.open(ATLAS_PATH).convert("RGBA")
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    cell_width = int(manifest["cell_width"])
    cell_height = int(manifest["cell_height"])
    expected_size = (
        int(manifest["columns"]) * cell_width,
        int(manifest["rows"]) * cell_height,
    )
    if atlas.size != expected_size:
        raise SystemExit(
            f"atlas/manifest mismatch: {atlas.size} != {expected_size}"
        )

    clips: dict[str, dict[str, object]] = manifest["clips"]
    ordered_names = [
        name
        for name, clip in sorted(
            clips.items(),
            key=lambda item: (
                int(item[1]["row"]),
                int(item[1]["column_offset"]),
                item[0],
            ),
        )
        if name != "idle-left"
    ]
    tile_gap = 4
    label_height = 18
    sheet_width = 8 * (APP_SIZE[0] + tile_gap) + 12
    sheet_height = len(ordered_names) * (APP_SIZE[1] + label_height + tile_gap) + 12
    sheet = checker((sheet_width, sheet_height), block=8)
    draw = ImageDraw.Draw(sheet)
    font = ImageFont.load_default()

    report_clips: dict[str, object] = {}
    y = 8
    for name in ordered_names:
        clip = clips[name]
        row = int(clip["row"])
        offset = int(clip["column_offset"])
        frame_count = int(clip["frame_count"])
        durations = clip.get("frame_durations")
        if not isinstance(durations, list) or len(durations) != frame_count:
            durations = [float(clip["frame_duration"])] * frame_count

        cells = [
            extract_cell(atlas, row, offset + index, cell_width, cell_height)
            for index in range(frame_count)
        ]
        app_frames = [render_app_size(cell) for cell in cells]
        bounds = [visible_bbox(frame) for frame in app_frames]
        widths = [bbox[2] - bbox[0] for bbox in bounds]
        heights = [bbox[3] - bbox[1] for bbox in bounds]
        baselines = [bbox[3] for bbox in bounds]
        differences = [
            normalized_difference(app_frames[index], app_frames[index + 1])
            for index in range(frame_count - 1)
        ]
        loop_difference = normalized_difference(app_frames[-1], app_frames[0])
        eye_frames = clip.get("eyes", [])
        eye_counts = [
            len(anchors) if isinstance(anchors, list) else 0
            for anchors in eye_frames
        ]

        preview_frames: list[Image.Image] = []
        for app_frame in app_frames:
            background = checker(APP_SIZE, block=7).convert("RGBA")
            background.alpha_composite(app_frame)
            preview_frames.append(background.convert("P", palette=Image.Palette.ADAPTIVE))
        preview_path = PREVIEW_DIR / f"{name}.gif"
        preview_frames[0].save(
            preview_path,
            save_all=True,
            append_images=preview_frames[1:],
            duration=[max(20, round(float(value) * 1000)) for value in durations],
            loop=0,
            disposal=2,
        )

        draw.rectangle((6, y, sheet_width - 6, y + label_height - 2), fill=(28, 28, 28))
        draw.text(
            (10, y + 4),
            f"{name}  {frame_count}f  {clip.get('playback_mode', 'loop')}",
            fill=(255, 255, 255),
            font=font,
        )
        frame_y = y + label_height
        for index, app_frame in enumerate(app_frames):
            x = 8 + index * (APP_SIZE[0] + tile_gap)
            tile = checker(APP_SIZE, block=7).convert("RGBA")
            tile.alpha_composite(app_frame)
            sheet.paste(tile.convert("RGB"), (x, frame_y))
        y += label_height + APP_SIZE[1] + tile_gap

        report_clips[name] = {
            "frames": frame_count,
            "playback_mode": clip.get("playback_mode", "loop"),
            "widths": widths,
            "heights": heights,
            "baseline_range": max(baselines) - min(baselines),
            "height_range": max(heights) - min(heights),
            "adjacent_alpha_difference": differences,
            "loop_alpha_difference": loop_difference,
            "eye_counts": eye_counts,
            "gaze_ready": (
                name not in REQUIRED_GAZE_CLIPS
                or (
                    bool(clip.get("pointer_eyes"))
                    and len(eye_counts) == frame_count
                    # A turn or crawl may canonically retract one stalk. Every
                    # visible eye must track, but a one-eye pose is still valid.
                    and min(eye_counts, default=0) >= 1
                )
            ),
            "preview": str(preview_path),
        }

    sheet_path = QA_DIR / "all-clips-actual-size.png"
    sheet.crop((0, 0, sheet_width, y + 8)).save(sheet_path, optimize=True)

    identity_names = [
        "idle",
        "patrol",
        "patrol-left",
        "laptop",
        "phone",
        "book",
        "rapid-notes",
        "fine-motor",
    ]
    median_heights = {
        name: statistics.median(report_clips[name]["heights"])
        for name in identity_names
    }
    idle_height = median_heights["idle"]
    scale_ratios = {
        name: round(height / idle_height, 4)
        for name, height in median_heights.items()
    }
    gaze_failures = [
        name
        for name in REQUIRED_GAZE_CLIPS
        if name in report_clips and not report_clips[name]["gaze_ready"]
    ]
    direction_failures: list[str] = []
    for name in ("laptop", "phone", "book"):
        if clips[name].get("mirror_policy") != "automatic":
            direction_failures.append(f"{name}:mirror_policy")
    for name in ("laptop", "phone", "book", "rapid-notes", "fine-motor"):
        if clips[name].get("turn_left_clip") != "turn-left":
            direction_failures.append(f"{name}:turn_left_clip")
        if clips[name].get("turn_right_clip") != "turn-right":
            direction_failures.append(f"{name}:turn_right_clip")
    if clips["patrol"].get("left_clip") != "patrol-left":
        direction_failures.append("patrol:left_clip")
    for name in ("patrol", "patrol-left", "turn-left", "turn-right"):
        if clips[name].get("mirror_policy") != "never":
            direction_failures.append(f"{name}:mirror_policy")
    for name in ("turn-left", "turn-right"):
        turn_duration = sum(float(value) for value in clips[name]["frame_durations"])
        if abs(turn_duration - 1.01) > 0.0001:
            direction_failures.append(f"{name}:duration:{turn_duration:.4f}")

    result = {
        "ok": not gaze_failures
        and not direction_failures
        and all(0.82 <= ratio <= 1.18 for ratio in scale_ratios.values()),
        "atlas": str(ATLAS_PATH),
        "manifest": str(MANIFEST_PATH),
        "actual_size_contact": str(sheet_path),
        "display_size": list(APP_SIZE),
        "identity_median_height_ratios": scale_ratios,
        "gaze_failures": gaze_failures,
        "direction_failures": direction_failures,
        "clips": report_clips,
    }
    report_path = QA_DIR / "motion-validation.json"
    report_path.write_text(
        json.dumps(result, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(
        json.dumps(
            {
                "ok": result["ok"],
                "contact": str(sheet_path),
                "report": str(report_path),
                "gaze_failures": gaze_failures,
                "direction_failures": direction_failures,
                "scale_ratios": scale_ratios,
            },
            indent=2,
        )
    )
    if not result["ok"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
