#!/usr/bin/env python3
"""Compare controlled production Metal readbacks; never synthesize pet art."""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[1]
QA = ROOT / "QA" / "motion-quality-v0.15.0"
SCENARIOS = {
    "breathing": "Breathing / changing energy",
    "work-rate": "Work / 0.75x > 1.40x > 0.75x",
    "blink-gaze": "Eyelids / delayed gaze",
    "handoff": "Idle > laptop > phone",
}
FONT = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 14)


def tile(path: Path, background=(239, 237, 230)) -> Image.Image:
    source = Image.open(path).convert("RGBA")
    result = Image.new("RGBA", source.size, (*background, 255))
    result.alpha_composite(source)
    return result.convert("RGB")


def main() -> None:
    report: dict = {"ok": True, "errors": [], "scenarios": {}, "atlas_sha256": {}}
    for name in ["migi-v4-atlas.png", "migi-v4-atlas.json", "migi-v4-atlas.ktx"]:
        path = ROOT / "Sources" / "MigiAdvanced" / "Resources" / name
        report["atlas_sha256"][name] = hashlib.sha256(path.read_bytes()).hexdigest()
    for scenario, label in SCENARIOS.items():
        info = {}
        for variant in ["before", "after"]:
            directory = QA / variant / scenario
            paths = sorted(directory.glob("[0-9][0-9][0-9][0-9].png"))
            if len(paths) != 180:
                report["errors"].append(f"{variant}/{scenario}: expected 180 frames, got {len(paths)}")
            smallest = 230 * 270
            for path in paths:
                source = Image.open(path).convert("RGBA")
                bbox = source.getchannel("A").getbbox()
                if source.size != (230, 270) or bbox is None:
                    report["errors"].append(f"invalid:{path}")
                elif bbox[0] <= 0 or bbox[1] <= 0 or bbox[2] >= 230 or bbox[3] >= 270:
                    report["errors"].append(f"clipped:{path}")
                if bbox:
                    smallest = min(smallest, (bbox[2] - bbox[0]) * (bbox[3] - bbox[1]))
            samples = json.loads((directory / "samples.json").read_text())
            # The laptop row has six authored frames in forward cyclic order.
            # At these playback rates a 30-Hz capture cannot legitimately skip.
            skips = []
            if scenario == "work-rate":
                for previous, current in zip(samples, samples[1:]):
                    step = (current["column"] - previous["column"]) % 6
                    if step > 1:
                        skips.append({"time": current["time"], "from": previous["column"], "to": current["column"]})
            info[variant] = {"frames": len(paths), "minimum_bbox_area": smallest,
                             "skipped_frame_events": skips,
                             "frame_rate_changes": sum(a["fps"] != b["fps"] for a, b in zip(samples, samples[1:]))}
        if scenario == "work-rate" and info["after"]["skipped_frame_events"]:
            report["errors"].append("New work playback skipped an authored frame")
        report["scenarios"][scenario] = info

        video = QA / f"{scenario}-comparison.mp4"
        ffmpeg = shutil.which("ffmpeg")
        if not ffmpeg:
            raise SystemExit("ffmpeg is required for motion comparison videos")
        process = subprocess.Popen([
            ffmpeg, "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
            "-s", "480x326", "-r", "30", "-i", "-", "-an", "-c:v", "libx264",
            "-preset", "fast", "-crf", "17", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(video)
        ], stdin=subprocess.PIPE)
        assert process.stdin is not None
        for index in range(180):
            frame = Image.new("RGB", (480, 326), (25, 28, 32))
            draw = ImageDraw.Draw(frame)
            draw.text((10, 8), label, font=FONT, fill=(240, 240, 235))
            draw.text((10, 31), "Before", font=FONT, fill=(195, 198, 204))
            draw.text((250, 31), "After", font=FONT, fill=(128, 217, 186))
            for x, variant in [(5, "before"), (245, "after")]:
                frame.paste(tile(QA / variant / scenario / f"{index:04d}.png"), (x, 52))
            process.stdin.write(frame.tobytes())
        process.stdin.close()
        if process.wait() != 0:
            raise SystemExit(f"ffmpeg failed for {scenario}")

    # The full motion clip is already a GPU readback; enlarged crops only
    # make blink coverage and the semantic midpoint easier to inspect.
    sheet = Image.new("RGB", (1200, 580), (239, 237, 230))
    draw = ImageDraw.Draw(sheet)
    for row, variant in enumerate(["before", "after"]):
        draw.text((8, row * 290 + 5), f"{variant.upper()} / blink closure + release", font=FONT, fill=(25, 28, 32))
        for column, index in enumerate([60, 61, 62, 63, 65, 68]):
            sprite = tile(QA / variant / "blink-gaze" / f"{index:04d}.png")
            crop = sprite.crop((55, 30, 205, 175)).resize((195, 225), Image.Resampling.LANCZOS)
            sheet.paste(crop, (column * 200, row * 290 + 35))
            draw.text((column * 200 + 8, row * 290 + 265), f"t={index / 30:.3f}s", font=FONT, fill=(40, 45, 50))
    sheet.save(QA / "blink-contact.png")

    sheet = Image.new("RGB", (1150, 590), (239, 237, 230))
    draw = ImageDraw.Draw(sheet)
    for row, variant in enumerate(["before", "after"]):
        for column, index in enumerate([61, 63, 65, 66, 70]):
            sheet.paste(tile(QA / variant / "handoff" / f"{index:04d}.png"), (column * 230, row * 295 + 25))
            draw.text((column * 230 + 8, row * 295 + 5), f"{variant} / t={index / 30:.3f}s", font=FONT, fill=(40, 45, 50))
    sheet.save(QA / "handoff-contact.png")
    multi = QA / "after" / "multi-eye-blink"
    paths = sorted(multi.glob("[0-9][0-9][0-9][0-9].png"))
    samples = json.loads((multi / "samples.json").read_text())
    if len(paths) != 180 or any(sample["eyes"] < 2 for sample in samples):
        report["errors"].append("Dual-eye sequence is incomplete or contains a one-eye pose")
    for path in paths:
        source = Image.open(path).convert("RGBA")
        bbox = source.getchannel("A").getbbox()
        if source.size != (230, 270) or bbox is None or not (0 < bbox[0] < bbox[2] < 230 and 0 < bbox[1] < bbox[3] < 270):
            report["errors"].append(f"invalid-multi-eye:{path}")
    report["multi_eye_blink"] = {
        "frames": len(paths), "minimum_eye_count": min(sample["eyes"] for sample in samples),
        "blink_samples": [sample for sample in samples if 2 <= sample["time"] <= 2.30]
    }
    sheet = Image.new("RGB", (945, 870), (239, 237, 230))
    draw = ImageDraw.Draw(sheet)
    for index, frame_index in enumerate([59, 60, 61, 62, 63, 64, 65, 66, 68]):
        x, y = (index % 3) * 315, (index // 3) * 290
        sprite = tile(multi / f"{frame_index:04d}.png")
        crop = sprite.crop((10, 30, 220, 200)).resize((315, 255), Image.Resampling.LANCZOS)
        sheet.paste(crop, (x, y + 30))
        draw.text((x + 8, y + 6), f"Dual eye / t={frame_index / 30:.3f}s", font=FONT, fill=(40, 45, 50))
    sheet.save(QA / "multi-eye-contact.png")
    report["ok"] = not report["errors"]
    (QA / "validation.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    if not report["ok"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
