#!/usr/bin/env python3
"""Build the v0.10 right-hand-symbiont atlas from approved coherent strips."""

from __future__ import annotations

import importlib.util
import json
import sys
from dataclasses import dataclass
from pathlib import Path

from PIL import Image

PROJECT_DIR = Path(__file__).resolve().parents[1]
WORKSPACE_DIR = PROJECT_DIR.parent
V09_SCRIPT = PROJECT_DIR / "scripts" / "build-v09-atlas.py"
V010_STRIPS_DIR = WORKSPACE_DIR / "work" / "migi-v010-20260730" / "strips"
RESOURCE_DIR = PROJECT_DIR / "Sources" / "MigiAdvanced" / "Resources"
QA_DIR = PROJECT_DIR / "QA" / "fullbody-v0.10.0"

module_spec = importlib.util.spec_from_file_location("migi_v09_atlas", V09_SCRIPT)
if module_spec is None or module_spec.loader is None:
    raise SystemExit(f"unable to load v0.9 atlas builder: {V09_SCRIPT}")
v09 = importlib.util.module_from_spec(module_spec)
sys.modules[module_spec.name] = v09
module_spec.loader.exec_module(v09)

CELL_SIZE = v09.CELL_SIZE
ATLAS_COLUMNS = v09.ATLAS_COLUMNS
ATLAS_ROWS = 21


@dataclass(frozen=True)
class V010ClipSpec:
    name: str
    source: str
    source_frames: int
    selected_frames: tuple[int, ...]
    duration: float
    pointer_eyes: bool
    row: int
    column_offset: int
    contains_prop: bool = False
    frame_durations: tuple[float, ...] = ()
    playback_mode: str = "loop"
    hold_frame: int | None = None
    hold_duration: float | None = None
    loop_range: tuple[int, int] | None = None
    target_height: int = 310
    maximum_eyes: int = 2
    eye_count_caps: tuple[int, ...] = ()
    maximum_eye_aspect: float = 1.95
    force_empty_eye_frames: tuple[int, ...] = ()
    deformation_zones: tuple[dict[str, float], ...] = ()
    rigid_zones: tuple[dict[str, float], ...] = ()


HAND_TISSUE = (
    {"x": 0.43, "y": 0.68, "radius_x": 0.40, "radius_y": 0.30, "gain": 0.62},
    {"x": 0.55, "y": 0.42, "radius_x": 0.32, "radius_y": 0.38, "gain": 0.84},
    {"x": 0.70, "y": 0.25, "radius_x": 0.26, "radius_y": 0.28, "gain": 1.0},
)

