# WindowEventReducer — phantom-pass effects — Specs

## Summary

Covers the effects `WindowEventReducer.cgsWindowListsRead` emits when the CGS phantom pass flips a
window's DERIVED phantom. Specs + Tests without a same-named kernel (like `RealWorldScenarios`): the
subject is the reducer's effect emission, not a pure function of its own.

Driven through `WindowEventReducer.reduce` directly rather than the replay harness, because
`.removeWindowlessPlaceholder` is a display-side effect that `TestReducerRunner` deliberately swallows
(it has no model content) — so a scenario replay cannot observe it.

## Why this exists (#5849)

An app whose only window looks phantom is indistinguishable from an app with no windows, so a windowless
placeholder tile is added for it. When the window later un-phantoms, that placeholder is stale and must be
dropped. Four sites did this, all of them Space paths (`applySpaceMembershipDelta`, `applyWindowSpaces`).

The CGS-list pass, which owns the authoritative verdict and is the path that actually clears an Electron
app's latch, did not. So Slack ended up with a real tile AND a windowless tile, permanently: "it appears
twice in the list and won't change even if I wait or switch windows".

The same capture showed the second half of the bug. Slack, reopened from the Dock, keeps its window tagged
invisible by CGS for seconds after it is on screen and focused, so the weak signal flagged the FOREGROUND
window a phantom. Hidden but still holding MRU slot 0, it made the switcher's "previously-focused window"
default count one visible window too far and focus the wrong app. A window the user is looking at is never
a phantom, so `PhantomWindowDetector.cgsVerdict` now takes `isFocused` (front of the MRU AND app frontmost)
and exempts it from the weak signal only — after the strong signal, so #5714 stands.

---

## Test scenarios

Mirrors `WindowEventReducerPhantomTests.swift` 1:1.

### A. Un-phantoming drops the app's stale windowless placeholder
- **testUnphantomingEmitsRemoveWindowlessPlaceholder** — a latched-phantom window seen in both CGS lists
  clears its verdict and emits `.removeWindowlessPlaceholder`. The regression guard for the duplicate tile.
- **testBecomingPhantomDoesNotEmitRemoveWindowlessPlaceholder** — the reverse flip (real → phantom) emits
  nothing: the app is becoming windowless, which is exactly when the placeholder is legitimate.
- **testNoFlipEmitsNothing** — a steady-state pass emits nothing, so repeated CGS reads don't churn the list.

### B. The focused window is exempt from the weak signal
- **testFocusedWindowSurvivesTheWeakSignal** — tagged invisible by CGS, but front of the MRU with its app
  frontmost → not a phantom.
- **testUnfocusedWindowStillFlaggedByTheWeakSignal** — same window and tagging, app not frontmost → still a
  phantom.
- **testNonFrontWindowOfActiveAppStillFlagged** — app frontmost but the window sits at MRU slot 3, so it is
  not the one the user is looking at → still a phantom.

### C. Focus clears a stale verdict immediately

The exemption in B is only consulted when the CGS pass runs, and that pass runs on a show, landing a beat
AFTER the switcher appears. So it does not cover the fast path the reporter actually hit: open Slack, tap
the shortcut straight away, and the switcher is built while the stale verdict still hides the window that
was just focused. Focusing a window is proof it is real, so the verdict is now cleared at that moment
instead of waiting for a pass (`TrackedWindowState.clearPhantomOnFocus`).

- **testFocusClearsAStalePhantomLatch** — a latched-phantom window that receives focus is real immediately.
- **testFocusUnphantomingEmitsRemoveWindowlessPlaceholder** — that un-phantoming also drops the app's stale
  placeholder, so the fast path doesn't trade the wrong-window bug for the duplicate-tile one.
- **testFocusingARealWindowEmitsNoPlaceholderRemoval** — focusing an already-real window emits nothing, so
  ordinary switching doesn't churn.

### D. Focus that arrives as an AX READ clears it too

C only covers focus that arrives as an 808. Two focus signals arrive as an AX `kAXFocusedWindow` READ
instead — the activation backstop (an activation that emits no 808) and the creation seed (a window
discovered while its app was already frontmost) — and both used to bump the MRU by calling
`Windows.updateLastFocusOrder` straight from the shell, bypassing the reducer's focus path and therefore the
clear in C. Reopening Slack from the Dock reaches the front through the activation, so the second #5849
report hit exactly that hole: the switcher summoned right after showed the app as a closed-app icon while
its hidden real window held slot 0, and the default pick landed on a third app. Both reads are now the
`.axFocusedWindowRead` input and share the one focus path; the gates they always had move with them.

- **testActivationBackstopClearsAStalePhantomLatch** — the backstop read fronts the window and clears its
  latch, dropping the placeholder its app grew.
- **testActivationBackstopYieldsToTheActivations808** — once the activation's own 808 has bumped, the read is
  the stale weak signal (#5596) and decides nothing.
- **testActivationBackstopIgnoresANoLongerFrontmostApp** — a read landing after the user moved on doesn't
  front that app's window.
- **testCreationSeedClearsAStalePhantomLatch** — the creation seed clears the latch the same way.
- **testCreationSeedIgnoresABackgroundApp** — `kAXFocusedWindow` answers "which window WOULD take keys",
  which every app has at all times, so a background app's read fronts nothing (#5785).

### E. An app whose last window turns phantom gets its placeholder in the SAME pass

The other half of the placeholder's lifecycle had no owner. Adding it was left to the shell's per-app sweep,
which runs in the same block as the CGS fetch but BEFORE the verdicts are applied, so it judged "does this
app still have a real window?" against the previous latch. Closing Slack's window therefore gave three
different switchers in three consecutive summons: the corpse re-discovered as an open window, then nothing
at all for that app, then finally the closed-app icon.

- **testLastWindowTurningPhantomEmitsAddWindowlessPlaceholder** — the app is now windowless, so the verdict
  that made it so emits `.addWindowlessPlaceholder`.
- **testPhantomWithAnotherRealWindowLeftEmitsNoAdd** — one window of several turning phantom leaves the app
  something to show, so no placeholder (the duplicate tile, in the other direction).
- **testUnphantomingEmitsNoAdd** — the opposite edge never adds one.
