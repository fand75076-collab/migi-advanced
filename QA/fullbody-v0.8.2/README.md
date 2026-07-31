# Migi Advanced v0.8.2 QA

Date: 2026-07-30  
Application version: 0.8.2 (build 12)

## Scope

This patch replaces only the four `sharpen-tip` frames. It follows the original
manga's continuous tissue-transformation logic and the 2014 animation setting
sheet's dusty red-brown muscle and pale silver blade treatment:

1. an intact four-finger hand;
2. the fingers fuse, beige skin retracts and three muscle branches fan outward;
3. three differently directed blades harden from those attached branches into
   one asymmetric multi-blade organ;
4. the blades and muscle retract while skin and finger buds return.

The peak is not a single attached knife, parallel twin needles, scissors or a
surface red stripe. The red tissue has volume and remains structurally attached,
without blood droplets, an open wound or a detached weapon.

The generated source, transparent strip, prompt, reference copies, source URLs,
processing method and SHA-256 hashes are frozen under
`work/migi-blade-canon-v082-20260730/`.

## Deterministic validation

- Atlas: 3584 × 4032 RGBA, 448 × 448 cells.
- Clip location: row 4, columns 4–7.
- Frame timing: 0.22 seconds per frame.
- Changed cells versus frozen v0.8.1: exactly `(4,4)`, `(4,5)`, `(4,6)`,
  `(4,7)`.
- Every other clip's decoded pixels and manifest metadata are preserved.
- Every replacement frame contains exactly two regenerated pointer-eye anchors.
- Approximate 115 × 135 muscle-red pixel counts for the transformation frames:
  242, 325 and 96; the intact-hand frame has five threshold false positives.
- Red muscle remains readable in exposure, multi-blade peak and retraction.
- Atlas SHA-256:
  `a5bb8ead899b3db83936b293a740add523f9009c41ed86aa22f52ef4df1145f7`
- Manifest SHA-256:
  `f9fd5797159a72c16a75e19f1389bfd35c5afb9a049eef941ffaec473d767958`
- Transparent source SHA-256:
  `d305904d521e620f49dcce1d5ba79f2b67798042b09e68d80b6c7c85fb203607`
- `swift test`: 64/64 passed, 0 failures.

Machine-readable evidence is in `blade-validation.json`.

## Visual QA

- `blade-atlas-contact.png`: full-resolution four-frame clip.
- `blade-actual-size-contact.png`: approximate 115 × 135 desktop presentation.
- `blade-sequence.gif`: exact four-frame order with a longer peak hold for review.
- Independent atlas/GIF QA: PASS. The hand-to-muscle-to-blade relationship,
  three attached branches, stable identity and reverse retraction remain legible
  at desktop size; no clipping, detached anatomy, extra eye or size jump was found.
- `blade-metal-0.png` through `blade-metal-3.png`: frames sampled from the
  installed Metal renderer at 230 × 270 Retina pixels.
- `blade-metal-contact.png`: installed 115 × 135 pt sequence shown together.
- Independent Metal QA: PASS. The core body and baseline remain stable; expansion
  comes only from the blades, and there is no clipping, ghosting, color fringe,
  floating component or renderer artifact.

## Installed delivery

- Version: 0.8.2, build 12.
- Signature: valid.
- Installed atlas and manifest are byte-identical to the validated source resources.
- Desktop entry resolves to `/Users/fdk/Applications/Migi Advanced.app`.
- Reopening the desktop entry returns the same PID; one normal process remains.
- The complete v0.8.1 atlas and manifest are frozen under
  `backups/atlas-v0.8.1/`.
