import CoreGraphics
import Foundation

/// The pure, replayable snapshot of the window model — everything the event-handling ORCHESTRATION reads
/// and writes, lifted off the live object graph (`Windows.list` / `Window` / `TabGroups` statics / the
/// pending sets on `Windows`) into one value type. `WindowEventReducer` evolves it as
/// `(TrackedWindowState, ReducerInput) -> [ReducerEffect]`; the adapters (`WindowServerEvents`, `Applications`,
/// `TabGroup`) shrink to an IO shell that snapshots, reduces, applies, and executes effects. A debug-log
/// recording then replays as a unit test: fixture = initial state + inputs, assertions = invariants after
/// every step (see `TestReducerRunner`).
///
/// **The synthetic-fact rule lives here.** Facts the adapter writes that aren't raw OS reports — the hold
/// (`held`), a borrowed Space (`spaceIsBorrowed`), the mirrored fullscreen flag (`isFullscreenMirrored`) —
/// are first-class fields, and `TrackedWindowState.tabWindow` is THE projection to the kernels' `TabWindow`,
/// masking or forwarding each, so no kernel can read a synthetic fact as OS evidence (the rec14/15/20/21 bug
/// class). "The" is literal now: the live model had a second copy for its one remaining group mutation, and
/// it had silently drifted (no `lastLeftSpaceId`, no handover edge). That path goes through this one.
struct TrackedWindow: Equatable {
    /// stable identity, same scheme as `WindowState.id`: "wid-N" for tracked windows, "pid-N" for an app's
    /// windowless placeholder (placeholders hold MRU slots, so they must exist here for the shifts to match)
    var id: String
    var wid: CGWindowID?
    var pid: pid_t
    var title = ""
    var size: CGSize?
    var position: CGPoint?
    var spaceIds = [UInt64]()               // CGSSpaceID === UInt64
    var spaceIndexes = [Int]()              // SpaceIndex === Int
    var isOnAllSpaces = false
    /// SYNTHETIC marker: `spaceIds` was copied from a tab sibling, not reported by CGS (see `Window.spaceIsBorrowed`)
    var spaceIsBorrowed = false
    var isFullscreen = false
    /// SYNTHETIC marker: `isFullscreen` was mirrored from the active tab sibling, not reported by the
    /// WindowServer (see `Window.isFullscreenMirrored`)
    var isFullscreenMirrored = false
    var isMinimized = false
    var isMainWindow = false
    var isWindowlessApp = false
    /// the latched CGS phantom verdict (`Window.storedState.isPhantom`); the user-facing value is
    /// `TrackedWindowState.isPhantom(_:)`, derived at read like the live `Window.isPhantom`
    var cgsPhantomLatch = false
    /// The Space this window most recently LEFT (from a 1326), cleared when it joins one again. HISTORY, and
    /// the only thing that distinguishes a tab which just backgrounded inside window A from a brand-new tab
    /// of window B: by current facts both are merely Space-less, same app, same size, unlinked. Genuine CGS
    /// evidence, not an annotation — the event names the Space — so unlike `isHeld`/`spaceIsBorrowed` the
    /// kernel projection forwards it as-is.
    var lastLeftSpaceId: UInt64?
    /// **The handover edge.** The wid that took this window's place on the Space it just left — its 1326 and
    /// that wid's 1325 name the same Space within `recentPairingWindow`. Cleared when this window joins a
    /// Space again (it is no longer the one that was replaced).
    ///
    /// This is the fact a Space cannot supply. `lastLeftSpaceId` names the SPACE left, which identifies the
    /// WINDOW only where one window owns a Space — true in fullscreen, false everywhere else: two Terminal
    /// windows stacked at the same frame on one Space are identical on every other fact, so "it left Space 1"
    /// is true of both and geometry hands one window's tab to the other
    /// (`testBackgroundedTabIsNotStolenByAStackedWindowOfTheSameApp`). The successor's WID names the window.
    ///
    /// Recorded from either direction, because the two halves race: the leave may land first (the join is
    /// paired when it arrives) or the join first (the leave is paired against the remembered join). The
    /// `HandoverOrder` fuzz axis exists to keep both live.
    var replacedByWid: CGWindowID?
    /// The other end of the same edge: the wid THIS window replaced on the Space it just joined. Read by
    /// `dragOutVerdict` — a join that replaced someone is a tab SWITCH, a join that replaced nobody is a tab
    /// dragged OUT, and neither needs a frame comparison to say so. Cleared when this window leaves a Space.
    var replacedWid: CGWindowID?
    /// Tab-button count from this window's last AXTabGroup read (0 = none / not tabbed). Written by the two
    /// paths that read tabs (`discoveryLanded`, `titleAndTabsRead`) and NEVER cleared by a nil read: an
    /// active tab reports no AXTabGroup transiently while tabs are created or switched, and the whole
    /// nil-titles policy exists because that transient must not be read as "no longer tabbed". Cleared only
    /// by a positive signal, when a read RETURNS titles saying otherwise. See `TabWindow.tabCount`.
    var tabCount = 0
    /// **The MRU truth**: the uptime at which the OS last told us this window came forward (the event's own
    /// `now`, never a time we invent). 0 = never seen focused, which sorts behind every window that was.
    /// Stored rather than derived because it is the one thing that survives a LATE report: a window
    /// discovered 80ms after its order-in, or any event we could only apply once the wid was tracked, is
    /// placed by WHEN IT HAPPENED instead of when we got around to it (#5785, WeChat landing last).
    var focusedAt: TimeInterval = 0
    /// DERIVED from `focusedAt` by `recomputeFocusRanks` — the dense MRU rank every reader still speaks
    /// (0 = most recent), so kernels, the switcher's selection and `--focusUsingLastFocusOrder` are unchanged.
    /// Never assign it to express a focus; call `noteFocus`.
    var lastFocusOrder = 0
    var creationOrder = 0
    /// whether a thumbnail exists (the reducer decides thumbnail BORROWING between siblings; the pixels stay
    /// in the shell — `ReducerEffect.copyThumbnail`)
    var hasThumbnail = false
}

