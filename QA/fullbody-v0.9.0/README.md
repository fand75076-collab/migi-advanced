# Migi Advanced v0.9.0 QA

This directory validates the v0.9 full-character atlas and the actual Metal
overlay at its default 115 × 135 point size.

## Results

- `motion-validation.json`: pass
- `metal-validation.json`: pass
- Swift tests: 75/75 pass
- Atlas: 8 columns × 13 rows, 448 × 448 pixels per cell
- Runtime package: 0.9.0, build 13

High-frequency median-height ratios relative to idle:

| Clip | Ratio |
| --- | ---: |
| patrol right | 0.9195 |
| patrol left | 0.8851 |
| laptop | 0.9655 |
| phone | 0.9943 |
| book | 1.0000 |
| rapid notes | 0.9828 |
| fine motor | 1.0977 |

All ratios are within the accepted 0.82–1.18 range. No required gaze anchor or
direction metadata check failed.

## Artifacts

- `all-clips-actual-size.png`: every atlas frame at 115 × 135 logical size.
- `previews/*.gif`: authored per-frame timelines.
- `metal-contact.png`: real Metal frames for left/right idle, patrol, turn,
  laptop, phone, book, rapid notes, fine motor, and the red-muscle blade peak.
- `metal/`: individual transparent Retina captures.
- `motion-validation.json`: scale, baseline, motion, gaze, timeline, and
  direction checks.
- `metal-validation.json`: output size, clipping, visible bounds, and mirrored
  prop-pair checks.

The rapid-notes row was explicitly normalized after review: its final Metal
visible bounds are 144 × 144 Retina pixels instead of the rejected 204 × 204,
removing the review-state zoom jump.
