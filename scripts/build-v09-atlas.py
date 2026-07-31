#!/usr/bin/env python3
"""Build the v0.9 high-resolution Migi atlas from approved coherent strips."""

from __future__ import annotations

import hashlib
import json
from collections import deque
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw

PROJECT_DIR = Path(__file__).resolve().parents[1]
WORKSPACE_DIR = PROJECT_DIR.parent
LEGACY_STRIPS_DIR = (
    WORKSPACE_DIR / "work" / "migi-idle-v6-20260730" / "strips"
)
V09_STRIPS_DIR = (
    WORKSPACE_DIR / "work" / "migi-v09-canon-motion-20260730" / "strips"
)
BLADE_CANON_STRIPS_DIR = (
    WORKSPACE_DIR
    / "work"
    / "migi-blade-canon-v082-20260730"
    / "strips"
)
RESOURCE_DIR = PROJECT_DIR / "Sources" / "MigiAdvanced" / "Resources"
QA_DIR = PROJECT_DIR / "QA" / "fullbody-v0.9.0"

CELL_SIZE = 448
ATLAS_COLUMNS = 8
ATLAS_ROWS = 13


@dataclass(frozen=True)
class ClipSpec:
    name: str
    source: str
    source_frames: int
    selected_frames: tuple[int, ...]
    duration: float
    pointer_eyes: bool
    row: int
    column_offset: int
    contains_prop: bool = False
    source_group: str = "legacy"
    frame_durations: tuple[float, ...] = ()
    playback_mode: str = "loop"
    hold_frame: int | None = None
    hold_duration: float | None = None
    loop_range: tuple[int, int] | None = None
    mirror_policy: str = "automatic"
    left_clip: str | None = None
    right_clip: str | None = None
    turn_left_clip: str | None = None
    turn_right_clip: str | None = None
    target_height: int | None = None


