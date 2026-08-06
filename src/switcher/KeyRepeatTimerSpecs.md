# KeyRepeatTimer — Specs

## Summary

`KeyRepeatTimerTestable.shouldApplyArtificialRepeat` is the pure decision kernel for the artificial
key-repeat (hold-to-cycle for modifier-only shortcuts). `KeyRepeatTimer` owns the `DispatchSource`
timer; on each tick it asks this kernel whether the tick should actually advance the selection.

The artificial repeat exists because a modifier-only shortcut (e.g. ⌥⇥ where ⇥ has no keycode of its
own once ⌥ is the hold) gets no OS key-repeat, so AltTab synthesizes one. The timer is armed at
show-invoke time with the user's `InitialKeyRepeat` delay + `KeyRepeat` rate.

## The problem it guards (why gate on visibility)

When the user summons the switcher right after a fullscreen/Space transition, the WindowServer is busy
settling the transition and can't paint AltTab's `.canJoinAllSpaces` panel until it finishes — the
panel's pixels can land ~500ms after the timer was armed. The timer's background `DispatchSource`
keeps ticking through that gap; the queued ticks then all fire the instant the panel appears and jump
the selection several tiles, with no input from the user (they'd pressed once and were waiting for the
switcher to show).

So the initial-delay grace must be measured from when the panel was actually **visible**, not from arm
time. A fast, normal summon is unaffected (visible within ~tens of ms of arming).

## The anchor that went missing (live QA, 2026-07-30)

Anchoring only on `SwitcherSession.panelBecameVisibleAt` — our own panel's WindowServer `orderedIn` —
made the fallback the NORMAL path, because that notification never arrives. Order-in is only delivered
for wids in the per-window opt-in set (`WindowServerEvents.wsWindows`, mandatory since Sequoia), and the
panel is not in it. So every tick fell through and hold-to-cycle started at
`armedAt + initialDelay + 1s`: measured **1377ms** against a system `InitialKeyRepeat` of **417ms**, on
every hold, felt by every user. (Carbon hotkeys fire once per press and ignore auto-repeat keyDowns —
verified in the log: 14 auto-repeat keyDowns produced exactly one `state:down` — so the artificial repeat
is the only thing that can advance the selection while the key is held.)

The panel was NOT added to the opt-in set to fix this: that would feed our own panel's order/geometry
events into the reducer as inputs for an untracked wid, which is a real risk for a timing nicety.
Instead `TilesPanel.show()` sets `SwitcherSession.panelShownAt` as it orders the panel front — an anchor
that cannot go missing. It is slightly EARLY (the WindowServer paints after the order-front returns), so
the visible signal stays above it as the correction rather than replacing it, and the tradeoff is stated
plainly: on a genuinely slow show the grace now starts at the order-front instead of at the paint, which
can let ONE advance land early. That is the price of not being a second late on every ordinary summon.

## The rule (tested)

Inputs are `systemUptime` timestamps. The anchor is `panelBecameVisibleAt ?? panelShownAt`:

1. **an anchor is known** → apply iff `now - anchor >= initialDelay`. The WindowServer's visible
   timestamp wins when present, being the true pixels-on-screen moment; the show timestamp is the
   guaranteed stand-in.
2. **neither known** → hold off, but fall back to arm-relative timing after
   `initialDelay + missedVisibleSignalBudget` (1s), so a missing anchor can never wedge hold-to-cycle
   permanently. A genuine safety net now, rather than the path every tick took.

---

## Test scenarios

Mirrors `KeyRepeatTimerTests.swift` 1:1.

### A2. The show-time anchor
- **testAppliesFromTheShowAnchorWhenNoWindowServerSignalArrives** — the 1.4s bug: with no WindowServer
  signal the grace runs from `panelShownAt`, not from arm + 1s.
- **testTheWindowServerSignalOverridesTheShowAnchor** — when both are known the visible signal wins, so a
  slow show still can't start the grace early.

### A. Visible timestamp known — gate from visibility
- **testAppliesOnceVisibleForInitialDelay** — visible 0.5s ago, initialDelay 0.4s → applies.
- **testSkipsWhenNotVisibleLongEnough** — visible 0.1s ago, initialDelay 0.4s → skips (the core fix: a
  slow show presented the panel, but the grace hasn't elapsed since it became visible).
- **testAppliesExactlyAtInitialDelayBoundary** — visible exactly initialDelay ago → applies (`>=`).

### B. Visible timestamp unknown — arm-relative fallback
- **testSkipsBeforeFallbackBudgetWhenNeverVisible** — never visible, armed 0.5s ago, initialDelay 0.4s
  → skips (the queued-burst case: repeats due at ~arm+initialDelay are suppressed while the panel still
  isn't up). Fallback only opens at `initialDelay + 1s`.
- **testAppliesAfterFallbackBudgetWhenNeverVisible** — never visible, armed 1.5s ago, initialDelay 0.4s
  → applies (`>= 0.4 + 1`), so a missed visible signal doesn't wedge hold-to-cycle.
