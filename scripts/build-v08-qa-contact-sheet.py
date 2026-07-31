#!/usr/bin/env python3
"""Build deterministic v0.8 wake-sequence QA presentation artifacts."""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


PROJECT_ROOT = Path(__file__).resolve().parents[1]
QA_ROOT = PROJECT_ROOT / "QA" / "fullbody-v0.8.0"
PHASES = [
    ("wake-deep.png", "Deep sleep"),
    ("wake-dream-early.png", "Dream 0.10 s"),
    ("wake-dream-mid.png", "Dream 0.55 s"),
    ("wake-dream-late.png", "Dream 1.05 s"),
    ("wake-look-early.png", "Look 0.10 s"),
    ("wake-look-late.png", "Look 1.45 s"),
    ("wake-handoff-early.png", "Handoff 0.08 s"),
    ("wake-handoff-mid.png", "Handoff 0.21 s"),
    ("wake-handoff-late.png", "Handoff 0.35 s"),
    ("wake-awake.png", "Awake"),
]
GAZE = [
    ("wake-look-gaze-left.png", "Look / gaze left"),
    ("wake-look-gaze-right.png", "Look / gaze right"),
]


def load_font(size: int) -> ImageFont.ImageFont:
    candidates = [
        Path("/System/Library/Fonts/SFNS.ttf"),
        Path("/System/Library/Fonts/Helvetica.ttc"),
    ]
    for candidate in candidates:
        if candidate.exists():
            return ImageFont.truetype(str(candidate), size=size)
    return ImageFont.load_default()


def checkerboard(size: tuple[int, int], cell: int = 12) -> Image.Image:
    background = Image.new("RGBA", size, (244, 244, 244, 255))
    draw = ImageDraw.Draw(background)
    for y in range(0, size[1], cell):
        for x in range(0, size[0], cell):
            if (x // cell + y // cell) % 2:
                draw.rectangle(
                    (x, y, min(x + cell - 1, size[0]), min(y + cell - 1, size[1])),
                    fill=(226, 226, 226, 255),
                )
    return background


def build_contact_sheet() -> None:
    image_size = (230, 270)
    label_height = 34
    margin = 18
    columns = 5
    rows = 2
    title_height = 54
    cell_width = image_size[0] + margin * 2
    cell_height = image_size[1] + label_height + margin
    sheet = Image.new(
        "RGBA",
        (columns * cell_width, title_height + rows * cell_height),
        (250, 250, 250, 255),
    )
    draw = ImageDraw.Draw(sheet)
    title_font = load_font(22)
    label_font = load_font(17)
    draw.text(
        (margin, 14),
        "Migi Advanced v0.8 — Metal wake sequence (115 × 135 pt, captured @2x)",
        fill=(28, 28, 28, 255),
        font=title_font,
    )

    for index, (filename, label) in enumerate(PHASES):
        image = Image.open(QA_ROOT / filename).convert("RGBA")
        if image.size != image_size:
            raise ValueError(f"{filename}: expected {image_size}, got {image.size}")
        column = index % columns
        row = index // columns
        x = column * cell_width + margin
        y = title_height + row * cell_height
        tile = checkerboard(image_size)
        tile.alpha_composite(image)
        sheet.alpha_composite(tile, (x, y))
        text_box = draw.textbbox((0, 0), label, font=label_font)
        text_width = text_box[2] - text_box[0]
        draw.text(
            (x + (image_size[0] - text_width) / 2, y + image_size[1] + 8),
            label,
            fill=(34, 34, 34, 255),
            font=label_font,
        )

    sheet.convert("RGB").save(QA_ROOT / "wake-contact-sheet.png", optimize=True)


def build_gaze_sheet() -> None:
    image_size = (230, 270)
    margin = 20
    label_height = 36
    sheet = Image.new(
        "RGBA",
        (image_size[0] * 2 + margin * 3, image_size[1] + label_height + margin * 2),
        (250, 250, 250, 255),
    )
    draw = ImageDraw.Draw(sheet)
    label_font = load_font(17)
    for index, (filename, label) in enumerate(GAZE):
        image = Image.open(QA_ROOT / filename).convert("RGBA")
        x = margin + index * (image_size[0] + margin)
        y = margin
        tile = checkerboard(image_size)
        tile.alpha_composite(image)
        sheet.alpha_composite(tile, (x, y))
        text_box = draw.textbbox((0, 0), label, font=label_font)
        text_width = text_box[2] - text_box[0]
        draw.text(
            (x + (image_size[0] - text_width) / 2, y + image_size[1] + 8),
            label,
            fill=(34, 34, 34, 255),
            font=label_font,
        )
    sheet.convert("RGB").save(QA_ROOT / "wake-gaze-comparison.png", optimize=True)


def build_actual_size_sheet() -> None:
    point_size = (115, 135)
    label_height = 26
    margin = 12
    columns = 5
    rows = 2
    title_height = 42
    cell_width = point_size[0] + margin * 2
    cell_height = point_size[1] + label_height + margin
    sheet = Image.new(
        "RGBA",
        (columns * cell_width, title_height + rows * cell_height),
        (250, 250, 250, 255),
    )
    draw = ImageDraw.Draw(sheet)
    title_font = load_font(18)
    label_font = load_font(13)
    draw.text(
        (margin, 11),
        "Actual-size QA — each Migi tile is 115 × 135 px",
        fill=(28, 28, 28, 255),
        font=title_font,
    )
    for index, (filename, label) in enumerate(PHASES):
        image = Image.open(QA_ROOT / filename).convert("RGBA")
        image = image.resize(point_size, Image.Resampling.LANCZOS)
        column = index % columns
        row = index // columns
        x = column * cell_width + margin
        y = title_height + row * cell_height
        tile = checkerboard(point_size, cell=8)
        tile.alpha_composite(image)
        sheet.alpha_composite(tile, (x, y))
        text_box = draw.textbbox((0, 0), label, font=label_font)
        text_width = text_box[2] - text_box[0]
        draw.text(
            (x + (point_size[0] - text_width) / 2, y + point_size[1] + 6),
            label,
            fill=(34, 34, 34, 255),
            font=label_font,
        )
    sheet.convert("RGB").save(
        QA_ROOT / "wake-actual-size-contact.png",
        optimize=True,
    )


def build_animation() -> None:
    # This is a compact keyframe preview; the app renders the real transition
    # continuously at 30 fps, with the 0.42 s handoff raised to 60 fps.
    durations = [750, 350, 350, 350, 450, 450, 140, 140, 140, 900]
    frames = []
    for filename, _ in PHASES:
        source = Image.open(QA_ROOT / filename).convert("RGBA")
        background = Image.new("RGBA", source.size, (255, 255, 255, 255))
        background.alpha_composite(source)
        frames.append(background.convert("RGB"))
    frames[0].save(
        QA_ROOT / "wake-sequence.gif",
        save_all=True,
        append_images=frames[1:],
        duration=durations,
        loop=0,
        disposal=2,
        optimize=False,
    )


if __name__ == "__main__":
    build_contact_sheet()
    build_gaze_sheet()
    build_actual_size_sheet()
    build_animation()