CLIPS = (
    ClipSpec(
        "idle",
        "idle-transparent.png",
        6,
        (0, 1, 2, 3, 4, 5),
        0.18,
        True,
        0,
        0,
        source_group="v09",
        frame_durations=(0.42, 0.25, 0.28, 0.35, 0.32, 0.65),
        mirror_policy="never",
        left_clip="idle-left",
        turn_left_clip="turn-left",
        turn_right_clip="turn-right",
        target_height=300,
    ),
    ClipSpec(
        "patrol",
        "patrol-right-transparent.png",
        8,
        tuple(range(8)),
        0.12,
        True,
        1,
        0,
        source_group="v09",
        frame_durations=(0.12, 0.12, 0.12, 0.12, 0.12, 0.12, 0.12, 0.22),
        mirror_policy="never",
        left_clip="patrol-left",
        turn_left_clip="turn-left",
        turn_right_clip="turn-right",
        target_height=300,
    ),
    ClipSpec(
        "patrol-left",
        "patrol-left-transparent.png",
        8,
        tuple(range(8)),
        0.12,
        True,
        2,
        0,
        source_group="v09",
        frame_durations=(0.12, 0.12, 0.12, 0.12, 0.12, 0.12, 0.12, 0.22),
        mirror_policy="never",
        target_height=300,
    ),
    ClipSpec(
        "turn-left",
        "turn-transparent.png",
        6,
        (0, 1, 2, 3, 4, 5),
        0.15,
        True,
        3,
        0,
        source_group="v09",
        frame_durations=(0.13, 0.15, 0.17, 0.17, 0.15, 0.24),
        playback_mode="once",
        mirror_policy="never",
        target_height=300,
    ),
    ClipSpec(
        "turn-right",
        "turn-transparent.png",
        6,
        (5, 4, 3, 2, 1, 0),
        0.15,
        True,
        4,
        0,
        source_group="v09",
        frame_durations=(0.13, 0.15, 0.17, 0.17, 0.15, 0.24),
        playback_mode="once",
        mirror_policy="never",
        target_height=300,
    ),
    ClipSpec(
        "laptop",
        "laptop-transparent.png",
        6,
        tuple(range(6)),
        0.16,
        True,
        5,
        0,
        True,
        source_group="v09",
        frame_durations=(0.28, 0.18, 0.18, 0.30, 0.24, 0.42),
        # No readable text is present on the rigid prop, so mirroring the
        # complete authored pose is safe and preserves Migi's current facing.
        mirror_policy="automatic",
        turn_left_clip="turn-left",
        turn_right_clip="turn-right",
        target_height=300,
    ),
    ClipSpec(
        "phone",
        "phone-transparent.png",
        6,
        tuple(range(6)),
        0.20,
        True,
        6,
        0,
        True,
        source_group="v09",
        frame_durations=(0.55, 0.22, 0.52, 1.35, 0.46, 1.05),
        mirror_policy="automatic",
        turn_left_clip="turn-left",
        turn_right_clip="turn-right",
        target_height=300,
    ),
    ClipSpec(
        "book",
        "book-transparent.png",
        6,
        tuple(range(6)),
        0.18,
        True,
        7,
        0,
        True,
        source_group="v09",
        frame_durations=(0.38, 0.25, 0.30, 0.36, 0.58, 0.72),
        mirror_policy="automatic",
        turn_left_clip="turn-left",
        turn_right_clip="turn-right",
        target_height=300,
    ),
    # Source frame 2 contains an unwanted detached blue sphere. It is excluded.
    ClipSpec(
        "failed",
        "failed-transparent.png",
        4,
        (0, 1, 3, 0),
        0.24,
        False,
        8,
        0,
        playback_mode="once",
    ),
    ClipSpec(
        "inspect-hand",
        "inspect-hand-transparent.png",
        4,
        (0, 1, 2, 3),
        0.24,
        True,
        8,
        4,
        playback_mode="enter-hold-retract",
        hold_frame=2,
        hold_duration=0.38,
    ),
    ClipSpec(
        "sharpen-tip",
        "sharpen-tip-canonical-transparent.png",
        4,
        (0, 1, 2, 3),
        0.22,
        True,
        9,
        0,
        source_group="blade",
        playback_mode="enter-hold-retract",
        hold_frame=2,
        hold_duration=0.62,
    ),
    ClipSpec(
        "look-around",
        "look-around-transparent.png",
        4,
        (0, 1, 2, 3),
        0.26,
        True,
        9,
        4,
        playback_mode="once",
    ),
    ClipSpec(
        "stretch",
        "stretch-transparent.png",
        4,
        (0, 1, 2, 3),
        0.26,
        True,
        10,
        0,
        playback_mode="once",
    ),
    ClipSpec(
        "dormant",
        "dormant-transparent.png",
        4,
        (0, 1, 2, 3),
        0.30,
        False,
        10,
        4,
        loop_range=(1, 2),
    ),
    ClipSpec(
        "rapid-notes",
        "rapid-notes-transparent.png",
        4,
        (0, 1, 2, 3),
        0.24,
        True,
        11,
        0,
        True,
        turn_left_clip="turn-left",
        turn_right_clip="turn-right",
        target_height=300,
    ),
    ClipSpec(
        "fine-motor",
        "fine-motor-transparent.png",
        4,
        (0, 1, 2, 3),
        0.20,
        True,
        11,
        4,
        turn_left_clip="turn-left",
        turn_right_clip="turn-right",
    ),
    ClipSpec(
        "organ-drift",
        "organ-drift-transparent.png",
        4,
        (0, 1, 2, 3),
        0.30,
        False,
        12,
        0,
        playback_mode="once",
    ),
    ClipSpec(
        "logic-count",
        "logic-count-transparent.png",
        4,
        (0, 1, 2, 3),
        0.28,
        False,
        12,
        4,
        playback_mode="once",
    ),
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def alpha_bbox(image: Image.Image) -> tuple[int, int, int, int]:
    bbox = image.getchannel("A").getbbox()
    if bbox is None:
        raise SystemExit("encountered an empty animation slot")
    return bbox


def extract_pose_groups(path: Path, frame_count: int) -> list[Image.Image]:
    with Image.open(path) as opened:
        strip = opened.convert("RGBA")
    alpha = strip.getchannel("A")
    mask = alpha.point(lambda value: 255 if value > 16 else 0)
    components = connected_components(mask)
    if len(components) < frame_count:
        raise SystemExit(f"could not identify {frame_count} complete poses in {path}")

    slot_width = strip.width / frame_count
    seeds: list[dict[str, object]] = []
    for index in range(frame_count):
        left = index * slot_width
        right = (index + 1) * slot_width
        candidates = [
            component
            for component in components
            if left <= float(component["center_x"]) < right
        ]
        if not candidates:
            raise SystemExit(f"missing pose component in slot {index} of {path}")
        seeds.append(max(candidates, key=lambda component: int(component["area"])))

    seed_ids = {id(seed) for seed in seeds}
    groups: list[list[dict[str, object]]] = [[seed] for seed in seeds]
    for component in components:
        if id(component) in seed_ids or int(component["area"]) < 8:
            continue
        nearest = min(
            range(frame_count),
            key=lambda index: abs(
                float(seeds[index]["center_x"]) - float(component["center_x"])
            ),
        )
        groups[nearest].append(component)

    frames: list[Image.Image] = []
    source_pixels = strip.load()
    for group in groups:
        min_x = min(int(component["bbox"][0]) for component in group)
        min_y = min(int(component["bbox"][1]) for component in group)
        max_x = max(int(component["bbox"][2]) for component in group)
        max_y = max(int(component["bbox"][3]) for component in group)
        frame = Image.new("RGBA", (max_x - min_x, max_y - min_y), (0, 0, 0, 0))
        frame_pixels = frame.load()
        for component in group:
            for pixel_index in component["pixels"]:
                x = int(pixel_index) % strip.width
                y = int(pixel_index) // strip.width
                frame_pixels[x - min_x, y - min_y] = source_pixels[x, y]
        frames.append(frame)
    return frames


def normalize_clip(
    frames: list[Image.Image],
    target_height: int | None = None,
) -> list[Image.Image]:
    bboxes = [alpha_bbox(frame) for frame in frames]
    crops = [frame.crop(bbox) for frame, bbox in zip(frames, bboxes)]
    maximum_width = max(crop.width for crop in crops)
    maximum_height = max(crop.height for crop in crops)
    scale_candidates = [
        (CELL_SIZE - 24) / maximum_width,
        (CELL_SIZE - 24) / maximum_height,
    ]
    if target_height is None:
        # Legacy strips already have their intended scale and should never be
        # enlarged. The v0.9 redraws are high-resolution sources whose pose
        # crops vary, so they deliberately normalize both up and down.
        scale_candidates.append(1.0)
    else:
        scale_candidates.append(target_height / maximum_height)
    scale = min(scale_candidates)

    normalized: list[Image.Image] = []
    for crop in crops:
        if abs(scale - 1.0) > 0.001:
            crop = crop.resize(
                (max(1, round(crop.width * scale)), max(1, round(crop.height * scale))),
                Image.Resampling.LANCZOS,
            )
        cell = Image.new("RGBA", (CELL_SIZE, CELL_SIZE), (0, 0, 0, 0))
        left = (CELL_SIZE - crop.width) // 2
        top = CELL_SIZE - 12 - crop.height
        cell.alpha_composite(crop, (left, top))
        normalized.append(cell)
    return normalized


def connected_components(mask: Image.Image) -> list[dict[str, object]]:
    width, height = mask.size
    pixels = mask.load()
    visited = bytearray(width * height)
    components: list[dict[str, object]] = []
    for y in range(height):
        for x in range(width):
            offset = y * width + x
            if visited[offset] or pixels[x, y] == 0:
                continue
            visited[offset] = 1
            queue = deque([(x, y)])
            area = 0
            component_pixels: list[int] = []
            min_x = max_x = x
            min_y = max_y = y
            while queue:
                current_x, current_y = queue.popleft()
                area += 1
                component_pixels.append(current_y * width + current_x)
                min_x = min(min_x, current_x)
                max_x = max(max_x, current_x)
                min_y = min(min_y, current_y)
                max_y = max(max_y, current_y)
                for next_x, next_y in (
                    (current_x - 1, current_y),
                    (current_x + 1, current_y),
                    (current_x, current_y - 1),
                    (current_x, current_y + 1),
                ):
                    if not (0 <= next_x < width and 0 <= next_y < height):
                        continue
                    next_offset = next_y * width + next_x
                    if visited[next_offset] or pixels[next_x, next_y] == 0:
                        continue
                    visited[next_offset] = 1
                    queue.append((next_x, next_y))
            components.append(
                {
                    "area": area,
                    "bbox": (min_x, min_y, max_x + 1, max_y + 1),
                    "center_x": (min_x + max_x + 1) * 0.5,
                    "pixels": component_pixels,
                }
            )
    return components


def detect_eye_anchors(cell: Image.Image) -> list[dict[str, float]]:
    rgba = cell.convert("RGBA")
    mask = Image.new("L", rgba.size, 0)
    source = rgba.load()
    output = mask.load()
    for y in range(round(CELL_SIZE * 0.08), round(CELL_SIZE * 0.72)):
        for x in range(CELL_SIZE):
            red, green, blue, alpha = source[x, y]
            neutral = max(red, green, blue) - min(red, green, blue) < 54
            warm_white = red > 205 and green > 200 and blue > 170
            if alpha > 220 and neutral and warm_white:
                output[x, y] = 255

    candidates: list[tuple[int, tuple[int, int, int, int]]] = []
    for component in connected_components(mask):
        area = int(component["area"])
        bbox = component["bbox"]
        width = bbox[2] - bbox[0]
        height = bbox[3] - bbox[1]
        aspect = width / max(height, 1)
        if 55 <= area <= 1800 and 0.55 <= aspect <= 1.8 and 9 <= width <= 42 and 9 <= height <= 42:
            candidates.append((area, bbox))

    candidates.sort(key=lambda item: item[0], reverse=True)
    if candidates:
        # Specular highlights and teeth can satisfy the warm-white color test,
        # but they are much smaller than even Migi's retracted secondary eye.
        # Keep anatomy-relative candidates rather than blindly taking two.
        minimum_eye_area = max(100, round(candidates[0][0] * 0.25))
        candidates = [
            item for item in candidates
            if item[0] >= minimum_eye_area
        ]
    anchors = []
    for _, bbox in candidates[:2]:
        width = bbox[2] - bbox[0]
        height = bbox[3] - bbox[1]
        anchors.append(
            {
                "x": ((bbox[0] + bbox[2]) * 0.5) / CELL_SIZE,
                "y": ((bbox[1] + bbox[3]) * 0.5) / CELL_SIZE,
                "radius": (max(width, height) * 0.5) / CELL_SIZE,
            }
        )
    # Migi may retract one eye stalk during a turn or crawl. Keep every visible
    # eye interactive instead of invalidating the frame when anatomy changes.
    if not anchors:
        return []
    return sorted(anchors, key=lambda anchor: anchor["radius"], reverse=True)


def build_contact_sheet(
    atlas: Image.Image,
    clips: tuple[ClipSpec, ...],
    destination: Path,
) -> None:
    checker = Image.new("RGB", atlas.size, (230, 230, 230))
    draw = ImageDraw.Draw(checker)
    block = 24
    for y in range(0, checker.height, block):
        for x in range(0, checker.width, block):
            if (x // block + y // block) % 2:
                draw.rectangle((x, y, x + block - 1, y + block - 1), fill=(205, 205, 205))
    checker.paste(atlas, (0, 0), atlas)
    overlay = ImageDraw.Draw(checker)
    for spec in clips:
        left = spec.column_offset * CELL_SIZE
        top = spec.row * CELL_SIZE
        label_width = max(104, 12 + len(spec.name) * 7)
        overlay.rectangle(
            (left, top, left + label_width, top + 22),
            fill=(0, 0, 0),
        )
        overlay.text((left + 6, top + 5), spec.name, fill=(255, 255, 255))
    checker.save(destination)


def main() -> None:
    RESOURCE_DIR.mkdir(parents=True, exist_ok=True)
    QA_DIR.mkdir(parents=True, exist_ok=True)
    atlas = Image.new(
        "RGBA",
        (ATLAS_COLUMNS * CELL_SIZE, ATLAS_ROWS * CELL_SIZE),
        (0, 0, 0, 0),
    )

    manifest_clips: dict[str, object] = {}
    source_hashes: dict[str, str] = {}
    occupied_slots: set[tuple[int, int]] = set()
    for spec in CLIPS:
        if not 0 <= spec.row < ATLAS_ROWS:
            raise SystemExit(f"clip row is out of range: {spec.name}")
        if spec.column_offset < 0:
            raise SystemExit(f"clip column offset is negative: {spec.name}")
        if spec.column_offset + len(spec.selected_frames) > ATLAS_COLUMNS:
            raise SystemExit(f"clip exceeds atlas columns: {spec.name}")
        for column in range(
            spec.column_offset,
            spec.column_offset + len(spec.selected_frames),
        ):
            slot = (spec.row, column)
            if slot in occupied_slots:
                raise SystemExit(f"overlapping atlas slot for clip: {spec.name}")
            occupied_slots.add(slot)

        source_dirs = {
            "legacy": LEGACY_STRIPS_DIR,
            "v09": V09_STRIPS_DIR,
            "blade": BLADE_CANON_STRIPS_DIR,
        }
        source_dir = source_dirs.get(spec.source_group)
        if source_dir is None:
            raise SystemExit(
                f"unknown source group {spec.source_group!r}: {spec.name}"
            )
        path = source_dir / spec.source
        if not path.is_file():
            raise SystemExit(f"missing approved strip: {path}")
        source_hashes[spec.name] = sha256(path)
        source_frames = extract_pose_groups(path, spec.source_frames)
        selected = [source_frames[index] for index in spec.selected_frames]
        normalized = normalize_clip(selected, target_height=spec.target_height)
        eye_frames: list[list[dict[str, float]]] = []
        for relative_column, cell in enumerate(normalized):
            column = spec.column_offset + relative_column
            atlas.alpha_composite(
                cell,
                (column * CELL_SIZE, spec.row * CELL_SIZE),
            )
            eye_frames.append(detect_eye_anchors(cell) if spec.pointer_eyes else [])
        manifest_clip: dict[str, object] = {
            "row": spec.row,
            "column_offset": spec.column_offset,
            "frame_count": len(normalized),
            "frame_duration": spec.duration,
            "frame_durations": (
                list(spec.frame_durations)
                if spec.frame_durations
                else [spec.duration] * len(normalized)
            ),
            "playback_mode": spec.playback_mode,
            "mirror_policy": spec.mirror_policy,
            "pointer_eyes": spec.pointer_eyes,
            "contains_prop": spec.contains_prop,
            "eyes": eye_frames,
        }
        if spec.hold_frame is not None:
            manifest_clip["hold_frame"] = spec.hold_frame
        if spec.hold_duration is not None:
            manifest_clip["hold_duration"] = spec.hold_duration
        if spec.loop_range is not None:
            manifest_clip["loop_range"] = list(spec.loop_range)
        if spec.left_clip is not None:
            manifest_clip["left_clip"] = spec.left_clip
        if spec.right_clip is not None:
            manifest_clip["right_clip"] = spec.right_clip
        if spec.turn_left_clip is not None:
            manifest_clip["turn_left_clip"] = spec.turn_left_clip
        if spec.turn_right_clip is not None:
            manifest_clip["turn_right_clip"] = spec.turn_right_clip
        manifest_clips[spec.name] = manifest_clip

    # A dedicated leftward idle redraw is unnecessary for this repair: the
    # approved left-patrol contact pose already has the right topology and
    # registration. Expose that single authored frame as a stationary alias
    # instead of mirroring the right-facing neutral body.
    patrol_left = manifest_clips["patrol-left"]
    manifest_clips["idle-left"] = {
        "row": patrol_left["row"],
        "column_offset": patrol_left["column_offset"],
        "frame_count": 1,
        "frame_duration": 0.45,
        "frame_durations": [0.45],
        "playback_mode": "hold",
        "hold_frame": 0,
        "mirror_policy": "never",
        "pointer_eyes": True,
        "contains_prop": False,
        "eyes": [patrol_left["eyes"][0]],
        "turn_left_clip": "turn-left",
        "turn_right_clip": "turn-right",
    }

    atlas_path = RESOURCE_DIR / "migi-v4-atlas.png"
    manifest_path = RESOURCE_DIR / "migi-v4-atlas.json"
    atlas.save(atlas_path, optimize=True)
    manifest = {
        "version": 3,
        "columns": ATLAS_COLUMNS,
        "rows": ATLAS_ROWS,
        "cell_width": CELL_SIZE,
        "cell_height": CELL_SIZE,
        "clips": manifest_clips,
        "source_sha256": source_hashes,
    }
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    build_contact_sheet(
        atlas,
        CLIPS,
        QA_DIR / "contact-sheet.png",
    )
    print(
        json.dumps(
            {
                "ok": True,
                "atlas": str(atlas_path),
                "manifest": str(manifest_path),
                "contact_sheet": str(QA_DIR / "contact-sheet.png"),
                "atlas_sha256": sha256(atlas_path),
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