/// The per-app facts the orchestration reads: the kernel-facing `ApplicationState` plus `isActive`
/// (an AppKit fact — `NSRunningApplication.isActive` — that several event decisions key on).
struct TrackedApp: Equatable {
    var state: ApplicationState
    var isActive = false
}

/// The tab-group registry as a pure value type — the same tables and funnel operations as the live
/// `TabGroups` class (which delegates its storage and mutations here), so the reducer and the live model
/// share ONE implementation of membership semantics: a wid belongs to at most one group, a group has ≥ 2
/// members and exactly one representative, `isTabbed` = member ∧ ¬representative. Mutations return their
/// log lines instead of logging (the caller logs / the replay harness records), and the wids they
/// ungrouped instead of clearing borrowed Spaces (the owner of the windows does — `TrackedWindowState` or the live
/// `TabGroups` wrapper), keeping this type dependency-free.
struct TabGroupsTable: Equatable {
    private(set) var membersByGroup = [Int: [CGWindowID]]()
    private(set) var groupByWid = [CGWindowID: Int]()
    private(set) var representativeByGroup = [Int: CGWindowID]()
    private(set) var nextGroupId = 1

    /// What a mutation did: whether anything changed, which wids left membership (their borrowed Space must
    /// die with it — rec20), and the log lines to emit, in order.
    struct Mutation {
        var changed = false
        var ungroupedWids = [CGWindowID]()
        var logs = [String]()
    }

    /// Picks a group's representative after a shrink left it without one. Called with the remaining member
    /// wids and the MID-MUTATION table (the shrunk member list is already written), so the caller can build
    /// coherent `TabWindow` snapshots for `TabGroupResolver.groupRepresentative`.
    typealias RepresentativePicker = ([CGWindowID], TabGroupsTable) -> CGWindowID?

    func groupId(of wid: CGWindowID) -> Int? { groupByWid[wid] }

    func siblingWids(of wid: CGWindowID) -> [CGWindowID]? {
        guard let gid = groupByWid[wid], let members = membersByGroup[gid], members.count > 1 else { return nil }
        return members
    }

    func isTabbed(_ wid: CGWindowID) -> Bool {
        guard let gid = groupByWid[wid] else { return false }
        return representativeByGroup[gid] != wid
    }

    /// Does this group have a CLAIM TO THE SCREEN (see `TabGroups.hasScreenClaim` for the rec22 story)?
    /// `memberHasClaim` supplies the per-window fact ("on some Space, or held mid-swap") from whichever
    /// window store the caller owns.
    func hasScreenClaim(_ gid: Int, memberHasClaim: (CGWindowID) -> Bool) -> Bool {
        (membersByGroup[gid] ?? []).contains { memberHasClaim($0) }
    }

    /// Make `wids` a group, EXACTLY (see `TabGroups.form`). `changed` mirrors the live return value.
    mutating func form(_ wids: [CGWindowID], representative: CGWindowID, reason: String,
                       repPicker: RepresentativePicker) -> Mutation {
        var members = [CGWindowID]()
        for w in wids where !members.contains(w) { members.append(w) }
        guard members.count > 1, members.contains(representative) else { return Mutation() }
        // fast path: the exact same set already IS a group — order + representative upkeep only, no log spam
        if let gid = groupByWid[representative], Set(membersByGroup[gid] ?? []) == Set(members) {
            membersByGroup[gid] = members
            return setRepresentative(representative, reason: reason)
        }
        var result = Mutation(changed: true)
        let oldGids = Set(members.compactMap { groupByWid[$0] })
        let gid = nextGroupId
        nextGroupId += 1
        for w in members { groupByWid[w] = gid }
        membersByGroup[gid] = members
        representativeByGroup[gid] = representative
        for old in oldGids { shrinkAfterDetach(old, reason: "\(reason)→g\(gid)", repPicker: repPicker, into: &result) }
        result.logs.append("group form g\(gid) rep=#\(representative) members=\(members) reason=\(reason)")
        return result
    }

    /// Take `wid` out of its group (see `TabGroups.remove`).
    mutating func remove(_ wid: CGWindowID, reason: String, repPicker: RepresentativePicker) -> Mutation {
        guard let gid = groupByWid[wid] else { return Mutation() }
        var result = Mutation(changed: true)
        groupByWid[wid] = nil
        result.ungroupedWids.append(wid)
        shrinkAfterDetach(gid, reason: "\(reason) -#\(wid)", repPicker: repPicker, into: &result)
        return result
    }

    /// Move a group's representative — which member it shows. No-op (and no log) when already there.
    mutating func setRepresentative(_ wid: CGWindowID, reason: String) -> Mutation {
        guard let gid = groupByWid[wid], representativeByGroup[gid] != wid else { return Mutation() }
        representativeByGroup[gid] = wid
        return Mutation(changed: true, logs: ["group rep g\(gid) rep=#\(wid) reason=\(reason)"])
    }

    /// Settle a group after members were detached (see `TabGroups.shrinkAfterDetach`): drop them from the
    /// member list, dissolve when ≤ 1 remains, re-pick the representative if it was the one taken.
    private mutating func shrinkAfterDetach(_ gid: Int, reason: String, repPicker: RepresentativePicker,
                                            into result: inout Mutation) {
        let remaining = (membersByGroup[gid] ?? []).filter { groupByWid[$0] == gid }
        if remaining.count <= 1 {
            for w in remaining {
                groupByWid[w] = nil
                result.ungroupedWids.append(w)
            }
            membersByGroup[gid] = nil
            representativeByGroup[gid] = nil
            result.logs.append("group dissolve g\(gid) reason=\(reason)")
        } else {
            membersByGroup[gid] = remaining
            // a group must always have a representative (else every member derives tabbed and the whole
            // group hides) — re-pick when it left with the detached members
            if !remaining.contains(representativeByGroup[gid] ?? 0) {
                representativeByGroup[gid] = repPicker(remaining, self) ?? remaining.first
            }
            result.logs.append("group shrink g\(gid) members=\(remaining) rep=#\(representativeByGroup[gid] ?? 0) reason=\(reason)")
        }
    }
}

