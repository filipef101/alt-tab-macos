# ActivationFocusResolver — Specs

## Summary

Pure decisions for MRU focus around an app activation, extracted from `WindowServerEvents` after two
regressions in a row (#5596). The recorded ground truth (TextEdit and iTerm, via Cmd+Tab, clicks, and
AltTab-initiated focus): on activation macOS emits 808s for the app's on-Space windows — the **first** is the
genuinely focused window; the rest, when there is a storm at all, are raises front-to-back; sometimes there is
**no** storm, just the single focus 808 (iTerm). Three rules follow:

- The **first 808** of a live activation bumps the MRU. It is the truth, and it bypasses the `isActive` guard
  (`NSRunningApplication.isActive` is a separate clock and can still read false at that instant).
- The **raise tail** (subsequent 808s for wids still in the activation snapshot) is swallowed — re-fronting
  each would reverse the app's MRU (the original #5596 inversion).
- The **AX focused-window backstop** (`bumpFocusOnActivation`, for activations that emit no 808) is the weak
  signal: it races the app's internal focus update and can return the *previous* window (iTerm with panes).
  It yields once the activation's focus 808 has spoken (`focusBumped`), checked at apply time since the read
  is async and can land after the 808.

`ActivationEntry` is the per-pid state: the snapshot `wids` (only windows the storm can raise — the adapter
excludes minimized and inactive tabs), the `until` expiry (0.5s; generous because the 808s queue behind
AltTab's own activation work), `focusBumped`, and `raiseTail`.

`raiseTail` is `wids` as it was built, never drained. The 808 path spends `wids` (a wid still in it is a
raise), which leaves the set useless to the **815** path in `WindowEventReducer`: a tail's order-ins arrive
after its focus events emptied it, so an empty set is not "the storm is over". That path therefore reads
`raiseTail` — "was this wid ever a candidate of this activation" — bounded by `until`. An AltTab-initiated
activation snapshots nothing, so its tail is empty and the user's own Cmd+` inside the 0.5s is a real focus
(#5875, where the plain time gate swallowed it and the next alt-tab landed back on the window they left).

## Functions

- **`onFocusEvent(entry, wid, now, wasJustCreated, appIsActive) -> FocusDecision`** — decide one 808:
  `bump` + the entry state to store back. Expired entry ⇒ pruned (nil) and plain rules apply. Brand-new
  window ⇒ always bump. First 808 of a live activation ⇒ bump, mark `focusBumped`, consume the wid.
  In-snapshot 808 after that ⇒ raise, swallow, consume. Otherwise ⇒ bump iff `appIsActive`.
- **`onActivation(snapshotWids, until, altTabTarget) -> (entry, bumpWid)`** — build the activation entry.
  A known AltTab-initiated target (switcher selection / CLI focus) is bumped directly with `focusBumped` set
  (AX backstop yields) — with no 808 and a stale AX read, the freshly-focused window's bump was otherwise
  lost — and with an EMPTY snapshot, because AltTab raises exactly one window rather than fronting the app's
  stack, so that activation has no raise tail to swallow (#5785's log: three alt-tabs into a 3-window Chrome,
  one 808 each, always the target's). No target ⇒ plain entry; the first 808 or the AX backstop decides.
- **`altTabIntentToRecord(wid, pid, frontmostPid, at) -> AltTabFocusIntent?`** — is AltTab's own focus worth
  recording, i.e. is an activation actually COMING? Not when the app is already frontmost: nothing would
  consume the record, and a leftover intent hands the next activation of that app a stale target AND "no raise
  tail to mute", so the real burst re-fronts each window (#5596). The in-app case needs nothing from it — its
  focus arrives as an ordinary 808, or an order-in for Cmd+`.
- **`altTabIntentApplies(intent, activatedPid, now) -> Bool`** — does a recorded intent belong to THIS
  activation? Same app, and within `altTabIntentFailsafe` (1s), which only exists because an activation that
  never comes must not leave the record live forever.
- **`axBackstopShouldApply(entry) -> Bool`** — false only when a live entry has `focusBumped` (the real
  808 already spoke); nil/expired/pre-focus ⇒ true.

## Test scenarios

Mirrors `ActivationFocusResolverTests.swift` 1:1.

### onFocusEvent

- **testFirstFocusOfActivationBumpsEvenWhileInactive** — single 808 right after activation, `isActive` still
  false (the iTerm #5596 case) → bump; `focusBumped` set; wid consumed.
- **testRaiseTailSwallowed** — post-focus 808 for a wid still in the snapshot (the TextEdit storm) → no bump;
  wid consumed.
- **testSecondFocusOfSameWidBumps** — a wid's second 808 (entry already consumed) while active → bump.
- **testExpiredEntryPrunedAndNormalRulesApply** — entry past `until` → pruned to nil; plain isActive rule.
- **testNoActivationActiveAppBumps** — no entry, app active → bump.
- **testNoActivationInactiveAppDropped** — no entry, app inactive (background app re-focusing itself) → drop.
- **testJustCreatedAlwaysBumps** — brand-new window's first focus bumps even inactive, even mid-raise-tail.

### onActivation

- **testAltTabInitiatedActivationBumpsKnownTarget** — known target → bumped directly; entry starts
  `focusBumped` (the AX backstop yields) with an empty snapshot.
- **testAltTabInitiatedActivationMutesNothing** — that empty snapshot means a later 808 for ANOTHER window of
  the same app bumps: the second alt-tab of #5785's stuck switcher.
- **testRestoringAMinimizedTargetMutesTheDeminiaturizeTail** — a MINIMIZED target is the exception: AltTab
  deminiaturizes before focusing, restoring a window stirs the app's others, so this activation does have a
  tail and the snapshot is kept. Live I-11: the sibling's 808 landed 38ms in and took the front off the
  window just restored (#5439).
- **testRestoringAMinimizedTargetStillBumpsTheTargetsOwnFocus** — the target is subtracted from that tail, so
  its own 808 is never read as a raise. A GUARD, not a pin: it passes with the fix removed too (an empty
  tail contains nothing either), and exists to catch a future change that widens the tail to include the
  target. The two tests around it are teeth-verified — both fail when the subtraction is reverted.
- **testRestoringAMinimizedTargetMutesEachSiblingOnlyOnce** — the entry consumes per wid, so a genuine later
  switch to that sibling still bumps; the muting is one event deep, not a 0.5s blackout.

- **testExternalActivationWaitsForFocusSignal** — no target (Cmd+Tab, click) → plain entry; the first 808
  (or the AX backstop when none arrives) decides.

### raiseTail

- **testRaiseTailSurvivesTheFocusEventsThatDrainTheSnapshot** — two 808s empty `wids`; `raiseTail` still names
  both, which is the only thing left for the order-ins that arrive after them (#5596).
- **testAltTabInitiatedActivationHasAnEmptyRaiseTail** — we raised one window, so nothing this app orders in
  during the 0.5s is a raise of ours (#5875).

### the AltTab focus intent

- **testIntentIsRecordedWhenAnActivationIsComing** — target app not frontmost → recorded.
- **testNoIntentWhenTheAppIsAlreadyFrontmost** — no activation will follow, so nothing is recorded; the hole
  that let a stale intent disable the mute for a later genuine Cmd+Tab burst.
- **testIntentAppliesOnlyToItsOwnAppAndOnlyWhileFresh** — another app's activation, or one past the failsafe,
  is not the activation our focus caused.

### axBackstopShouldApply

- **testBackstopAppliesBeforeFocus808** — pre-focus entry or no entry → apply (zero-808 activations need it).
- **testBackstopYieldsAfterFocus808** — `focusBumped` → yield (the stale-AX race, #5596).
