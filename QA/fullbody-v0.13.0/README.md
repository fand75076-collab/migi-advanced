# Migi Advanced v0.13.0 multi-Agent transition QA

This QA set validates the production Metal renderer and the new behavior clocks;
it does not rebuild or alter the accepted 8 x 21 atlas.

## Transition language

- `join`: after a 0.20 s stable work pose, one live Agent becomes two. Migi
  plays the complete 2.94 s `signal-sampling` presentation: palm eye, delayed
  eye-stalk expansion, peak multi-focus hold, then branch-by-branch retraction.
- `handoff`: the live set remains Codex + Grok while the activity winner changes.
  Migi preserves its old facing for the complete 1.40 s `look-around`, then
  commits one independent 1.01 s authored `turn-left` or `turn-right` before
  resuming the latest work pose.
- `leave`: two live Agents become one. Migi plays one complete 1.48 s
  `logic-count` reconciliation after any already-committed turn finishes.

Waiting, failure, and an explicit monitoring-mode reset may interrupt these
presentations. Read/write and novel-tool gestures complete before a pending
join or handoff. ZCode is excluded because its records arrive only after a
response is complete and do not prove concurrent live work.

## Captures

All six images in `metal/` are direct 230 x 270 GPU readbacks from the signed
release app using `--qa-agent-transition=join|handoff|leave`. The capture points
are 0.75, 1.65, and 2.85 s for join; 0.90 and 2.05 s for handoff; and 0.90 s for
leave. `multi-agent-transition-contact.png` is the visual review sheet.
`installed-handoff-turn.png` is a second direct readback from the canonical
`~/Applications/Migi Advanced.app` after installation, confirming that the
installed build presents the same independent turn rather than a stale dist app.

Visual review confirms:

- join grows one connected right-hand organism; it does not clone a full Migi;
- the maximum-focus pose has five independently tracked eyes and retracts to
  fewer branches instead of deleting all appendages at once;
- handoff uses one body and one eye set in both acquisition and planted turn;
- leave is a calm one-finger count with no blade, red muscle, alarm icon,
  particles, glow, Agent logo, or brand color;
- every readback is non-empty, remains inside the 230 x 270 surface, and shows
  no second-body ghost or detached duplicate eye set.

The source and packaged atlas hashes remain identical:

```text
migi-v4-atlas.json  3a68d95628c8f54e75f15211419e8e55050177d0df851cde6871bf354e78a4c0
migi-v4-atlas.png   630080752431281387159863d532c649d13a3cee430fd61660805bf30bda3f8e
```

## State-machine coverage

Behavior tests cover complete clip boundaries, duplicate snapshots, rapid
source reversal, reversal on the expiry frame, monitoring-generation reset,
Codex-to-Grok sequential handoff, ZCode exclusion, tool deferral, waiting and
failure preemption, simultaneous 2-to-0 completion, committed-turn preservation,
and leave reconciliation after the committed turn.