/// The whole orchestration state: the window list (in `Windows.list` order — the title-match and geometry
/// passes are order-sensitive, "first compatible wins"), the app facts, the group registry, the pending
/// sets that used to live as statics on `Windows` / `WindowServerEvents`, and the Space topology the
/// decisions read. Plus the DERIVED reads (`isTabbed` / `isPhantom`) and the kernel projections
/// (`tabWindow` / `windowState`), mirrored from the live `Window` / `TabGroup` so live and replayed
/// decisions see identical facts.
struct TrackedWindowState: Equatable {
    var windows = [TrackedWindow]()
    var apps = [pid_t: TrackedApp]()
    var groups = TabGroupsTable()
    /// `Windows.windowsHeldVisibleForTab` — SYNTHETIC: a just-backgrounded tab kept visible through the
    /// new-tab discovery gap
    var held = Set<CGWindowID>()
    /// `Windows.recentlyCreatedWindows` — wids flagged brand-new by a WS create event, not yet promoted
    var recentlyCreated = Set<CGWindowID>()
    /// `Windows.windowsPendingSpaceRemoval` — a 1326 that arrived while the wid was still untracked
    /// Wid → the Space it was removed from while still UNTRACKED. The SPACE matters, not just the fact:
    /// a backgrounding tab leaves its Space and stays nowhere, but a window going FULLSCREEN also leaves its
    /// old Space — having just joined a new one. Remembering only "something was removed" made discovery
    /// force a brand-new fullscreen active Space-less, and it went phantom (generator seeds 7/11/15).
    var pendingSpaceRemoval = [CGWindowID: UInt64]()
    /// `Windows.windowsPendingFocusPromotion` — a focus signal that arrived while the wid was still
    /// UNTRACKED, kept so discovery can apply it at the time it happened rather than dropping it.
    var pendingFocusPromotion = [CGWindowID: FocusPromotion]()

    /// A focus signal held over the discovery gap, in one of two strengths.
    enum FocusPromotion: Equatable {
        /// The OS named this window focused (an 808) or put it on the visible Space (a 1325). Applied as the
        /// front on arrival, which is what the tab machinery reads as "this is the group's active tab".
        case asserted
        /// An untracked window merely ordered in. That counts as focus only for the app that was FRONTMOST at
        /// that instant, and the pid is what an untracked wid can't tell us — so the check waits for
        /// discovery. Applied at `at`, behind anything the OS focused since: fronting it on arrival would
        /// hand the front to a window the user has already left.
        case circumstantial(at: TimeInterval, frontmostPid: pid_t)
    }

    /// Uptime of the input being reduced (`systemUptime`), stamped by the shell before each dispatch. An
    /// input fact like any other, not a clock read: it exists so the branches that move the MRU without an
    /// event of their own (a re-front after a close, a group's elected visible) can stamp `focusedAt` with
    /// the moment they ran. Branches whose input CARRIES a `now` pass that instead — it is the truer time.
    /// Deliberately NOT carried between dispatches: every dispatch stamps its own.
    var now: TimeInterval = 0

    /// One half of a Space HANDOVER, waiting for the other. See `TrackedWindow.replacedByWid`.
    struct SpaceHandoverHalf: Equatable {
        var wid: CGWindowID
        var at: TimeInterval
    }

    /// A handover edge whose other half was an UNTRACKED wid — Finder mints one per tab switch, with no
    /// create event — kept until that wid is discovered and can carry it. `pendingSideJoined` says which end
    /// the pending wid is: it JOINED the Space (so it replaced the partner) or it LEFT it (so the partner
    /// replaced it). Consumed at `discoveryLanded`, which is also where the pid can finally be compared.
    ///
    /// **KEYS ARE ALWAYS UNTRACKED WIDS** — both writes in `recordHandover` are gated on
    /// `windowIndex(wid) == nil`, and `applyPendingHandoverEdge` consumes the entry at `newlyTracked`, the
    /// one moment a wid becomes tracked. So an entry can never survive into trackedness, which answers the
    /// question this map invites: no, the removal paths (`.livenessConfirmedDead` → `.removeWindow`) do not
    /// need to drain it, because by then the key cannot be here. The same holds for `pendingGroupInheritance`
    /// (keyed on an untracked joiner or successor, except for one write that the next line consumes).
    /// What DOES leak is a key that never becomes tracked at all, which is why the drains exist on the three
    /// paths where that is decided: superseded, destroyed, and rejected by the discriminator.
    struct PendingHandoverEdge: Equatable {
        var partnerWid: CGWindowID
        var pendingSideJoined: Bool
    }