NEW_CLIPS = (
    V010ClipSpec(
        "normal-hand",
        "normal-hand-transparent.png",
        4,
        (0, 1, 2, 3),
        0.42,
        True,
        13,
        0,
        frame_durations=(0.62, 0.42, 0.34, 0.58),
        maximum_eyes=1,
        eye_count_caps=(0, 1, 1, 0),
        force_empty_eye_frames=(0, 3),
        deformation_zones=HAND_TISSUE,
    ),
    V010ClipSpec(
        "calm-diagnosis",
        "calm-diagnosis-transparent.png",
        6,
        (0, 1, 4, 5),
        0.26,
        True,
        13,
        4,
        frame_durations=(0.24, 0.28, 0.58, 0.34),
        playback_mode="enter-hold-retract",
        hold_frame=2,
        hold_duration=0.62,
        maximum_eyes=3,
        eye_count_caps=(1, 3, 3, 1),
        deformation_zones=HAND_TISSUE,
    ),
    V010ClipSpec(
        "palm-observer",
        "palm-observer-transparent.png",
        6,
        tuple(range(6)),
        0.24,
        True,
        14,
        0,
        frame_durations=(0.30, 0.24, 0.22, 0.58, 0.26, 0.34),
        playback_mode="enter-hold-retract",
        hold_frame=3,
        hold_duration=0.58,
        maximum_eyes=2,
        eye_count_caps=(1, 1, 2, 2, 1, 1),
        deformation_zones=HAND_TISSUE,
    ),
    V010ClipSpec(
        "signal-sampling",
        "signal-sampling-transparent.png",
        6,
        tuple(range(6)),
        0.22,
        True,
        15,
        0,
        frame_durations=(0.28, 0.22, 0.20, 0.64, 0.22, 0.32),
        playback_mode="enter-hold-retract",
        hold_frame=3,
        hold_duration=0.70,
        maximum_eyes=5,
        eye_count_caps=(1, 2, 4, 5, 3, 1),
        deformation_zones=HAND_TISSUE
        + (
            {
                "x": 0.40,
                "y": 0.22,
                "radius_x": 0.30,
                "radius_y": 0.28,
                "gain": 1.18,
            },
            {
                "x": 0.72,
                "y": 0.18,
                "radius_x": 0.27,
                "radius_y": 0.25,
                "gain": 1.12,
            },
        ),
    ),
    V010ClipSpec(
        "storage-pocket",
        "storage-pocket-transparent.png",
        6,
        tuple(range(6)),
        0.24,
        True,
        16,
        0,
        contains_prop=True,
        frame_durations=(0.30, 0.24, 0.24, 0.72, 0.26, 0.34),
        playback_mode="enter-hold-retract",
        hold_frame=3,
        hold_duration=0.66,
        maximum_eyes=1,
        eye_count_caps=(1, 1, 1, 1, 1, 1),
        deformation_zones=HAND_TISSUE,
        rigid_zones=(
            {
                "min_x": 0.57,
                "min_y": 0.15,
                "max_x": 0.86,
                "max_y": 0.68,
                "feather": 0.035,
            },
        ),
    ),
    V010ClipSpec(
        "recovery-care",
        "recovery-care-transparent.png",
        6,
        tuple(range(6)),
        0.28,
        True,
        17,
        0,
        contains_prop=True,
        frame_durations=(0.34, 0.26, 0.30, 0.78, 0.30, 0.42),
        playback_mode="once",
        maximum_eyes=2,
        eye_count_caps=(1, 2, 1, 2, 1, 1),
        deformation_zones=HAND_TISSUE,
        rigid_zones=(
            {
                "min_x": 0.50,
                "min_y": 0.08,
                "max_x": 0.82,
                "max_y": 0.70,
                "feather": 0.035,
            },
        ),
    ),
    V010ClipSpec(
        "detached-scout-return",
        "detached-scout-return-transparent.png",
        8,
        tuple(range(8)),
        0.20,
        True,
        18,
        0,
        frame_durations=(0.28, 0.22, 0.20, 0.24, 0.30, 0.28, 0.24, 0.42),
        playback_mode="once",
        maximum_eyes=2,
        eye_count_caps=(1, 1, 2, 1, 1, 1, 2, 1),
        maximum_eye_aspect=2.60,
        target_height=300,
        deformation_zones=HAND_TISSUE,
    ),
    V010ClipSpec(
        "complete-sleep",
        "complete-sleep-transparent.png",
        8,
        tuple(range(8)),
        0.34,
        True,
        19,
        0,
        frame_durations=(0.30, 0.28, 0.28, 0.34, 0.80, 0.80, 0.32, 0.34),
        playback_mode="loop",
        loop_range=(4, 5),
        maximum_eyes=2,
        eye_count_caps=(1, 1, 0, 0, 0, 0, 1, 1),
        force_empty_eye_frames=(2, 3, 4, 5),
        deformation_zones=HAND_TISSUE,
    ),
    V010ClipSpec(
        "protective-shield",
        "protective-shield-transparent.png",
        6,
        tuple(range(6)),
        0.20,
        True,
        20,
        0,
        frame_durations=(0.24, 0.20, 0.20, 0.62, 0.22, 0.32),
        playback_mode="enter-hold-retract",
        hold_frame=3,
        hold_duration=0.62,
        maximum_eyes=2,
        eye_count_caps=(2, 1, 1, 1, 1, 2),
        deformation_zones=HAND_TISSUE
        + (
            {
                "x": 0.52,
                "y": 0.42,
                "radius_x": 0.44,
                "radius_y": 0.36,
                "gain": 0.88,
            },
        ),
    ),
)


