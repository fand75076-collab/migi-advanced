# Migi Advanced v0.11.1 flicker repair QA

## Root cause

The v0.11 renderer created an 85 ms outgoing/incoming handoff for every
authored animation cell. Both complete sprites and both pointer-eye sets were
drawn with source-over blending. Even complementary 0.5/0.5 visibility yields
only 0.75 composite alpha, and differing silhouettes produced darker multi-eye
and multi-limb frames. The pre-fix live probe captured no blank Metal frames,
but 15 of 120 frames contained this ghosting; the lowest measured visible
signal was about 49% of the normal peak.

## Repair

- Same-presentation authored cells now advance directly.
- Real semantic, sleep, wake, and turn handoffs use additive premultiplied
  tissue compositing, whose complementary layers preserve opacity.
- A handoff draws exactly one pointer-eye set, selected from the dominant pose.
- Anchored work and transformation poses keep the NSPanel origin fixed; their
  breathing remains inside the Metal mesh.
- Pointer enter/exit no longer forces an immediate 30/60 Hz rate toggle.
- The drawable is acquired only after an in-flight GPU buffer slot is reserved.
- Tap look-around includes the 0.36 second semantic lead-in and now exposes the
  complete 1.04 second authored clip. QA taps are queued until demo setup is
  complete.

## Verification

- `swift test`: 101 tests, 0 failures.
- Release bundle: v0.11.1 build 16, ad-hoc signature verified.
- Source, built, and installed v4 atlas hashes are unchanged.
- `deterministic-fine-motor-final/` contains eight installed-renderer Metal
  captures across the rapid authored sequence. Every frame contains one body
  and one eye set. Mean alpha ranges from 47.659 to 49.552 on the full capture
  canvas, a 3.91% silhouette-driven spread with no transition collapse.
- The old and new evidence can be compared with
  `../flicker-v0.11.0-before/contact.png` and
  `deterministic-fine-motor-final/contact.png`.

The macOS session became locked during the post-install desktop probe.
`probe/README.md` records `CGSSessionScreenIsLocked=1`; desktop and window
capture were therefore blocked by macOS privacy rather than by Migi. The
authoritative post-fix visual evidence is the app's own final Metal texture
capture above.