    /// **Everything the reducer remembers that has NO home in the live model.** The fields above are
    /// projections of a `Window` / `TabGroups` / `Spaces` fact, so the bridge can rebuild them from the model
    /// on every dispatch; these have nowhere to be rebuilt FROM. They exist only in between two inputs, which
    /// is precisely what makes them fragile: `TrackedWindowStateBridge.snapshot()` starts from a fresh
    /// `TrackedWindowState()`, so a field it does not carry is empty at the start of every single input and
    /// any set written by one event and read by the next silently never fires.
    ///
    /// They are grouped into ONE value so the bridge parks the whole thing in one assignment each way and a
    /// new field cannot be forgotten. Add fields HERE, not to `TrackedWindowState` — and if a new field truly
    /// belongs at the top level, `TrackedWindowStateFieldsTests` will fail until it is classified, because
    /// that is the only thing standing between this class of bug and a green test suite. Measured: eight
    /// fields shipped unbridged (the whole minted-tab handover chain plus `offScreen`), all 817 tests green.
    struct Carried: Equatable {
        /// Wids the WindowServer took OFF screen (an 816) and has not put back yet. It exists to tell the two
        /// meanings of an order-in apart: a RAISE of a window that was on screen all along (Cmd+`), versus a
        /// RE-SHOW of one that had left it (Space switch, fullscreen exit, un-hide). Only the first is a focus
        /// signal — see `movedResizedOrOrderedIn`.
        var offScreen = Set<CGWindowID>()
        /// per-app activation state for the 808 storm
        var pendingActivationRaises = [pid_t: ActivationEntry]()
        /// uptime of the most recent `windowCreated`
        var lastWindowCreatedAt: TimeInterval = 0
        /// The wid of that most recent `windowCreated` (the pair to `lastWindowCreatedAt`, exactly as
        /// `lastUntrackedVisibleSpaceJoinWid` pairs with its `At`). A create is the OTHER way a mint can be
        /// superseded before discovery — opening a tab rather than switching to one.
        var lastWindowCreatedWid: CGWindowID?
        /// The most recent untracked Space JOIN on ANY Space, visible or not — the
        /// `lastUntrackedVisibleSpaceJoin` pair without the visibility gate. A tab switch inside a window whose
        /// Space we are no longer LOOKING at still mints a wid, and that mint is still the successor of the one
        /// it replaced; gating on visibility lost exactly that handover (generator seed 106, where a
        /// `newWindow` moves the viewport back to the windowed Space first). Kept separate rather than widening
        /// the visible pair, which feeds the hold-visible/promotion decisions and means what it says.
        var lastUntrackedSpaceJoinWid: CGWindowID?
        var lastUntrackedSpaceJoinAt: TimeInterval = 0
        /// uptime of the most recent UNTRACKED window joining a visible Space — Finder's tab switch mints a
        /// brand-new wid with no create event, so this 1325 is its only replacement signal (rec24; feeds
        /// `shouldHoldVisibleThroughDiscovery` like `lastWindowCreatedAt` does for creations)
        var lastUntrackedVisibleSpaceJoinAt: TimeInterval = 0
        /// The UNTRACKED wid that most recently announced itself by joining a visible Space — the incoming half
        /// of a Finder-style minted tab switch. Paired with the outgoing representative's 1326 a beat later, it
        /// says "this wid is the replacement for that group", which is the ONLY link available when the switch
        /// mints a brand-new wid: the new tab carries no AX tab group in fullscreen, and its frozen siblings sit
        /// at the pre-fullscreen size, so geometry can never cluster them together.
        var lastUntrackedVisibleSpaceJoinWid: CGWindowID?
        /// Minted wid → the group members it is taking over from, recorded when the pair above is observed and
        /// consumed at the minted wid's discovery. Pure causality from the event stream; the drag-out verdict
        /// still rules asynchronously if the frames say the tab was actually torn out.
        var pendingGroupInheritance = [CGWindowID: [CGWindowID]]()
        /// Untracked wid → the Space it last JOINED. An untracked wid leaving a Space means two different
        /// things: superseded before discovery ever reached it (drop what it had pending), or simply MOVED — it
        /// joined another Space first, which is what a fullscreen transition looks like. Only the Space it is
        /// leaving tells them apart.
        var untrackedJoinedSpace = [CGWindowID: UInt64]()
        /// Per Space, the most recent JOIN and LEAVE — the raw material of the handover edge. Two tables rather
        /// than one because the halves race: whichever lands first waits here for the other, so the pairing is
        /// order-independent by construction (the `HandoverOrder` fuzz axis keeps both directions honest).
        /// Keyed by Space, because that is what makes the two events one event: a window took another's PLACE.
        var lastSpaceJoin = [UInt64: SpaceHandoverHalf]()
        var lastSpaceLeave = [UInt64: SpaceHandoverHalf]()
        var pendingHandoverEdge = [CGWindowID: PendingHandoverEdge]()
    }
    var carried = Carried()

    var visibleSpaces = [UInt64]()
    var currentSpaceId: UInt64 = 0
    /// Space topology (`Spaces.idsAndIndexes`), for deriving `spaceIndexes` from `spaceIds`
    var spaceIndexById = [UInt64: Int]()
    var frontmostPid: pid_t?

    // MARK: window access

    func window(_ wid: CGWindowID) -> TrackedWindow? {
        windows.first { $0.wid == wid }
    }

    func windowIndex(_ wid: CGWindowID) -> Int? {
        windows.firstIndex { $0.wid == wid }
    }

    func appState(_ pid: pid_t) -> ApplicationState {
        apps[pid]?.state ?? ApplicationState(pid: pid, bundleIdentifier: nil, localizedName: nil, isHidden: false)
    }

    // MARK: derived facts (mirroring the live `Window` computed properties)

    func isTabbed(_ w: TrackedWindow) -> Bool {
        w.wid.map { groups.isTabbed($0) } ?? false
    }

    /// DERIVED phantom verdict — the exact composition of the live `Window.isPhantom`: hold exemption →
    /// group screen-claim exemption → `PhantomWindowDetector.syncVerdict` over the STORED record (whose
    /// `isTabbed` is dead storage, always false — the live value is derived and patched into `windowState`).
    func isPhantom(_ w: TrackedWindow) -> Bool {
        if let wid = w.wid {
            if held.contains(wid) { return false }
            if let gid = groups.groupId(of: wid), groups.hasScreenClaim(gid, memberHasClaim: { m in
                !(window(m)?.spaceIds.isEmpty ?? true) || held.contains(m)
            }) { return false }
        }
        return PhantomWindowDetector.syncVerdict(storedWindowState(w), appState(w.pid))
    }

    // MARK: kernel projections

    /// The `TabWindow` snapshot the tab kernels see — the ONE synthetic-fact chokepoint, identical to the
    /// live `TabGroup.tabWindow`: mirrored fullscreen is masked (kernels see GENUINE fullscreen only,
    /// rec21), the hold and the borrow are forwarded as the first-class flags they are (rec14/rec20).
    func tabWindow(_ w: TrackedWindow) -> TabWindow {
        tabWindow(w, in: groups)
    }

    /// Same projection over an explicit (possibly mid-mutation) registry — used by the representative
    /// re-pick inside a group mutation, where the live code reads the already-mutated static registry.
    func tabWindow(_ w: TrackedWindow, in table: TabGroupsTable) -> TabWindow {
        let wid = w.wid ?? 0
        return TabWindow(pid: w.pid, wid: wid, size: w.size, position: w.position,
            spaceIds: w.spaceIds, title: w.title, isTabbed: table.isTabbed(wid),
            isFullscreen: w.isFullscreen && !w.isFullscreenMirrored,
            isMinimized: w.isMinimized, tabbedSiblingWids: table.siblingWids(of: wid),
            isHeld: held.contains(wid),
            spaceIsBorrowed: w.spaceIsBorrowed,
            lastFocusOrder: w.lastFocusOrder,
            lastLeftSpaceId: w.lastLeftSpaceId,
            // Genuine event evidence, like `lastLeftSpaceId` and unlike `isHeld`/`spaceIsBorrowed`: the two
            // notifications name the wids and the Space themselves. Forwarded, never masked.
            replacedByWid: w.replacedByWid,
            replacedWid: w.replacedWid,
            tabCount: w.tabCount)
    }

