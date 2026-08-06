# SelectionResolver — Specs

> **Line coverage:** `SelectionResolver.swift` 93% · _refreshed 2026-05-27 by `/coverage-explore`_

## Summary

`SelectionResolver` decides **which tile is highlighted** while the switcher is open. Every time the
window list changes (a window opens/closes, an app steals focus, a search query filters the list), the
switcher calls `SelectionResolver.decide(_:)` with a snapshot of the current state and gets back a
`SelectionDecision` enum; the wrapper (`Windows`) turns that into highlight redraws, scroll-to-visible,
target bookkeeping, and the preview. Pure data in, `Equatable` decision out — no globals, no AppKit.

### The core idea: a stable "target"

Once the user moves the highlight, the selected window's id is remembered as the **target**. On every
refresh the resolver tries to keep the highlight on that same window even as the list reorders — this is
the #5665 fix (before it, a background app finishing launch could yank the highlight away mid-pick).

## Behavior & edge cases (decision priority order)

1. **Search-clear** (`restoreDefaultOnSearchClear`) takes precedence — re-runs the initial pick even with no visible windows.
2. **Empty visible list** → `clearTargetAndHover`.
3. **Search best-match** (`bestMatchOnSearchChange`) → jump to the first visible (best-scored) window.
4. **No target yet** (`selectedTarget == nil`, first refresh) → "from scratch" initial pick.
5. **Target still present** → follow it to its new index (`selectAt`).
6. **Target gone** → adapt to the closest visible window.

