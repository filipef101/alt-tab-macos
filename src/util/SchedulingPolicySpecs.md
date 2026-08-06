# SchedulingPolicy — Specs

## Summary

`SchedulingPolicy` holds the pure timing decisions behind the AX scheduling layer, extracted so they're
testable without real clocks or queues (same pattern as `SelectionResolver` / `AxQueryRouting`):

- **`ThrottleDecision`** — for one `throttleOrProceed` call: run on the leading edge, or (within the
  window) schedule a single trailing run and coalesce the rest. Used by `Throttler` and `ThrottlerWithKey`.
- **`RetryPolicy`** — backoff schedule (200ms → 1s → 2s → 5s, then 5s) and the 60s give-up, for retrying
  an AX call against an unresponsive app. Used by `AXCallScheduler`.
- **`InactiveTabScanPolicy`** — may we brute-force an app's AX tree for the inactive tabs its AXTabGroup named
  but we hold no window for, and WHERE should that sweep start? That walk is the ONLY way to adopt an inactive tab (it appears in no CGS list) and
  it is expensive, so it is gated per app on the SITUATION: the untracked titles plus the app's window count,
  which is what says whether anything has changed since we last looked. Used by
  `Applications.discoverInactiveTabs`.

## Test scenarios

Mirrors `SchedulingPolicyTests.swift` 1:1.

### A. ThrottleDecision
- **testThrottleFirstCallRunsNow** — no prior fire → `runNow`.
- **testThrottleAfterWindowRunsNow** — elapsed ≥ delay → `runNow` (window reset).
- **testThrottleWithinWindowSchedulesTail** — within window, no tail pending → `scheduleTail(remaining)`.
- **testThrottleWithinWindowWithPendingTailCoalesces** — within window, tail already pending → `coalesce`.
- **testThrottleClockGoingBackwardsRunsNow** — now < last (monotonic-clock guard) → `runNow`.
- **testThrottleBurstCoalescesAfterOneTail** — a burst yields one leading run, one `scheduleTail`, then `coalesce` for the rest.

### B. RetryPolicy
- **testRetryBackoffSequence** — retry 0/1/2/3/4… → 200ms / 1s / 2s / 5s / 5s.
- **testRetryBackoffClampsAndFloors** — counts past the last step clamp to 5s; negative counts floor to the first step.
- **testRetryGivesUpAtThreshold** — elapsed ≥ 60s → give up.
- **testRetryDoesNotGiveUpEarly** — elapsed < 60s → keep retrying.

### C. InactiveTabScanPolicy

The situation used to be recorded BEFORE the scan ran and then refused forever, so one fruitless attempt — the
app's AX tree not ready yet, the classic at launch — permanently gave up on it, with no retry and no later
trigger. Measured over a live QA run (2026-07-30): 82 tab reads named untracked tabs and the scan adopted
NOTHING, against 57 adoptions in a run whose first attempt happened to land. So the outcome is what gets
recorded, and a situation gets a small budget instead of exactly one shot.

- **testFruitlessScanIsRetriedOnTheSameSituation** — the fix: three fruitless attempts on one situation are all
  permitted, where the first used to close the door.
- **testFruitlessScansStopAtTheCap** — and bounded, because fruitless is ORDINARY, not an error: Finder destroys
  a backgrounded tab's window, so its AXTabGroup routinely names tabs with no window to find
  (`testFinderTabsAllUntracked`) and no number of walks resolves them. Past the cap the tree is left alone.
- **testANewSituationIsAlwaysEligible** — any change to the app's window set (a tab adopted, opened or closed)
  moves the titles or the count, and makes the app eligible again however exhausted the last situation was.
- **testTheSweepStartsNearTheAppsOwnElementsNotAtZero** — WHERE the sweep begins is what decided whether it
  found anything. It walks AXUIElementIDs one by one under a wall-clock budget, so it covers a WINDOW of the
  id space and never the space; starting at 0 aimed that window at wherever the app was hours ago. Measured
  live: three attempts covered ids `0..<30000` (~9.7k per 250ms) and adopted nothing, while Finder's window
  elements sat at ~31000 — stopping just short, every time. A tab's window element is minted when the tab is,
  so an app's windows cluster in a narrow band and a window we already track names it; anchoring a margin
  below found them in a single attempt (D-01/D-03/T-15 went green, D-01 from 34s to 16s).
- **testARetryResumesWhereTheLastSweepStopped** — the cursor from a fruitless attempt beats the anchor, so
  retries climb the id space instead of re-walking what already failed.
- **testASuccessfulScanSpendsNoBudget** — a scan that adopted something made progress and the situation it
  leaves is new anyway; only a fruitless attempt consumes budget, and a fresh situation restarts it.