    /// The STORED record (the live `Window.storedState`): `isPhantom` carries the CGS latch, `isTabbed` the
    /// dead stored value (never written — the live one is derived). Feed this to `syncVerdict`.
    func storedWindowState(_ w: TrackedWindow) -> WindowState {
        WindowState(id: w.id, isPhantom: w.cgsPhantomLatch, isWindowlessApp: w.isWindowlessApp,
            isFullscreen: w.isFullscreen, isMinimized: w.isMinimized, isTabbed: false,
            isOnAllSpaces: w.isOnAllSpaces, spaceIds: w.spaceIds, spaceIndexes: w.spaceIndexes,
            lastFocusOrder: w.lastFocusOrder, creationOrder: w.creationOrder, title: w.title,
            isMainWindow: w.isMainWindow)
    }

    /// The DERIVED record (the live `Window.state`): both derived facts patched in.
    func windowState(_ w: TrackedWindow) -> WindowState {
        var s = storedWindowState(w)
        s.isTabbed = isTabbed(w)
        s.isPhantom = isPhantom(w)
        return s
    }

    // MARK: group mutations (the borrow-clearing wrappers around `TabGroupsTable`)

    /// The representative re-pick every group mutation shares: `TabGroupResolver.groupRepresentative` over
    /// snapshots taken against the mid-mutation registry — same data flow as the live `TabGroups`.
    private func repPicker(_ remaining: [CGWindowID], _ table: TabGroupsTable) -> CGWindowID? {
        TabGroupResolver.groupRepresentative(remaining.compactMap { wid in window(wid).map { tabWindow($0, in: table) } })
    }

    @discardableResult
    mutating func formGroup(_ wids: [CGWindowID], representative: CGWindowID, reason: String) -> (changed: Bool, logs: [String]) {
        var table = groups
        let m = table.form(wids, representative: representative, reason: reason, repPicker: repPicker)
        groups = table
        return (m.changed, m.logs)
    }

    @discardableResult
    mutating func removeFromGroup(_ wid: CGWindowID, reason: String) -> [String] {
        var table = groups
        let m = table.remove(wid, reason: reason, repPicker: repPicker)
        groups = table
        return m.logs
    }

    @discardableResult
    mutating func setGroupRepresentative(_ wid: CGWindowID, reason: String) -> (changed: Bool, logs: [String]) {
        var table = groups
        let m = table.setRepresentative(wid, reason: reason)
        groups = table
        return (m.changed, m.logs)
    }


    // MARK: MRU

    /// Record that the OS brought `wid` forward at time `at`, then re-derive the ranks. Usually `at` is the
    /// newest time in the model and the window lands at the front, exactly as the old front-and-shift did.
    /// What differs is LATE news: a signal we could only apply after the fact slots in behind whatever the OS
    /// focused in the meantime, instead of jumping to the front (wrong — it steals a front the user has
    /// already left) or landing at the back (wrong — #5785's WeChat window, discovered 80ms late, went last).
    ///
    /// STRICTLY older news is refused: a report about T1 cannot undo what the OS said at T2 > T1.
    /// Returns the wids to re-render — this one, plus every window whose rank moved.
    mutating func noteFocus(_ wid: CGWindowID, at: TimeInterval) -> [CGWindowID] {
        guard let fi = windowIndex(wid), at >= windows[fi].focusedAt else { return [wid] }
        windows[fi].focusedAt = at
        return [wid] + recomputeFocusRanks(preferring: wid).filter { $0 != wid }
    }

    /// Re-derive every window's dense MRU rank from `focusedAt`, most recent first. Windows never seen
    /// focused (`focusedAt == 0`: freshly appended, or seeded from screen stacking on the first summon) sort
    /// behind the rest and keep their relative order, since the tiebreak is the rank they already held.
    /// `preferring` wins an exact tie, so two windows brought forward at the same instant end up in the order
    /// the reports arrived. Returns the wids whose rank changed.
    mutating func recomputeFocusRanks(preferring preferred: CGWindowID? = nil) -> [CGWindowID] {
        let ranked = windows.indices.sorted {
            guard windows[$0].focusedAt == windows[$1].focusedAt else {
                return windows[$0].focusedAt > windows[$1].focusedAt
            }
            if let preferred, windows[$0].wid == preferred || windows[$1].wid == preferred {
                return windows[$0].wid == preferred
            }
            return windows[$0].lastFocusOrder < windows[$1].lastFocusOrder
        }
        var changed = [CGWindowID]()
        for (rank, i) in ranked.enumerated() where windows[i].lastFocusOrder != rank {
            windows[i].lastFocusOrder = rank
            // a windowless placeholder holds a rank but has no wid and needs no re-render
            if let wid = windows[i].wid { changed.append(wid) }
        }
        return changed
    }

