# WindowEventReducer — Space-transition effects — Specs

## Summary

Pins the SPLIT between the two reactions to a Space switch: `spaceTransitionStarted` (the leading edge of
the 1329/1401 burst) and `spaceChangeSettled` (its trailing edge, 250ms later). Specs + Tests without a
same-named kernel, like `WindowEventReducerPhantom`: the subject is which effects each branch emits, not a
pure function of its own.

Driven through `WindowEventReducer.reduce` directly. The replay harness cannot judge this — it records both
branches' requests into the same `pendingRequests` bucket and swallows `.refreshUi` entirely as display-side,
so a scenario replay sees no difference between the two.

## Why this exists (#5864)

v11.3.1 reacted to a Space switch on the LEADING edge of `NSWorkspace.activeSpaceDidChange`. The WindowServer
migration replaced that with a trailing-only 250ms debounce, so the active Space stayed stale for ~273ms after
every switch (measured live) and a Cmd+Tab inside that window was filtered, sorted and DISCOVERED against the
Space the user had just left. That is not merely a display filter: `Window.init` defaults a new window to
`[Spaces.currentSpaceId]` and the Space-join branch gates promotion on `visibleSpaces`, so a stale active
Space poisons the model exactly while the arriving Space's windows are being reported.

The reaction is therefore split by cost, and the split is what these tests hold in place:

- the topology is **a fact that flips** — one CGS round-trip (p50 0.097ms, measured), valid immediately
  because CGS already answers with the new Space at the first 1329. It goes on the leading edge.
- per-window membership and the WindowServer state re-query are **a state that settles** — they are what the
  transition's window storm is churning, so an early answer is a wrong answer that has to be re-taken. They
  stay on the trailing edge.

**The trap the first test guards.** The leading edge must NOT repaint. `App.refreshOpenUiAfterExternalEvent`
is throttled at 200ms leading-edge, so a repaint fired the instant the Space flips SPENDS that edge, and the
update that actually matters — the arriving Space's focus 808, which lands 14–67ms later and re-orders the
tiles — then waits out the tail. Measured live with the switcher open across a transition: it pushed the MRU
correction from 19ms to 220ms after the summon. It looks free and it is not.

## Scenarios

### A. The leading edge is the topology read, and nothing else

- **testSpaceTransitionStartedEmitsTheTopologyReadAlone** — `.spaceTransitionStarted` emits exactly
  `[.refreshSpacesTopology]`: no repaint (the 200ms-throttle trap above), and none of the settled branch's
  expensive work.
- **testSpaceTransitionStartedTouchesNoWindowState** — the leading edge asks the shell to re-read the
  topology and writes nothing on the model itself, so the state it returns is byte-for-byte the one it got.

### B. The trailing edge keeps the expensive half

- **testSpaceChangeSettledKeepsMembershipAndTheStateRequery** — `.spaceChangeSettled` still emits the
  per-window Space sync, the WindowServer state re-query for every tracked window, the shortcut re-check and
  the repaint. Collapsing the two branches into one would either run this storm-time work early or lose it.
