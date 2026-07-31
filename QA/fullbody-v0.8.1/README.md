# Migi Advanced v0.8.1 QA

Date: 2026-07-30  
Application version: 0.8.1 (build 11)

## Scope

This patch replaces only the four `sharpen-tip` frames. The animation now reads:

1. intact beige finger-tendril;
2. skin opens and exposes attached crimson muscle bundles;
3. broad red/burgundy muscle sheath tensions around a rigid silver-gray blade;
4. blade retracts and the residual red seam closes under the beige skin.

The transformation is anatomical but not gory: no blood droplets, open wound,
detached weapon or floating effect.

## Deterministic validation

- Atlas: 3584 × 4032 RGBA, 448 × 448 cells.
- Clip location: row 4, columns 4–7.
- Frame timing: 0.22 seconds per frame.
- Changed cells versus v0.8.0: exactly `(4,4)`, `(4,5)`, `(4,6)`, `(4,7)`.
- Every other clip's decoded pixels and manifest metadata are preserved.
- Approximate 115 × 135 red-pixel counts: 10, 52, 173, 31; the red muscle remains
  readable in the exposure, full-blade and retraction poses.
- Atlas SHA-256:
  `284a0755716e6b9cdb1644e61c560cd8f735746288b712765d4d0b2c93f6c56f`
- Manifest SHA-256:
  `5cb9ec596e84a6685e98c66393408e57d3992ef9f8fb9d80a8b9efe81af404a5`
- `swift test`: 64/64 passed, 0 failures.

Machine-readable evidence is in `blade-validation.json`.

## Visual QA

- `blade-atlas-contact.png`: full-resolution four-frame clip.
- `blade-actual-size-contact.png`: approximate 115 × 135 desktop presentation.
- `blade-sequence.gif`: exact four-frame order with a longer hold on the complete blade.
- Independent visual QA: PASS, with stable identity and baseline, attached blade,
  readable muscle at desktop size, and no clipping, extra anatomy or background
  contamination.
- `blade-metal-0.png` through `blade-metal-3.png`: four frames sampled from the
  installed Metal renderer at 230 × 270 Retina pixels.
- `blade-metal-contact.png`: installed 115 × 135 pt sequence shown together.
- Independent installed-Metal QA: PASS. Mirroring keeps the hand, muscle sheath and
  blade together on the same side; the red bundles and retraction seam remain visible
  without clipping, ghosting or eye deformation.

## Installed delivery

- Version: 0.8.1, build 11.
- Signature: valid.
- Installed atlas and manifest are byte-identical to the validated source resources.
- Desktop entry resolves to `/Users/fdk/Applications/Migi Advanced.app`.
- Reopening returns the same PID; a forced second normal instance exits.
- Final observed runtime state: one process and one 115 × 135 window.