    /// Screen stacking, top-most first, as the MRU order for the windows we have no focus history for.
    /// Returns the wids whose rank changed.
    ///
    /// **It is written into the TIEBREAK, never over `focusedAt`, and that is the whole design.** Stacking is
    /// a guess about a past we did not watch, so it may only decide between windows nothing better is known
    /// about; `recomputeFocusRanks` orders by `focusedAt` first, so a window the OS told us was focused keeps
    /// its place whatever the screen looks like. The guess is also blind in a specific direction: the query
    /// lists the visible Spaces' windows, so a background tab, a minimized window and anything on another
    /// Space are simply absent — read literally, they all go last.
    ///
    /// Which is exactly what used to happen, because the seed was applied in the shell by assigning
    /// `lastFocusOrder` directly (`Windows.sortByLevel`), bypassing the derivation. The query blocks, so its
    /// answer lands AFTER the first render of the very first summon: live capture 2026-08-02 (T-21), where
    /// the just-focused Terminal tab had backgrounded into its own window, was therefore not in the z-order
    /// list, and fell from tile 0 to tile 3 ~20ms in — taking the highlight off the window the initial pick
    /// had chosen, since the pick had already been resolved against the order it replaced.
    ///
    /// Windows the query cannot see keep their existing relative order behind the stacked ones: not being on
    /// screen says nothing about which of them the user touched last.
    mutating func seedFocusOrderFromZOrder(_ widsTopFirst: [CGWindowID]) -> [CGWindowID] {
        var zOrder = [CGWindowID: Int]()
        for (i, wid) in widsTopFirst.enumerated() { zOrder[wid] = i }
        func stacking(_ i: Int) -> Int { windows[i].wid.flatMap { zOrder[$0] } ?? Int.max }
        let ordered = windows.indices.sorted { i, j in
            stacking(i) != stacking(j) ? stacking(i) < stacking(j)
                : windows[i].lastFocusOrder < windows[j].lastFocusOrder
        }
        for (i, index) in ordered.enumerated() { windows[index].lastFocusOrder = i }
        return recomputeFocusRanks()
    }

    /// The log fact every MRU bump emits, read before bumping.
    func mruBumpLog(_ wid: CGWindowID) -> String {
        let w = window(wid)
        return "mru bump #\(wid) \(apps[w?.pid ?? 0]?.state.localizedName ?? "?") from=\(w?.lastFocusOrder ?? 0) sp\(w?.spaceIds ?? [])"
    }

    /// One line per window REMOVAL, naming the path that condemned it. Several paths can remove a window, and
    /// without this a capture shows one simply vanishing from the tile dump and reappearing later as a fresh
    /// discovery, with no way to tell which path ran (#5785). Carries the facts that
    /// separate a real close from a false verdict: its MRU slot and Space (both lost by the removal, which is
    /// why a re-discovered window comes back at the wrong position) and whether it was grouped or held.
    func removalLog(_ wid: CGWindowID, reason: String) -> String {
        let w = window(wid)
        return "remove #\(wid) \(apps[w?.pid ?? 0]?.state.localizedName ?? "?") reason=\(reason)"
            + " mru=\(w?.lastFocusOrder ?? -1) sp\(w?.spaceIds ?? []) tabbed=\(w.map { isTabbed($0) } ?? false)"
            + " held=\(held.contains(wid)) title='\(w?.title ?? "")'"
    }

    /// Find the active tab (non-isTabbed) sibling in the same tab group (the pure
    /// `TabGroup.activeTabSibling`).
    func activeTabSibling(of w: TrackedWindow) -> TrackedWindow? {
        guard let wid = w.wid, let siblingWids = groups.siblingWids(of: wid) else { return nil }
        return windows.first { sibling in
            sibling.id != w.id && !isTabbed(sibling)
                && sibling.wid != nil && siblingWids.contains(sibling.wid!)
        }
    }

    /// Apply a freshly-queried window→Spaces result for one window (the pure `Window.updateSpaces`):
    /// inactive tabs return no Space from `CGSCopySpacesForWindows`, so an empty result falls back to the
    /// active tab sibling's Space, MARKED borrowed. A latch taken while the window was briefly Space-less
    /// drops once membership recovers. Returns whether `spaceIds` changed, and whether a real window just
    /// un-phantomed (its app's stale windowless placeholder must be dropped — an effect).
    mutating func applyWindowSpaces(_ wid: CGWindowID, spaceIds queried: [UInt64])
        -> (changed: Bool, unphantomedRealWindow: Bool) {
        guard let i = windowIndex(wid) else { return (false, false) }
        let before = windows[i].spaceIds
        let wasEmpty = before.isEmpty
        let wasPhantom = isPhantom(windows[i])
        var ids = queried
        var borrowed = false
        // inactive tabs return no space from CGSCopySpacesForWindows; use the active tab sibling's space
        if ids.isEmpty, let activeTab = activeTabSibling(of: windows[i]) {
            ids = activeTab.spaceIds
            borrowed = !ids.isEmpty
        }
        windows[i].spaceIsBorrowed = borrowed
        windows[i].spaceIds = ids
        windows[i].spaceIndexes = ids.compactMap { spaceIndexById[$0] }
        windows[i].isOnAllSpaces = ids.count > 1
        // A CGS verdict latched while this window's Spaces were briefly empty (mid Space-transition, e.g.
        // going fullscreen) is stale now that CGS placed it again (see `Window.updateSpaces`).
        if wasEmpty, !ids.isEmpty { windows[i].cgsPhantomLatch = false }
        let unphantomed = wasPhantom && !isPhantom(windows[i]) && !windows[i].isWindowlessApp
        return (windows[i].spaceIds != before, unphantomed)
    }

    // MARK: Space-membership deltas

    /// Apply one 1325/1326 delta (the pure `Window.applySpaceMembershipDelta`): mutate `spaceIds` directly
    /// from the payload — no CGS re-query — and re-derive `spaceIndexes`/`isOnAllSpaces`. A delta is genuine
    /// CGS evidence, so the borrow marker clears; a latch taken while the window was briefly Space-less is
    /// dropped once membership recovers. Returns whether `spaceIds` actually changed, and whether a real
    /// window just un-phantomed (its app's stale windowless placeholder must be dropped — an effect).
    mutating func applySpaceMembershipDelta(_ wid: CGWindowID, spaceId: UInt64, added: Bool)
        -> (changed: Bool, unphantomedRealWindow: Bool) {
        guard let i = windowIndex(wid) else { return (false, false) }
        let wasEmpty = windows[i].spaceIds.isEmpty
        let wasPhantom = isPhantom(windows[i])
        // A BORROWED membership is our own annotation, not CGS evidence, so an incoming delta must not be
        // UNIONED with it — that would launder the guess into fact. It replaces it: the event says where the
        // window actually is. Merging instead left a tab carrying the windowed Space it had been lent while
        // ALSO on its window's fullscreen Space; the borrow marker then cleared, so a stale Space read as
        // genuine and the tab could no longer be claimed by its own group (generator seeds 8/30).
        var ids = windows[i].spaceIsBorrowed ? [] : windows[i].spaceIds
        if added {
            guard !ids.contains(spaceId) else { return (false, false) }
            ids.append(spaceId)
        } else {
            guard let j = ids.firstIndex(of: spaceId) else { return (false, false) }
            ids.remove(at: j)
        }
        windows[i].spaceIds = ids
        windows[i].spaceIndexes = ids.compactMap { spaceIndexById[$0] }
        windows[i].isOnAllSpaces = ids.count > 1
        windows[i].spaceIsBorrowed = false  // a 1325/1326 delta is genuine CGS evidence
        // See `Window.updateSpaces`: drop a CGS verdict latched while this window's Spaces were briefly
        // empty (mid Space-transition), now that a Space delta restored membership.
        if wasEmpty, !ids.isEmpty { windows[i].cgsPhantomLatch = false }
        let unphantomed = wasPhantom && !isPhantom(windows[i]) && !windows[i].isWindowlessApp
        return (true, unphantomed)
    }