def detect_eye_anchors(
    cell: Image.Image,
    maximum_eyes: int,
    maximum_aspect: float = 1.95,
) -> list[dict[str, float | str]]:
    """Detect up to four authored eyeballs and assign stable tracking families."""
    rgba = cell.convert("RGBA")
    mask = Image.new("L", rgba.size, 0)
    source = rgba.load()
    output = mask.load()
    for y in range(round(CELL_SIZE * 0.04), round(CELL_SIZE * 0.82)):
        for x in range(CELL_SIZE):
            red, green, blue, alpha = source[x, y]
            neutral = max(red, green, blue) - min(red, green, blue) < 58
            warm_white = red > 202 and green > 196 and blue > 164
            if alpha > 218 and neutral and warm_white:
                output[x, y] = 255

    candidates: list[tuple[int, tuple[int, int, int, int]]] = []
    for component in v09.connected_components(mask):
        area = int(component["area"])
        bbox = component["bbox"]
        width = bbox[2] - bbox[0]
        height = bbox[3] - bbox[1]
        aspect = width / max(height, 1)
        if (
            42 <= area <= 2200
            and 0.48 <= aspect <= maximum_aspect
            and 8 <= width <= 48
            and 8 <= height <= 48
        ):
            candidates.append((area, bbox))

    candidates.sort(key=lambda item: item[0], reverse=True)
    if candidates:
        minimum_eye_area = max(78, round(candidates[0][0] * 0.20))
        candidates = [item for item in candidates if item[0] >= minimum_eye_area]
    chosen = candidates[: max(maximum_eyes, 0)]

    raw: list[dict[str, float | str]] = []
    for _, bbox in chosen:
        width = bbox[2] - bbox[0]
        height = bbox[3] - bbox[1]
        raw.append(
            {
                "x": ((bbox[0] + bbox[2]) * 0.5) / CELL_SIZE,
                "y": ((bbox[1] + bbox[3]) * 0.5) / CELL_SIZE,
                "radius": (max(width, height) * 0.5) / CELL_SIZE,
            }
        )
    raw.sort(key=lambda anchor: float(anchor["radius"]), reverse=True)
    for index, anchor in enumerate(raw):
        if index == 0:
            anchor["tracking_id"] = "primary"
            anchor["tracking_gain"] = 0.78
            anchor["vertical_gain"] = 0.70
            anchor["tracking_stiffness"] = 7.8
        else:
            anchor["tracking_id"] = f"branch-{index}"
            anchor["tracking_gain"] = 0.56 + min(index, 3) * 0.06
            anchor["vertical_gain"] = 0.54 + min(index, 3) * 0.05
            anchor["tracking_stiffness"] = 6.1 + min(index, 3) * 0.45
    return raw


