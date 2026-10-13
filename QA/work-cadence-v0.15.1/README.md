# Migi work-cadence polish (proposed v0.15.1)

## Scope

This change addresses monotonous long-running work loops **without** modifying
the 8 × 21 atlas, 29 authored clips, body topology, semantic transition
priorities, eye animations, or resource format.

- `rapid-notes`, `fine-motor`, `laptop`, and `book` receive two smooth,
  low-frequency rate variations plus a brief, bounded hesitation roughly every
  13–16 seconds.
- Variation is layered over real Agent throughput. It feeds
  `MigiClipPlaybackClock`, so rate updates change **future** playback rather
  than reselecting already-shown frames.
- Deterministic `--qa-*`, `--demo`, `--demo-state=*` captures and the
  menu-triggered demo remain unmodified.
- Turns, idle, sleep, waiting, blade, failure, multi-Agent choreography,
  and protected props do not receive cadence modulation.

## Implemented code checks

`MigiMotionDynamicsTests` has three additional cases:

1. Only live work clips change cadence; QA and non-work clips are untouched.
2. The clock advances monotonically across one minute of modulated frames,
   with bounded rates.
3. The hesitation curve has no hard discontinuity when the cycle wraps.

The rate helper is deterministic for identical inputs. It does not allocate
per-frame collections, read logs, or add texture memory.

## Required macOS validation before merging

This repository's app requires macOS 13+, AppKit, and Metal. Run on the target
Mac (the code change has **not** yet been verified by a fresh macOS build):

```sh
swift test
scripts/build-app.sh
```

Then compare 30–60 seconds of *real live sessions*, not just `--demo`:

- Long `rapid-notes` and `fine-motor` tasks: no frame rewinds, 1-frame
  jitter, pose popping, abrupt freezes, or overactive 'dancing'.
- `laptop` and `book`: subtle organic pacing, not a new gesture or a global
  bob of the desk/props.
- Enter/leave work, switch Agents, run a test command, receive failures:
  existing full transition clips still take precedence.
- Check both the default 115 × 135 pt size and the 230 × 270 pt QA size.
- Compare per-process CPU/GPU and resident memory with v0.15.0 under similar
  tasks. Verify all `--qa-agent-transition=*` modes remain unchanged.

Do not call visual smoothness 'verified' until a real post-change Metal capture
and playback review have been saved. Captures are ignored by `.gitignore`.

## Deferred work

Transition mesh correspondence, optional additional intermediate authored
frames for turns, per-appendage inertia and 115 × 135 pt silhouette cleanup
need direct frame-by-frame review of running output. Do not tune these by
guessing from the static manifest; they are separate P0/P1 visual passes.