    /// **Focusing a window proves it is real.** The CGS verdict is only recomputed on a show, and lands a
    /// beat after the switcher appears, so a stale "phantom" latch outlives the moment the window actually
    /// came to the front: an Electron app reopened from the Dock stayed flagged until some later show
    /// happened to re-read it. Summoning the switcher in that gap hid the very window the user had just
    /// focused, which both spawned a windowless placeholder for its app and pushed the default selection one
    /// window too far (#5849).
    ///
    /// This is genuine evidence, not a guess, so it clears the latch exactly as a Space delta does — the
    /// #5714 "never clears a phantom" invariant governs the SYNCHRONOUS re-derivation, not new evidence.
    /// Returns whether a real window just un-phantomed, so the caller can drop the stale placeholder.
    mutating func clearPhantomOnFocus(_ wid: CGWindowID) -> Bool {
        guard let i = windowIndex(wid) else { return false }
        let wasPhantom = isPhantom(windows[i])
        windows[i].cgsPhantomLatch = false
        return wasPhantom && !isPhantom(windows[i]) && !windows[i].isWindowlessApp
    }
}

/// One window's WindowServer-owned facts as a WS query returns them (`WsRawWindow`, decoded) — the payload
/// of a `windowServerStateRead` input.
struct WsWindowSnapshot: Equatable {
    var wid: CGWindowID
    var position: CGPoint
    var size: CGSize
    var isFullscreen: Bool
    var isVisible: Bool
    /// The WindowServer's own minimized bit (`WsWindowState.minimizedTag`). Defaulted so fixtures that
    /// don't care keep building snapshots as before. Prompt on the way in, LATE on the way out — the reducer
    /// applies the staleness rule, not the caller.
    var isMinimized: Bool = false
}

/// One step of the orchestration: a WindowServer event, an async read RESULT landing (AX attributes /
/// discovery / WS state / the Spaces re-query / an AX liveness probe), or a timer check firing. Each case
/// carries exactly the OS-reported payload plus the ambient facts the live handler read at that instant
/// (uptime, app-active, in-Space-transition) — so a recorded debug log can be transcribed input by input.
enum ReducerInput: Equatable {
    // WindowServer events (raw ids in `WsEventRouting.Notification`)
    case windowCreated(wid: CGWindowID, now: TimeInterval, inSpaceTransition: Bool)          // 811
    case windowDestroyed(wid: CGWindowID)                                                    // 804
    case windowMovedOrResized(wid: CGWindowID, inSpaceTransition: Bool)                      // 806/807
    case windowOrderedIn(wid: CGWindowID, now: TimeInterval, inSpaceTransition: Bool)        // 815
    case windowOrderedOut(wid: CGWindowID, inSpaceTransition: Bool)                          // 816
    case windowFocused(wid: CGWindowID, now: TimeInterval)                                   // 808
    case spaceMembershipChanged(wid: CGWindowID, spaceId: UInt64, added: Bool,
                                now: TimeInterval, inSpaceTransition: Bool)                  // 1325/1326
    case spaceTransitionStarted                                                              // 1329/1401, leading edge
    case spaceChangeSettled                                                                  // 1329/1401, debounced
    /// NSWorkspace didActivateApplication (no WS equivalent). `altTabTargetWid` = a fresh AltTab-initiated
    /// focus of this app, when known.
    case appActivated(pid: pid_t, now: TimeInterval, altTabTargetWid: CGWindowID?)

    // async read results landing
    /// The apply-side of `Applications.addDiscoveredWindow`: acquisition + discrimination ran in the shell;
    /// `accepted` is whether a window was (or already is) tracked for the wid, `newlyTracked` whether this
    /// call appended it (`findOrCreate.1`). The shell has already applied the raw AX/WS attributes and
    /// appended the window to the snapshot; the reducer owns the decisions that follow.
    case discoveryLanded(wid: CGWindowID, accepted: Bool, newlyTracked: Bool,
                         adoptedAsInactiveTab: Bool, queriedSpaceIds: [UInt64], tabTitles: [String]?)
    /// The apply-side of `Applications.refreshWindowTitleAndTabs` (title/main already applied by the shell;
    /// `changedSoFar` = whether they changed): the reducer owns the tab reconcile. Carries NO minimized
    /// fact — that comes from the WindowServer query now (`WsWindowState.minimizedTag`).
    case titleAndTabsRead(wid: CGWindowID, tabTitles: [String]?, reconcileTabs: Bool, changedSoFar: Bool)
    /// A batched WS state query landed (`Applications.updateWindowStatesViaWindowServer`).
    case windowServerStateRead([WsWindowSnapshot])
    /// The off-main Spaces re-query landed (`Applications.syncSpacesState`): the authoritative per-window
    /// Space map, plus whether the topology snapshot changed anything.
    case spacesSynced(windowToSpaces: [CGWindowID: [UInt64]], topologyChanged: Bool)
    /// An AX `kAXFocusedWindow` read landed — the two focus signals that arrive as a READ rather than as a
    /// WindowServer event. `viaActivationBackstop`: an activation that emitted no 808
    /// (`WindowServerEvents.bumpFocusOnActivation`), else a window discovered while its app was already
    /// frontmost (`Window.checkIfFocused`). The two differ only in their gate.
    case axFocusedWindowRead(wid: CGWindowID, viaActivationBackstop: Bool)
    /// The AX probes after an order-out agreed the window is gone: dead cached element AND the app no longer
    /// lists the wid (`Applications.removeIfClosedAfterOrderOut`).
    case livenessConfirmedDead(wid: CGWindowID)
    /// The two CGS window lists the rescan fetched (visible excludes the `.invisible1/.invisible2` tags,
    /// all includes them) — the phantom-detection pass (`Applications.applyPhantomVerdict`).
    case cgsWindowListsRead(visible: Set<CGWindowID>, all: Set<CGWindowID>)
    /// Screen stacking, top-most first, from the blocking CGS query the very first summon fires off-main
    /// (`Windows.sortByLevel`). The order to fall back on for windows AltTab has never seen focused.
    case zOrderRead(widsTopFirst: [CGWindowID])