`selectedTarget` means two different things, split by `userPickedSelection`: while the user hasn't moved the
selection it is merely where the DEFAULT landed, so step 4 re-derives it on every refresh; once the user
cycles or hovers it is a commitment and step 5 follows THAT window by id however the list reorders (#5665).
Conflating them was a bug: the switcher opens while the window set is still settling (tabs grouping, Spaces
settling), so the default locked onto whatever occupied the slot mid-churn and then trailed that window across
the list as things resolved — the highlight ending up on an unrelated tile.

Initial-pick rules: with the last-focused rule, pick the visible non-windowless window with the lowest
`lastFocusOrder`; the both-top-minimized edge lands on index 0; otherwise `secondVisibleIndex` — the SECOND
VISIBLE window (the one you were on before the current one), wrapping to the only visible window when there
is just one. It counts VISIBLE windows, not raw indices: hidden windows sit in the MRU too (a background tab
is fronted when discovered, then hidden once grouped), so index 0 can be hidden and index 1 be the CURRENT
window — counting indices then selected the current window itself. Windowless app entries and invisible
windows are skipped when scanning. `findTarget` only matches a target id that is currently visible.

`secondVisibleIndex` counts the MRU **as of the summon**: windows flagged `appearedAfterSummon` are stepped
over. The drawn list keeps showing the truth — a window created and focused behind the switcher takes tile 0
and pushes everything along — but "the window you were on before" is a question about the moment the shortcut
was pressed, and it does not change because something else appeared afterwards. The flag means ABSENT FROM THE LIST AT THE PRESS, not "focused since": a tab group re-electing a
different member of itself is a focus change with no newcomer, and a late read telling us who was already
frontmost only re-orders windows that were there all along, so the pick re-derives over both. Nothing is pinned: the answer is recomputed
every refresh, so a window that closes or stops being drawn drops out of it, and when stepping over leaves
nothing to land on the plain rule takes over.

**Only an ARRIVAL is stepped over, never a REPLACEMENT.** A newcomer can take the tile of a window that left
the drawn list in the same breath, and then nothing moved down for the pick to compensate for. Live case: two
Finder windows with tabs, switch a tab, summon — the incoming tab is a window the model had never tracked
(untracked inactive tabs are the norm), so it is a newcomer at tile 0, while the tab it replaced stops being
drawn. Tile 1 is still the other Finder window, and stepping over aimed one tile past it at an unrelated app.
The two are told apart by the length of the list: newcomers are stepped over only while there are more visible
windows than at the summon (`visibleCountAtSummon`), which is exactly how many of them arrived rather than
replaced. The count is measured on the summon's first selection pass — the same main-thread turn as the press,
so no event can land in between.

## Test scenarios

Mirrors `SelectionResolverTests.swift` 1:1. Groups: A initial pick · B preserve target (#5665) ·
C target removed · D search mode · E edge cases · plus direct helper-kernel checks.

### A. Initial pick (`selectedTarget == nil`)
- **testInitialPickEmptyList** — no windows → `clearTargetAndHover`.
- **testInitialPickSingleVisible** — one window → `resetThenSelect(0)`.
- **testInitialPickTwoVisibleDefaultRules** — default Cmd-Tab cycles to slot 1.
- **testInitialPickTopTwoMinimized** — both top windows minimized → land on index 0, not cycle past.
- **testInitialPickUseLastFocusedRule** — alpha/space ordering → pick lowest `lastFocusOrder`.
- **testInitialPickAllInvisible** — everything filtered out → `clearTargetAndHover`.
- **testInitialPickSkipsWindowlessInLastFocusedRule** — windowless entries skipped when scanning.

### B. Preserve target across reorders (the #5665 regression cluster)
- **testPreserveTargetSameIndex** — target still at its index → `selectAt` unchanged.
- **testPreserveTargetMovedToHigherIndexAfterPhotoshopLaunch** — an app launches and reorders the list; highlight follows the target to its new slot (not a re-pick).
- **testPreserveTargetMovedToLowerIndex** — a window closed above the target; highlight follows down.
- **testPreserveTargetIndexUnchangedByCoincidence** — churn that lands the target at the same index.
- **testPreserveTargetNewWindowAppended** — new window appended at the end; target slot unchanged.
- **testPreserveTargetAcrossMultipleReorders** — repeated focus-stealing; target tracked every refresh.

### C. Target removed / no longer visible
- **testTargetRemovedAdaptToClosestBelow** — target closed; backfill the target to the window now at that index.
- **testTargetRemovedSelectedIndexOutOfBounds** — list shrank below `selectedIndex` → closest visible below.
- **testTargetBecameInvisible** — target filtered out (search/space) → closest visible below.
- **testTargetRemovedAndListEmptied** — nothing left → `clearTargetAndHover`.
- **testTargetRemovedOnlyOneLeft** — one window remains → select it and backfill the target.

### D. Search-mode interactions
- **testSearchBestMatchOnSearchChange** — new query produces a best match → jump to first visible.
- **testSearchRestoreDefaultOnClear** — cleared query → restore the default initial pick.
- **testTargetPreservedInSearchMode** — target preservation works the same with search active.
- **testSearchTargetFilteredOutWithOthersMatching** — target filtered but others match → adapt to closest.

### E. Edge cases
- **testEdgeSingleWindowBecomesInvisible** — the only window goes invisible → clear selection.
- **testEdgeNewWindowPushesTargetDown** — a window inserts ahead → highlight follows the target down.
- **testEdgeStaleSelectedTarget** — target id never existed (corrupt/stale) → adapt + backfill.

### Helper kernels (direct)
- **testGetLastFocusedOrderWindowIndexIgnoresWindowlessAndInvisible** — scan ignores windowless + invisible.
- **testInitialPickStepsOverWindowThatAppearedAfterSummon** — a window focused behind the switcher takes slot 0;
  the default still lands on the window that was previous when the shortcut was pressed.
- **testInitialPickFollowsALateCorrection** — the same shape without the flag (a correction about who was
  already frontmost) re-derives over the corrected order instead.
- **testInitialPickDoesNotStepOverANewcomerThatReplacedADrawnWindow** — switching a tab brings in an untracked
  window at tile 0 while the tab it replaced stops being drawn; the list is no longer, so the pick stays on
  tile 1 instead of aiming past it.
- **testInitialPickDoesNotStepOverANewcomerThatTookFocusFromAWindowThatLeft** — the same one beat earlier, with
  the focus change landing behind the switcher too.
- **testInitialPickStepsOverOnlyAsManyNewcomersAsTheListGained** — two newcomers, one of them a replacement:
  only the arrival is stepped over.
- **testInitialPickDoesNotStepOverAWindowAppendedBehindTheCurrentOne** — a newcomer appended at the back
  lengthens the list without disturbing its front, so the current window is not stepped over to pay for it.
- **testInitialPickFallsBackWhenSteppingOverLeavesNothing** — every visible window focused during the session
  → the plain rule takes over rather than returning nothing.
- **testCycleFromZeroBehavior** — `secondVisibleIndex`: empty / single-visible (wraps to it) / multi; and a
  HIDDEN window at index 0 must not shift the pick onto the CURRENT window (a background tab is fronted in the
  MRU when discovered, then hidden once grouped, so index 0 can be hidden and index 1 IS the current window —
  counting raw indices selected the current window itself).
- **testFindTargetSkipsInvisibleMatches** — finds visible id; nil for invisible/missing/nil id.
- **testDefaultSelectionRetracksModelUntilUserPicks** — an untouched default re-derives as the model settles.
- **testUserPickedTargetIsFollowedNotRederived** — the same target, once the USER chose it, is followed (#5665).
- **testDefaultDoesNotTrailAWindowThatSlidDownTheList** — the captured failure: the default locked onto a
  window that then slid down the list, dragging the highlight to a nonsense slot.