def detect_iris_eye_anchors(
    cell: Image.Image,
    maximum_eyes: int,
) -> list[dict[str, float | str]]:
    """Detect authored olive-gold irises instead of pale nails or props."""
    rgba = cell.convert("RGBA")
    mask = Image.new("L", rgba.size, 0)
    source = rgba.load()
    output = mask.load()
    for y in range(round(CELL_SIZE * 0.04), round(CELL_SIZE * 0.92)):
        for x in range(CELL_SIZE):
            red, green, blue, alpha = source[x, y]
            if (
                alpha > 218
                and red >= 68
                and green >= 58
                and blue <= 105
                and red - blue >= 35
                and green - blue >= 30
                and abs(red - green) <= 25
            ):
                output[x, y] = 255

    components: list[dict[str, float | int | tuple[int, int, int, int]]] = []
    for component in v09.connected_components(mask):
        area = int(component["area"])
        bbox = component["bbox"]
        width = bbox[2] - bbox[0]
        height = bbox[3] - bbox[1]
        if (
            3 <= area <= 600
            and 1 <= width <= 36
            and 1 <= height <= 36
        ):
            components.append(
                {
                    "area": area,
                    "bbox": bbox,
                    "center_x": (bbox[0] + bbox[2]) * 0.5,
                    "center_y": (bbox[1] + bbox[3]) * 0.5,
                }
            )

    clusters: list[dict[str, object]] = []
    for component in sorted(
        components,
        key=lambda item: int(item["area"]),
        reverse=True,
    ):
        target: dict[str, object] | None = None
        for cluster in clusters:
            distance = (
                (float(component["center_x"]) - float(cluster["center_x"])) ** 2
                + (float(component["center_y"]) - float(cluster["center_y"])) ** 2
            ) ** 0.5
            if distance <= 20:
                target = cluster
                break
        if target is None:
            clusters.append(
                {
                    "items": [component],
                    "area": int(component["area"]),
                    "center_x": float(component["center_x"]),
                    "center_y": float(component["center_y"]),
                }
            )
            continue

        previous_area = int(target["area"])
        component_area = int(component["area"])
        combined_area = previous_area + component_area
        target["items"].append(component)
        target["area"] = combined_area
        target["center_x"] = (
            float(target["center_x"]) * previous_area
            + float(component["center_x"]) * component_area
        ) / combined_area
        target["center_y"] = (
            float(target["center_y"]) * previous_area
            + float(component["center_y"]) * component_area
        ) / combined_area

    candidates: list[tuple[int, dict[str, float | str]]] = []
    for cluster in clusters:
        items = cluster["items"]
        largest = max(items, key=lambda item: int(item["area"]))
        bbox = largest["bbox"]
        width = bbox[2] - bbox[0]
        height = bbox[3] - bbox[1]
        aspect = width / max(height, 1)
        if (
            int(cluster["area"]) < 18
            or int(largest["area"]) < 8
            or not 0.35 <= aspect <= 2.80
        ):
            continue
        candidates.append(
            (
                int(cluster["area"]),
                {
                    "x": float(cluster["center_x"]) / CELL_SIZE,
                    "y": float(cluster["center_y"]) / CELL_SIZE,
                    "radius": max(width, height) * 0.95 / CELL_SIZE,
                },
            )
        )

    candidates.sort(key=lambda item: item[0], reverse=True)
    raw = [anchor for _, anchor in candidates[: max(maximum_eyes, 0)]]
    raw.sort(key=lambda anchor: float(anchor["radius"]), reverse=True)
    for index, anchor in enumerate(raw):
        if index == 0:
            anchor["tracking_id"] = "primary"
            anchor["tracking_gain"] = 0.78
            anchor["vertical_gain"] = 0.70
            anchor["tracking_stiffness"] = 7.8
        else:
            anchor["tracking_id"] = f"branch-{index}"
            anchor["tracking_gain"] = 0.56 + min(index, 4) * 0.06
            anchor["vertical_gain"] = 0.54 + min(index, 4) * 0.05
            anchor["tracking_stiffness"] = 6.1 + min(index, 4) * 0.45
    return raw


def source_path(spec: object) -> Path:
    if isinstance(spec, V010ClipSpec):
        return V010_STRIPS_DIR / spec.source
    source_dirs = {
        "legacy": v09.LEGACY_STRIPS_DIR,
        "v09": v09.V09_STRIPS_DIR,
        "blade": v09.BLADE_CANON_STRIPS_DIR,
    }
    source_dir = source_dirs.get(spec.source_group)
    if source_dir is None:
        raise SystemExit(f"unknown source group {spec.source_group!r}: {spec.name}")
    return source_dir / spec.source