    // timer checks firing
    case holdReleaseCheck(wid: CGWindowID, attempt: Int)                                     // `checkHoldRelease`
    case dragOutCheck(wid: CGWindowID, previousRepWid: CGWindowID, attempt: Int)             // `checkDragOut`
}

/// A request the reducer makes of the shell — every side effect the orchestration used to fire inline.
/// The shell executes them verbatim (same calls, same coalescing/throttling), so moving a decision into
/// the reducer never changes WHAT happens, only WHERE it's decided.
enum ReducerEffect: Equatable {
    /// acquire + discriminate a possibly-new wid (`Applications.discoverWindow`). `throttled` = coalesce
    /// per wid (the 0×0-at-create re-discovery path, `windowAttributesThrottler` key "wid-N-discover").
    case discoverWindow(wid: CGWindowID, throttled: Bool)
    /// AX-probe a just-ordered-out window; feeds back `livenessConfirmedDead` only when the app also stopped
    /// listing the wid (`removeIfClosedAfterOrderOut`)
    case probeWindowLiveness(CGWindowID)
    /// per-window AX read of title/main/minimized (+ tabs); feeds back `titleAndTabsRead`
    /// (`Applications.refreshWindowTitleAndTabs`)
    case readTitleAndTabs(wid: CGWindowID, readTabs: Bool)
    /// batched WS geometry/fullscreen query; feeds back `windowServerStateRead`
    /// (`Applications.updateWindowStatesViaWindowServer`). `throttled` = coalesce per wid (the resize-drag
    /// path, ≤1 query/200ms, `windowAttributesThrottler` key "wid-N-wsstate").
    case queryWindowServerState(wids: [CGWindowID], throttled: Bool)
    /// brute-force an app for inactive-tab windows (`Applications.discoverInactiveTabs`). `requesterWid` is
    /// the window whose AXTabGroup named the missing titles — the scan needs it to reject a candidate that is
    /// plainly another window's tab (`BruteForceWindowMatch.isPlausibleInactiveTab`).
    case discoverInactiveTabs(pid: pid_t, untrackedTitles: [String], requesterWid: CGWindowID)
    /// set `application.focusedWindow`, re-check shortcut disabling, capture the frontmost in background —
    /// the trio every focus-bump site fires
    case applyFocus(CGWindowID)
    /// `App.refreshOpenUiAfterExternalEvent(wids)`; some call sites fire only while the switcher is open
    case refreshUi(wids: [CGWindowID], onlyWhileSwitcherOpen: Bool)
    /// remove the window from the live model (`Windows.removeWindows`, view/scheduler/subscription cleanup)
    case removeWindow(CGWindowID)
    /// copy a sibling's thumbnail onto a freshly-active representative (the app-icon-gap placeholder)
    case copyThumbnail(from: CGWindowID, to: CGWindowID)
    /// hold every capture of this window until its restore animation is over, then take one
    /// (`WindowThumbnails.deferCaptureUntilRestoreEnds`)
    case deferCaptureUntilRestoreEnds(wid: CGWindowID)
    /// re-arm the hold-release re-check (`checkHoldRelease`'s 0.4s timer)
    case scheduleHoldReleaseCheck(wid: CGWindowID, attempt: Int)
    /// re-arm the drag-out re-check (`checkDragOut`'s 0.4s timer)
    case scheduleDragOutCheck(wid: CGWindowID, previousRepWid: CGWindowID, attempt: Int)
    /// re-read the Space topology alone (`Spaces.refresh` — one CGS round-trip, 0.1ms p50), so the switcher
    /// filters and sorts against the Space being ARRIVED on. Fires on the leading edge of a transition.
    case refreshSpacesTopology
    /// refresh Space topology + per-window membership after a Space change settles (`Spaces.refresh` +
    /// `Applications.syncSpacesState`); feeds back `spacesSynced`
    case refreshSpacesTopologyAndSync
    /// re-derive `screenId` from the window's fresh `spaceIds` (`Window.updateScreenId` — an
    /// `NSScreen`-coupled read the reducer can't do)
    case updateScreenId(CGWindowID)
    /// a real window just un-phantomed — drop its app's stale windowless icon placeholder
    /// (`Window.dropStaleWindowlessPlaceholderIfUnphantomed`)
    case removeWindowlessPlaceholder(pid: pid_t)
    /// the opposite edge: an app's last real window just turned phantom, so the app needs its windowless icon
    /// placeholder NOW (`Application.addWindowlessWindowIfNeeded`, which re-checks the predicate)
    case addWindowlessPlaceholder(pid: pid_t)
    /// an activation emitted no 808 — read the front app's focused window from AX and bump it
    /// (`WindowServerEvents.bumpFocusOnActivation`, the weak-signal backstop)
    case bumpFocusViaAxBackstop(pid: pid_t)
    /// re-check shortcut disabling for the frontmost app's focused window (after a Space change settles)
    case checkShortcutsForFocusedWindow
    /// One fact about what this input decided. The shell JOINS every one an input produced into a single
    /// debug line prefixed by the input (`TrackedWindowStateBridge.dispatch`), so the log reads one line per
    /// OS event rather than five; the replay harness records them individually as the step's trace.
    case log(String)
}
