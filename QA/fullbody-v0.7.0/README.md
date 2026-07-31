# Migi Advanced v0.7.0 QA

Date: 2026-07-30

## Scope

- New idle clips: `rapid-notes`, `fine-motor`, `organ-drift`, `logic-count`
- Clip-start epoch reset so every action begins at frame 0
- Per-action cooldowns, no consecutive action family, natural patrol stop before playback, and 0.6–1.0 second settle
- 8 × 9 high-density atlas with per-clip column offsets
- Isolated, auto-exiting LaunchServices QA capture path

## Deterministic validation

- Atlas: 3584 × 4032 RGBA, 448 × 448 cells
- Used slots: 64
- Transparent unused slots: 8
- Decoded texture bytes: 57,802,752
- Atlas SHA-256: `a0c9ba5282a898fae4aa0574da310355aab102e345d2b321be9bcebb293474d3`
- Manifest SHA-256: `53cc32518f73ca1891c569416ccf21dee5887a92642967a4a8c08ac39127a779`
- `swift test`: 42 tests, 0 failures

## Independent visual QA

- `rapid-notes`: PASS — book, notebook, pencil-hand, and study-to-note loop remain readable at 115 × 135.
- `fine-motor`: PASS — connected finger differentiation is asynchronous, readable, and non-grotesque.
- `organ-drift`: PASS — eye-stalk and mouth shifts preserve the body silhouette and return cleanly.
- `logic-count`: PASS — one-two-three-reset gesture is distinct and loopable.
- Packed layout: PASS — no cross-cell overlap, clipping, chroma fringe, detached debris, or dirty unused cell.

## Installed Metal QA

Each `*-metal.png` is a 230 × 270 Retina capture of the actual 115 × 135 Metal view:

- `rapid-notes-metal.png`
- `fine-motor-metal.png`
- `organ-drift-metal.png`
- `logic-count-metal.png`
- `fine-motor-gaze-left.png`
- `fine-motor-gaze-right.png`

Left/right gaze captures differ in the procedural pupils while the body remains fixed.

Installed application:

- Version: 0.7.0
- Build: 9
- Signature: valid
- Desktop entry resolves to `/Users/fdk/Applications/Migi Advanced.app`
- Reopening returned the same PID and CGWindow ID
- Final observed runtime state: one process, one 115 × 135 window