def main() -> None:
    RESOURCE_DIR.mkdir(parents=True, exist_ok=True)
    QA_DIR.mkdir(parents=True, exist_ok=True)
    atlas = Image.new(
        "RGBA",
        (ATLAS_COLUMNS * CELL_SIZE, ATLAS_ROWS * CELL_SIZE),
        (0, 0, 0, 0),
    )
    manifest_clips: dict[str, dict[str, object]] = {}
    source_hashes: dict[str, str] = {}
    occupied_slots: set[tuple[int, int]] = set()

    all_specs = tuple(v09.CLIPS) + NEW_CLIPS
    for spec in all_specs:
        selected_frames = spec.selected_frames
        if not 0 <= spec.row < ATLAS_ROWS:
            raise SystemExit(f"clip row is out of range: {spec.name}")
        if spec.column_offset + len(selected_frames) > ATLAS_COLUMNS:
            raise SystemExit(f"clip exceeds atlas columns: {spec.name}")
        for column in range(
            spec.column_offset,
            spec.column_offset + len(selected_frames),
        ):
            slot = (spec.row, column)
            if slot in occupied_slots:
                raise SystemExit(f"overlapping atlas slot for clip: {spec.name}")
            occupied_slots.add(slot)

        path = source_path(spec)
        if not path.is_file():
            raise SystemExit(f"missing approved strip: {path}")
        source_hashes[spec.name] = v09.sha256(path)
        source_frames = v09.extract_pose_groups(path, spec.source_frames)
        selected = [source_frames[index] for index in selected_frames]
        target_height = getattr(spec, "target_height", None)
        normalized = v09.normalize_clip(selected, target_height=target_height)

        eye_frames: list[list[dict[str, float | str]]] = []
        maximum_eyes = getattr(spec, "maximum_eyes", 2)
        eye_count_caps = getattr(spec, "eye_count_caps", ())
        maximum_eye_aspect = getattr(spec, "maximum_eye_aspect", 1.95)
        force_empty_eye_frames = getattr(spec, "force_empty_eye_frames", ())
        for relative_column, cell in enumerate(normalized):
            column = spec.column_offset + relative_column
            atlas.alpha_composite(
                cell,
                (column * CELL_SIZE, spec.row * CELL_SIZE),
            )
            if relative_column in force_empty_eye_frames:
                eye_frames.append([])
            elif spec.pointer_eyes:
                frame_eye_cap = (
                    eye_count_caps[relative_column]
                    if relative_column < len(eye_count_caps)
                    else maximum_eyes
                )
                if isinstance(spec, V010ClipSpec):
                    eye_frames.append(
                        detect_iris_eye_anchors(
                            cell,
                            frame_eye_cap,
                        )
                    )
                else:
                    eye_frames.append(
                        detect_eye_anchors(
                            cell,
                            frame_eye_cap,
                            maximum_eye_aspect,
                        )
                    )
            else:
                eye_frames.append([])

        frame_durations = (
            list(spec.frame_durations)
            if spec.frame_durations
            else [spec.duration] * len(normalized)
        )
        manifest_clip: dict[str, object] = {
            "row": spec.row,
            "column_offset": spec.column_offset,
            "frame_count": len(normalized),
            "frame_duration": spec.duration,
            "frame_durations": frame_durations,
            "playback_mode": spec.playback_mode,
            "mirror_policy": (
                "never" if isinstance(spec, V010ClipSpec) else spec.mirror_policy
            ),
            "pointer_eyes": spec.pointer_eyes,
            "contains_prop": spec.contains_prop,
            "eyes": eye_frames,
        }
        for key in (
            "hold_frame",
            "hold_duration",
            "left_clip",
            "right_clip",
            "turn_left_clip",
            "turn_right_clip",
        ):
            value = getattr(spec, key, None)
            if value is not None:
                manifest_clip[key] = value
        loop_range = getattr(spec, "loop_range", None)
        if loop_range is not None:
            manifest_clip["loop_range"] = list(loop_range)
        deformation_zones = getattr(spec, "deformation_zones", ())
        rigid_zones = getattr(spec, "rigid_zones", ())
        if deformation_zones:
            manifest_clip["deformation_zones"] = list(deformation_zones)
        if rigid_zones:
            manifest_clip["rigid_zones"] = list(rigid_zones)
        manifest_clips[spec.name] = manifest_clip

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

    sleep_clip = manifest_clips["complete-sleep"]
    manifest_clips["complete-sleep-wake"] = {
        "row": sleep_clip["row"],
        "column_offset": 6,
        "frame_count": 2,
        "frame_duration": 0.32,
        "frame_durations": [0.32, 0.36],
        "playback_mode": "once",
        "mirror_policy": "never",
        "pointer_eyes": True,
        "contains_prop": False,
        "eyes": sleep_clip["eyes"][6:8],
        "deformation_zones": list(HAND_TISSUE),
    }

    atlas_path = RESOURCE_DIR / "migi-v4-atlas.png"
    manifest_path = RESOURCE_DIR / "migi-v4-atlas.json"
    atlas.save(atlas_path, optimize=True)
    manifest = {
        "version": 4,
        "columns": ATLAS_COLUMNS,
        "rows": ATLAS_ROWS,
        "cell_width": CELL_SIZE,
        "cell_height": CELL_SIZE,
        "clips": manifest_clips,
        "source_sha256": source_hashes,
    }
    manifest_path.write_text(
        json.dumps(manifest, indent=2) + "\n",
        encoding="utf-8",
    )
    v09.build_contact_sheet(
        atlas,
        all_specs,
        QA_DIR / "contact-sheet.png",
    )
    print(
        json.dumps(
            {
                "ok": True,
                "atlas": str(atlas_path),
                "manifest": str(manifest_path),
                "contact_sheet": str(QA_DIR / "contact-sheet.png"),
                "atlas_sha256": v09.sha256(atlas_path),
                "rows": ATLAS_ROWS,
                "clips": len(manifest_clips),
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
