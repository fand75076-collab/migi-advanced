# Migi v0.15.0 motion quality

The baseline is commit `1a9be54` (v0.14.3). Only the debug capture hook was
added before collecting the baseline; its production animation was unchanged.
Both variants run the same behavior frames, pointer targets, energy changes,
clock origin (100,000 seconds), 30 Hz sample times and 230 × 270 render target.
The debug hook uses the production Metal meshes, pipelines and GPU readback;
it does not show a desktop panel or sample live conversation logs.

## Changes

- Integrate authored playback time with exact exponential rate easing. A new
  rate changes future movement, and semantic lead-ins remain outside clip time.
  The independent authored turn clock and fixed-duration gesture holds remain.
- Integrate breathing phase independently of system uptime, plant the lower
  body baseline, and remove whole-image bob from rigid prop poses.
- Close opaque upper/lower eyelids over the complete eyeball. Each delayed eye
  samples its own close/hold/open envelope, including short blinks.
- Use analytic critically damped gaze motion. Keep 60 Hz during blinks, branch
  eye pursuit and handoffs; delay downshifts by 0.55 seconds.
- Match the single procedural eye set's visibility to its tissue during a
  semantic handoff, retaining socket size and preventing an opaque early eye.

## Evidence

`validation.json` checks 1,440 GPU frames: 180 per scenario and variant.
All frames are non-empty, 230 × 270, and inside the render surface.
An additional 180-frame laptop sequence checks two eyes throughout and 60 Hz
requests across their staggered close/reopen window (1,620 checked frames total).
`multi-eye-contact.png` confirms that the leading eye reopens while the branch
eye finishes its own delayed closure, without jumping to the leading eye's phase.

In `work-rate`, changing from 1.4× to 0.75× at 4 seconds makes the baseline
jump from authored frame 3 to frame 5. The new clock has zero skipped frame
events across the same sequence. Unit tests also cover long-running phase
continuity, fixed-rate timing, handoff lead-in, late draws, 15/60 Hz equivalence,
refresh-rate hysteresis and delayed eyelid release.

Visual review of `blink-contact.png` shows geometric occlusion of the pupil
instead of a translucent flesh overlay; full closure covers the white eye.
`handoff-contact.png` samples both sides of the transition midpoint and shows
the incoming eye appearing with its supporting tissue.

The controlled exports are sampled at 30 Hz; they establish rendered output
and frame selection, not real-time display performance or GPU latency.
The atlas PNG, manifest and BC7 KTX are unchanged; hashes are in the report.
This release improves continuous rendering. It does not add authored in-between
art to the existing 4–8-frame actions.

The standard suite passes 164 tests, with the opt-in GPU exporter skipped.
That exporter separately passes the four comparison scenarios and dual-eye
scenario. The signed v0.15.0 (build 23) bundle is installed at
`~/Applications/Migi Advanced.app`; its executable and BC7 atlas match dist.
The canonical process was relaunched and independently verified as a single
instance with its 115 × 135 floating panel on screen. `installed-live.png`
is a fresh Cua Driver capture of that panel at Retina scale.

## Reproduce

```sh
swift test
MIGI_MOTION_QA_DIR="$PWD/QA/motion-quality-v0.15.0/after" \
  swift test --filter MigiMotionVisualQATests
```

`MigiMotionVisualQATests` skips routine GPU export unless that environment
variable is supplied. To rebuild comparisons, keep the original `before/`
readbacks and use the bundled Python with Pillow:

```sh
"$PYTHON" scripts/build-motion-quality-qa.py
```

The script requires `ffmpeg` and produces four synchronized videos, two
comparison contact sheets, a dual-eye contact sheet and `validation.json`. Generated frame sequences and media
remain local and are ignored by Git.
