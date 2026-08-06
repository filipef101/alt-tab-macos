import Cocoa
import ApplicationServices

class Applications {
    static var list = [Application]()
    static var frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
    // Throttlers coalesce redundant work. They are SEPARATE from AXCallScheduler, which is a pure executor
    // (bounded pools + retry, no throttle). Each one below states what it coalesces and why:
    // A — suppress redundant inbound events: coalesce resize/move/title bursts to ≤1 attribute read per window
    static let windowAttributesThrottler = ThrottlerWithKey(delayInMs: 200)
    // B — suppress redundant recompute: ≤1 full window-inventory scan per second (on switcher show)
    static let fullRescanThrottler = Throttler(delayInMs: 1000)
    // B — ≤1 Dock-badge fetch per second
    static let dockBadgeThrottler = Throttler(delayInMs: 1000)
    // C — cap a resource: ≤1 thumbnail capture per window per 200ms
    static let screenshotThrottler = ThrottlerWithKey(delayInMs: 200)
    /// Wids whose close the OS confirmed twice (`removeIfClosedAfterOrderOut`) while CGS still lists them.
    /// CGS keeps a closed wid in its all-Space list for seconds, and some apps (Slack) keep handing back a
    /// live `AXWindow` element for it by brute-force, so the inventory sweep re-acquired the corpse it had
    /// just removed — the window came back for one summon, was flagged phantom on the next, and only then got
    /// its app's placeholder (#5849). Suppresses the SWEEP only; see `refreshWindowsViaWindowServer`.
    static var widsConfirmedClosed = Set<CGWindowID>()

    static func initialDiscovery() {
        addInitialRunningApplications()
        RunningApplicationsEvents.observe()
    }

    static func addInitialRunningApplications() {
        addRunningApplications(NSWorkspace.shared.runningApplications, false)
    }

    static func manuallyRefreshAllWindows() {
        fullRescanThrottler.throttleOrProceed {
            Logger.debug { "manuallyRefreshAllWindows" }
            syncSpacesState()
            refreshWindowsViaWindowServer()
            reviewExistingWindows()
            discardDeadPhantomWindows()
        }
    }

    /// Discard "zombie" windows so they can't accumulate. Window removal is normally driven by the per-window
    /// destroy event (804), which is reliable for windows we're subscribed to. But our discovery is async — a
    /// window seen in the SLS snapshot can die in the gap before we subscribe to it, so its 804 fires before
    /// we're listening and never removes it; it lingers flagged phantom (empty spaceIds) and would otherwise
    /// pile up forever, holding a Window + a stale subscription each. So on each refresh, reconcile ONLY the
    /// windows currently flagged phantom (the accumulation candidates — usually none) against authoritative
    /// OS existence, and drop the ones the OS confirms gone. Alive-but-phantom windows (a real window briefly
    /// between Spaces, or Slack's empty-spaceIds case #5791) still exist, so they're kept and stay correctly
    /// hidden. Bails on query failure — never discard on incomplete data. (yabai sidesteps this race by
    /// observing a window synchronously at create; our discovery is async, so this is the cheap, scoped
    /// backstop — it checks the suspicious few, not the whole list.)
    static func discardDeadPhantomWindows() {
        let phantomWids = Windows.list.compactMap { $0.isPhantom ? $0.cgWindowId : nil }
        guard !phantomWids.isEmpty else { return }
        CGSCallScheduler.existingWindowIds(among: phantomWids) { alive in
            guard let alive else { return } // query failed; don't discard on incomplete data
            let dead = Windows.list.filter { $0.isPhantom && ($0.cgWindowId.map { !alive.contains($0) } ?? false) }
            guard !dead.isEmpty else { return }
            Logger.debug { "remove phantomSweep count=\(dead.count) \(dead.map { $0.debugId })" }
            Windows.removeWindows(dead, true)
            // CGS itself says these wids no longer exist, so unlike every other removal there is nothing left
            // to come back; drop the opt-in `removeWindows` deliberately keeps.
            dead.compactMap { $0.cgWindowId }.forEach { WindowServerEvents.unsubscribe($0) }
        }
    }

    /// Refresh Space topology + per-window Space/screen membership via SkyLight, OFF the main thread, then
    /// reconcile the open switcher only if something moved. This is the per-summon Space refresh that used
    /// to block `Windows.updatesBeforeShowing` (#5721) — relocated here (runs ~0.25s after show, throttled),
    /// and first so its correction lands before the best-effort window passes. Mirrors `refreshIsPhantom`'s
    /// capture-on-main → query-off-main → apply-on-main pattern.
    static func syncSpacesState() {
        let mainScreenUuid = Spaces.mainScreenUuid()
        let trackedWids = Windows.list.compactMap { $0.cgWindowId }
        CGSCallScheduler.run {
            let snapshot = Spaces.query(mainScreenUuid, includeWindowMap: true)
            // #5791: the inverted per-Space enumeration can miss a window (e.g. Slack), leaving it absent from
            // the map → empty spaceIds → flagged phantom → hidden ("No Window"). Backfill any tracked wid the
            // map missed with a per-window CGSCopySpacesForWindows (off-main; only the misses pay, usually none).
            var windowToSpacesMap = snapshot.windowToSpacesMap
            var backfillProbe = [String]()
            for wid in trackedWids where windowToSpacesMap[wid] == nil {
                let spaces = CGSCallScheduler.windowSpaces(wid)
                // What this per-window query answers for a BACKGROUNDED TAB decides whether the re-query can
                // ever strip a group of its claim — the rec24 vanish. `sp[]` means the enumeration and the
                // per-window query agree the tab is nowhere; a non-empty answer means the tab keeps a stale
                // Space and the group is never wiped. Logged because the test model has to assume one.
                backfillProbe.append("#\(wid)→\(spaces)")
                if !spaces.isEmpty { windowToSpacesMap[wid] = spaces }
            }
            Logger.debug { "spacesSync enumerated=\(snapshot.windowToSpacesMap.count)/\(trackedWids.count) "
                + "perWindowProbe=[\(backfillProbe.joined(separator: " "))]" }
            DispatchQueue.main.async {
                // apply the topology first (the reducer's snapshot must see the fresh Space⇄index map),
                // then the per-window backfill + regroup is the reducer's `.spacesSynced` branch
                let topologyChanged = Spaces.applyTopology(snapshot)
                TrackedWindowStateBridge.dispatch(.spacesSynced(windowToSpaces: windowToSpacesMap,
                    topologyChanged: topologyChanged))
            }
        }
    }

    /// Window discovery: take the all-Space wid set from the WindowServer and ACQUIRE an AX element for each
    /// genuinely-new app-level window (via `WindowElementAcquisition`), then discriminate it with WS-owned
    /// facts (geometry/level/fullscreen/minimized from the snapshot) + a light AX read (subrole/role/title/
    /// tabs). Already-tracked windows are skipped — events keep their geometry live, reviewExistingWindows their title/tabs.
    static func refreshWindowsViaWindowServer() {
        // the all-Space wid list comes from ONE CGSCopyWindowsWithOptionsAndTags call over every Space
        // (verified to match the per-Space fan-out), not a second windowToSpacesMap rebuild — syncSpacesState
        // owns the per-window membership map; here we only need the wid set.
        let allSpaceIds = Spaces.idsAndIndexes.map { $0.0 }
        guard !allSpaceIds.isEmpty else { return }
        CGSCallScheduler.run {
            let allSpaceWids = CGSCallScheduler.windowsInSpaces(allSpaceIds, true)
            // phantom detection reuses this same all-Space fetch (was a separate per-show CGS double-query
            // that also ran on the AX pool): a wid CGS omits from "visible" but keeps in "all" is alive-but-hidden.
            let visibleWids = Set(CGSCallScheduler.windowsInSpaces(allSpaceIds, false))
            let allWids = Set(allSpaceWids)
            let appWindows = WindowServerQuery.query(allSpaceWids).filter { WsWindowState.isApplicationWindowLevel($0) }
            DispatchQueue.main.async {
                // Drain the confirmed-closed tombstones against the two lists we just fetched, BEFORE they
                // gate anything: a wid CGS lists as visible again is genuinely back (a reopened window is
                // untagged, wherever its Space), and a wid CGS finally forgot is gone for good. What's left is
                // exactly the corpse case — closed, yet still lingering in the all-Space list. No clock
                // involved, and no event-driven path is gated: an order-in / focus for the wid reaches
                // `discoverWindow` as it always did.
                widsConfirmedClosed.formIntersection(allWids)
                widsConfirmedClosed.subtract(visibleWids)
                // Same reconcile for the opt-in dedup set: this enumeration is the only place that sees which
                // wids still exist, and destroy events don't erase reliably. Before the loop below, so a
                // pruned wid that IS still app-level is re-subscribed in this very pass.
                WindowServerEvents.pruneSubscriptions(allWids)
                for raw in appWindows {
                    // Opt in BEFORE the acquisition can reject it: subscribing costs nothing and commits to
                    // nothing, and a wid we skip here is one whose later re-show we cannot hear (see
                    // `WindowServerEvents.subscribe`).
                    WindowServerEvents.subscribe(raw.wid)
                    // This enumeration is the authority on level, so it also clears a stale "not an
                    // application window" verdict — the recovery path for a window re-leveled after creation,
                    // or one whose destroy event never came before its number was reused.
                    WindowServerEvents.noteApplicationLevel(raw.wid)
                    guard let app = findOrCreate(raw.pid, false) else { continue }
                    // tracked windows with a live element stay fresh via the WS event stream
                    // (geometry/min/fullscreen) + reviewExistingWindows (title/tabs); discovery only ACQUIRES
                    // genuinely-new windows.
                    guard Windows.byWindowId[raw.wid]?.axUiElement == nil else { continue }
                    guard !widsConfirmedClosed.contains(raw.wid) else { continue }
                    AXCallScheduler.shared.schedule(key: "wid-\(raw.wid)-acquire", context: app.debugId, pid: raw.pid, scan: true) {
                        if let element = WindowDiscriminator.acquireElementOrReject(raw.wid, raw.pid, .otherSpaceViaBruteForce) {
                            addDiscoveredWindow(element, raw, app)
                        }
                    }
                }
                // regular apps with no windows show as an icon placeholder. It's dropped when a real window
                // arrives (Window.init) or when an existing window un-phantoms (Window.updateSpaces), so a
                // window that recovers its Space after a fullscreen transition clears the stale placeholder
                // instead of leaving both the window tile and the icon tile shown.
                for app in list { _ = app.addWindowlessWindowIfNeeded() }
                // phantom detection reuses this same all-Space fetch; the per-window verdicts + latches are
                // the reducer's `.cgsWindowListsRead` branch
                TrackedWindowStateBridge.dispatch(.cgsWindowListsRead(visible: visibleWids, all: allWids))
            }
        }
    }

    /// Acquire-and-discriminate a newly-discovered window. WindowServer-owned facts (geometry, level,
    /// fullscreen) come from the snapshot `raw`; AX is read for what WS can't give cleanly — subrole/role
    /// (discrimination), title (AX title is preferred), the main flag, minimized (the WS ordered-out bit is
    /// ambiguous — see below), and tab children.
    /// Used for genuinely-new windows only (discovery + discoverWindow). Uses the "generic" bucket so a real
    /// focus event (in the "focus" bucket) is never clobbered.
    /// `adoptedAsInactiveTab`: this window was found by the inactive-tab brute-force (`discoverInactiveTabs`)
    /// — we already KNOW it's a background tab, so the per-window Space query must not be trusted for it: it
    /// returns the STALE old Space for a backgrounded tab (the same lie behind the #5830 burst fix), which
    /// made a cold-start adoption flood arrive as visible "on-screen" windows that the tab matcher was then
    /// forbidden to claim — a switcher full of ghost tiles that only the NEXT show's re-query healed (rec15).
    /// Forced Space-less, it arrives hidden like any unclaimed background tab, and the group converges below.
    static func addDiscoveredWindow(_ element: AXUIElement, _ raw: WsRawWindow, _ app: Application,
                                    adoptedAsInactiveTab: Bool = false) {
        let wid = raw.wid
        AXCallScheduler.shared.schedule(key: "wid-\(wid)-generic", context: app.debugId, pid: app.pid, scan: true) { [weak app] in
            guard let app else { return }
            guard wid != 0 else { return }
            // TilesPanel.shared is nil until the switcher is first built; discovery can now run before that
            // (a window created right at launch), so don't force-unwrap it. If the panel exists and this is
            // its own window, skip it; otherwise it can't be ours, so proceed.
            if let panel = TilesPanel.shared, wid == panel.windowNumber { return }
            let isSelf = app.pid == AXUIElement.currentProcessPid
            // minimized comes from AX (kAXMinimized) — a reliable, unambiguous signal — NOT the WS ordered-out
            // bit, which is also cleared for closing / app-hidden / other-Space windows. (yabai sources
            // minimize from AX the same way: seed kAXMinimized, then track miniaturize/deminiaturize.)
            let keys = [kAXTitleAttribute, kAXSubroleAttribute, kAXRoleAttribute, kAXMainAttribute] + (isSelf ? [] : [kAXChildrenAttribute])
            let a = try element.attributes(keys, pid: app.pid)
            let tabSiblingTitles = isSelf ? nil : TabGroup.extractTabTitles(a.children)
            let isFullscreen = WsWindowState.isFullscreen(raw)
            // Both from the SAME WindowServer snapshot this discovery already holds. Minimized used to be an
            // AX `kAXMinimized` read in the batch above; it is a WindowServer tag now, so it cannot be
            // delayed by the app being busy, and one fewer attribute crosses the AX boundary per window.
            let isMinimized = WsWindowState.isMinimized(raw)
            // Resolve the window's REAL Space(s) now, off-main. Window.init defaults spaceIds to the current
            // Space (it runs on main and must avoid this blocking CGS call, #5721); for an other-Space window
            // that default is wrong, and the first post-show syncSpacesState would then correct it → a visible
            // reflow on the first summon (misaligned space numbers / shifted title). Setting it right here makes
            // that later correction a no-op. Skipped for an adopted inactive tab: the query lies for those
            // (stale old Space), and a background tab's true membership is NO Space.
            let spaceIds = (isSelf || adoptedAsInactiveTab) ? [CGSSpaceID]() : CGSCallScheduler.windowSpaces(wid)
            DispatchQueue.main.async { [weak app] in
                guard let app else { return }
                windowAttributesThrottler.throttleOrProceed(key: "\(wid)-generic") {
                    // The shell's job ends at acquisition + raw-fact ingestion: findOrCreate applies the AX/WS
                    // attributes (and appends a genuinely-new window). Everything decided AFTER that — the
                    // pending-removal consume, the MRU promotion, the Space override for background tabs, the
                    // tab-state update, the reconcile — is the reducer's `.discoveryLanded` branch. A REJECTED
                    // window still dispatches, so the reducer's pending-removal marker stays self-draining.
                    let findOrCreate = Windows.findOrCreate(element, wid, app, CGWindowLevel(raw.level), a.title, a.subrole, a.role, raw.bounds.size, raw.bounds.origin, isFullscreen, isMinimized)
                    // not logged here: the reducer's `.discoveryLanded` line names this window with the facts
                    // that actually matter (tab titles, group, Spaces, whether it was adopted as a tab)
                    findOrCreate.0?.isMainWindow = a.isMain ?? false
                    TrackedWindowStateBridge.dispatch(.discoveryLanded(wid: wid, accepted: findOrCreate.0 != nil,
                        newlyTracked: findOrCreate.1, adoptedAsInactiveTab: adoptedAsInactiveTab,
                        queriedSpaceIds: spaceIds, tabTitles: tabSiblingTitles))
                }
            }
        }
    }

    /// WindowServer-driven per-window state refresh (geometry + fullscreen), replacing the AX attribute read
    /// on move/resize/visibility events and the Space-change fullscreen re-read. ONE batched WS query for the
    /// whole wid set (off-main: ~84µs for a full screen vs ~15µs × N serial), decoded by WsWindowState,
    /// applied on main in a single UI reconcile. Minimized IS read here (`WsWindowState.minimizedTag`) —
    /// the ordered-out BIT cannot tell minimized from closing/other-Space, but the tag can, and unlike the AX
    /// read it replaced it cannot be delayed by the window's own app. Callers coalesce upstream where the
    /// input self-floods: the per-event path
    /// throttles per-wid (windowAttributesThrottler, ≤1 query/200ms on a resize drag); the Space-change path
    /// calls this once per transition.
    static func updateWindowStatesViaWindowServer(_ wids: [CGWindowID]) {
        guard !wids.isEmpty else { return }
        CGSCallScheduler.run {
            let raws = WindowServerQuery.query(wids)
            guard !raws.isEmpty else { return }
            // decode off-main; the apply (geometry writes, regroup, re-render/re-capture decisions) is the
            // reducer's `.windowServerStateRead` branch
            let snapshots = raws.map {
                WsWindowSnapshot(wid: $0.wid, position: $0.bounds.origin, size: $0.bounds.size,
                    isFullscreen: WsWindowState.isFullscreen($0), isVisible: WsWindowState.isVisible($0),
                    isMinimized: WsWindowState.isMinimized($0))
            }
            DispatchQueue.main.async {
                TrackedWindowStateBridge.dispatch(.windowServerStateRead(snapshots))
            }
        }
    }

    /// A tracked window just ordered out (left the screen): it was either CLOSED, or merely minimized / hidden
    /// / moved to another Space. WindowServer can't disambiguate promptly — its destroy event (804) lags a real
    /// close by seconds, or never fires at all, for apps that retain the CGWindow after closing the window
    /// (Finder does). The window's AX element, by contrast, dies within ~20ms of a real close. So probe AX off
    /// -main: a live element means it's just off-screen → leave it. `.cannotComplete` (app busy) throws so the
    /// scheduler retries with backoff instead of wrongly concluding the window closed.
    ///
    /// A dead element (`.invalidUIElement`) is NOT proof of a close on its own: some apps silently rebuild a
    /// window's a11y node, which kills our cached ref while the window lives on (#5586, and the same rebind is
    /// why `Window.focus` retries a raise). So take a second opinion before condemning — ask the app for the
    /// wid again, exactly as discovery would. Measured on macOS 26 (TextEdit): closing a window drops its wid
    /// from `kAXWindows` at once (CGS keeps listing it for seconds), while minimize and app-hide both keep it
    /// there with a still-valid ref. Not found ⇒ really closed ⇒ remove now (prompt, OS-confirmed, NOT
    /// optimistic); found ⇒ our ref was merely stale ⇒ heal it and keep the window.
    ///
    /// Condemning on the weaker test than the one that re-adds the window is what made a live QQ window
    /// disappear and come back seconds later as a "new" window with no MRU history (#5785).
    static func removeIfClosedAfterOrderOut(_ window: Window) {
        guard let axWindow = window.axUiElement, let wid = window.cgWindowId else { return }
        let pid = window.application.pid
        AXCallScheduler.shared.schedule(key: "wid-\(wid)-liveness", pid: pid) {
            let result = axWindow.liveness(pid: pid)
            if result == .cannotComplete { throw AxError.runtimeError }
            guard result == .invalidUIElement else {
                Logger.debug { "liveness #\(wid) result=\(result.rawValue) verdict=alive" }
                return
            }
            // Only the cheap `kAXWindows` route: the brute-force one is time-budgeted, so on an app with
            // high AXUIElementIDs it can time out on a window that IS there and hand back the same false
            // "closed" this guard exists to prevent.
            let fresh = WindowElementAcquisition.element(for: wid, pid: pid, route: .currentSpaceViaApplicationWindows)
            // Log all three verdicts: a capture where a window vanished needs to show whether this probe ran
            // at all and what it answered.
            Logger.debug { "liveness #\(wid) result=\(result.rawValue) verdict=\(fresh == nil ? "DEAD" : "staleRef")" }
            DispatchQueue.main.async {
                guard let fresh else {
                    // Remember the verdict, or the inventory sweep re-acquires this very wid a beat later:
                    // CGS keeps listing it and the app can still hand back an element for it (see
                    // `widsConfirmedClosed`).
                    widsConfirmedClosed.insert(wid)
                    TrackedWindowStateBridge.dispatch(.livenessConfirmedDead(wid: wid))
                    return
                }
                Windows.byWindowId[wid]?.rebindAxElement(fresh)
            }
        }
    }

    /// A focus event (808) hit a wid we don't track yet — its create event was missed or is in-flight.
    /// Discover just that one window (it's on the current Space, since it was focused) instead of a full
    /// inventory. `Window.init`'s `checkIfFocused` then bumps its MRU order.
    static func discoverWindow(_ wid: CGWindowID) {
        CGSCallScheduler.run {
            guard let raw = WindowServerQuery.query([wid]).first else { return }
            guard WindowDiscriminator.isApplicationWindow(raw) else {
                // Menu, tooltip, Dock indicator. Remember the level verdict so this wid's next move / order-in
                // costs nothing at all: no snapshot, no reducer pass, no repeat of this very query.
                DispatchQueue.main.async { WindowServerEvents.noteNotApplicationLevel(wid) }
                return
            }
            DispatchQueue.main.async {
                // Opt in HERE, not on the raw 811: the level is only known once the query above answers, and
                // subscribing before it put every menu, tooltip and Dock indicator on our per-window stream.
                //
                // The cost is a gap: this wid's per-window events are unheard between its create and this
                // line. MEASURED on macOS 26.5, 25 rapid create/destroy cycles with the WindowServer driven
                // to ~99% CPU by 8 window-list hammers — gap p50 7.2ms, p99 12.7ms, and the WindowServer's
                // first per-window event for a brand-new window never arrived before 7.1ms. A/B against a
                // build that subscribed on the 811 instead: same 54 first-events, same 7.0ms floor, same
                // distribution (p50 34ms), same 49 windows accepted. Nothing measurable is lost in the gap.
                // Re-run that A/B before assuming it still holds on a new macOS.
                //
                // It is also survivable by construction: everything discovery reads next (geometry,
                // minimized, fullscreen, Spaces, title) is read fresh right here, and the one signal that is
                // NOT re-read, a focus 808, is compensated by `recentlyCreated` fronting a new window anyway.
                // Deliberately before the guards below — a window AX rejects must stay subscribed (#5785).
                WindowServerEvents.subscribe(wid)
                guard Windows.byWindowId[wid] == nil, let app = findOrCreate(raw.pid, false) else { return }
                AXCallScheduler.shared.schedule(key: "wid-\(wid)-acquire", context: app.debugId, pid: raw.pid, scan: true) {
                    if let element = WindowDiscriminator.acquireElementOrReject(wid, raw.pid, .currentSpaceViaApplicationWindows) {
                        addDiscoveredWindow(element, raw, app)
                    }
                }
            }
        }
    }

    // ≤1 inactive-tab brute-force scan per app per 3s, a frequency cap on top of the per-situation budget below.
    static let tabAdoptThrottler = ThrottlerWithKey(delayInMs: 3000)
    // The last unresolved situation (untracked-tab titles + window count) we scanned for, per app, and how many
    // FRUITLESS attempts it has spent. An inactive tab the brute-force can't resolve would otherwise re-fire the
    // scan on every show forever, so each situation gets a small budget (`InactiveTabScanPolicy`), and the app
    // becomes fully eligible again the moment its window set changes (a tab gets adopted, opened, or closed —
    // any of which moves the count or the titles).
    static var lastInactiveTabScan = [pid_t: (situation: String, attempts: Int)]()
    // Where each app's last brute-force sweep stopped. The budget is wall-clock and the AXUIElementID space is
    // UInt64, so one attempt covers a WINDOW of ids, not the space — restarting at 0 made every retry inspect
    // exactly the ids that had already failed, which is why 31 scans in a row adopted nothing while an earlier
    // run (whose windows happened to sit lower) adopted 57. Cleared on a productive scan: the ids around a
    // successful find are the live region, so the next question starts there rather than out in the desert.
    static var inactiveTabScanCursor = [pid_t: AXUIElementID]()

    /// Discover an app's INACTIVE OS TABS. A tabbed window's inactive tabs are real windows, but they appear in
    /// no CGS list, so the WindowServer-driven discovery never sees them — only the focused tab shows until the
    /// user activates another. When an AXTabGroup names tabs we have no window for (`untrackedTitles`), the
    /// inactive tab's accessibility element is still reachable: brute-force the app for the matching untracked
    /// standard windows and adopt them through the normal discovery path. Throttled per app, off-main, bounded.
    ///
    /// The situation and the exclusion set are read INSIDE the throttled block, deliberately. The throttler runs
    /// the leading call now and defers the next one by up to 3s, running the block captured at THAT call — so
    /// values snapshotted out here are up to 3s stale by the time the scan uses them, which meant excluding a
    /// set of tracked wids that no longer matched the model and recording a situation the app had already left.
    /// An attempt should act on, and be recorded against, the facts as they are when it runs.
    static func discoverInactiveTabs(_ app: Application, _ untrackedTitles: [String], _ requesterWid: CGWindowID) {
        let pid = app.pid
        tabAdoptThrottler.throttleOrProceed(key: "\(pid)") {
            let appWindowCount = Windows.list.reduce(0) { $1.application.pid == pid ? $0 + 1 : $0 }
            let situation = "\(untrackedTitles.sorted().joined(separator: "\u{1}"))|\(appWindowCount)"
            let previous = lastInactiveTabScan[pid]
            guard InactiveTabScanPolicy.shouldScan(recordedSituation: previous?.situation,
                                                   attempts: previous?.attempts ?? 0, situation: situation) else { return }
            let trackedWids = Set(Windows.list.compactMap { $0.cgWindowId })
            // ANCHOR the sweep near the app's OWN known elements instead of at id 0 — the decision that
            // actually made this scan work (`InactiveTabScanPolicy.scanStart`). `AXUIElement.id()` reads an
            // element's own id, so a window we already track names the band this app's windows live in.
            let knownIds = Windows.list.filter { $0.application.pid == pid }.compactMap { $0.axUiElement?.id() }
            let startId = InactiveTabScanPolicy.scanStart(cursor: inactiveTabScanCursor[pid],
                                                          lowestKnownId: knownIds.min())
            // Where this app's other windows sit, so a candidate parked on one of them can be recognised as
            // ITS tab rather than the requester's — see `BruteForceWindowMatch.isPlausibleInactiveTab`.
            let requesterFrame = Windows.byWindowId[requesterWid]?.position.map { CGRect(origin: $0, size: .zero) }
            let otherFrames = Windows.list.filter { $0.application.pid == pid && $0.cgWindowId != requesterWid }
                .compactMap { $0.position.map { p in CGRect(origin: p, size: .zero) } }
            // `isPlausibleInactiveTab` waves everything through when the requester has no frame or the app has
            // no other windows, so both inputs are logged: without them a green run cannot be told apart from
            // a gate that is wired up but inert.
            Logger.debug { "inactive-tab scan pid:\(pid) knownIds=\(knownIds.sorted().prefix(6)) from=\(startId) requester=#\(requesterWid)@\(requesterFrame?.origin.debugDescription ?? "nil") others=\(otherFrames.map { $0.origin })" }
            AXCallScheduler.shared.schedule(key: "pid-\(pid)-tabadopt", context: app.debugId, pid: pid, scan: true) { [weak app] in
                guard let app else { return }
                let (found, nextId) = AXUIElement.untrackedWindowsByBruteForce(
                    pid, excluding: trackedWids, matching: untrackedTitles, from: startId)
                var adopted = 0
                for (wid, element, title) in found {
                    guard let raw = WindowServerQuery.query([wid]).first else {
                        Logger.debug { "inactive tab wid:\(wid) '\(title)' has no WindowServer data; skipping" }
                        continue
                    }
                    // An inactive tab is BEHIND the active one, so the WindowServer does not have it on
                    // screen. A candidate it does have on screen is a window in its own right that merely
                    // shares a title with one of this app's tabs — which is not rare at all, because the
                    // titles we match on are tab titles, and two Finder windows browsing the same folder
                    // both have a tab called "lwouis". Adopting one swallowed a real, visible, FOCUSED
                    // window into another window's group: it stopped being drawn (a non-representative
                    // member is hidden), so the switcher silently lost a window and the default pick
                    // landed one tile past where the user was aiming.
                    //
                    // Title matching cannot tell the two apart (#5785: tab titles are not window titles,
                    // and no reliable tab->window mapping exists), so the on-screen bit is what separates
                    // them. A missed adoption is cheap — the next scan retries — while a wrong one hides a
                    // window the user is looking at.
                    guard !WsWindowState.isVisible(raw) else {
                        Logger.debug { "inactive tab candidate wid:\(wid) '\(title)' is ON SCREEN, so it is a window of its own, not a tab of this one; skipping" }
                        continue
                    }
                    guard BruteForceWindowMatch.isPlausibleInactiveTab(
                        candidate: raw.bounds, requester: requesterFrame, otherWindowsOfApp: otherFrames) else {
                        Logger.debug { "inactive tab candidate wid:\(wid) '\(title)' sits at \(raw.bounds.origin), on another window of this app rather than on #\(requesterWid); it is that window's tab, skipping" }
                        continue
                    }
                    Logger.debug { "discovered inactive tab via brute-force: wid:\(wid) '\(title)' at \(raw.bounds.origin) for #\(requesterWid)" }
                    adopted += 1
                    addDiscoveredWindow(element, raw, app, adoptedAsInactiveTab: true)
                }
                // Record the OUTCOME, not the intent: a fruitless attempt spends one of the situation's budget,
                // a productive one spends none. Recording before the scan is what gave up forever on a single
                // transient miss (the app's AX tree not ready yet at launch).
                let attempts = InactiveTabScanPolicy.attemptsAfterScan(previousAttempts: previous?.attempts ?? 0,
                    sameSituation: previous?.situation == situation, adopted: adopted)
                if adopted == 0 {
                    Logger.debug { "inactive-tab scan found nothing (attempt \(attempts)/\(InactiveTabScanPolicy.maxAttemptsPerSituation), ids \(startId)..<\(nextId))" }
                }
                DispatchQueue.main.async {
                    lastInactiveTabScan[pid] = (situation, attempts)
                    inactiveTabScanCursor[pid] = adopted > 0 ? 0 : nextId
                }
            }
        }
    }

    /// Light per-window AX read for already-tracked windows: the facts the WindowServer genuinely cannot
    /// deliver — title (no WS title-change event), the main-window flag, and tab siblings. Minimized is NOT
    /// among them any more: it is `WsWindowState.minimizedTag`, read from the WS query instead.
    /// Shares the "wid-N-generic" dedup/throttle key so it never double-reads a window the discovery pass
    /// just refreshed. Runs for every tracked window on each show.
    static func refreshWindowTitleAndTabs(_ axWindow: AXUIElement, _ wid: CGWindowID, _ app: Application, _ reconcileTabs: Bool = true) {
        AXCallScheduler.shared.schedule(key: "wid-\(wid)-generic", context: app.debugId, pid: app.pid, scan: true) { [weak app] in
            guard let app else { return }
            guard wid != 0 else { return }
            // TilesPanel.shared is nil until the switcher is first built; discovery can now run before that
            // (a window created right at launch), so don't force-unwrap it. If the panel exists and this is
            // its own window, skip it; otherwise it can't be ours, so proceed.
            if let panel = TilesPanel.shared, wid == panel.windowNumber { return }
            let isSelf = app.pid == AXUIElement.currentProcessPid
            // Skip the tab-group read when the caller says not to reconcile tabs (an order-out): an
            // ordered-out window reports its AXTabGroup inconsistently mid-transition, and order-out never
            // changes tab membership anyway. Saves the kAXChildren IPC too.
            let readTabs = !isSelf && reconcileTabs
            let keys = [kAXTitleAttribute, kAXMainAttribute] + (readTabs ? [kAXChildrenAttribute] : [])
            let a = try axWindow.attributes(keys, pid: app.pid)
            let tabSiblingTitles = readTabs ? TabGroup.extractTabTitles(a.children) : nil
            DispatchQueue.main.async {
                windowAttributesThrottler.throttleOrProceed(key: "\(wid)-generic") {
                    guard let window = Windows.byWindowId[wid] else { return }
                    // raw-fact ingestion stays here (bestEffortTitle needs the CG-title fallback IPC); the
                    // tab reconcile + re-render decision is the reducer's `.titleAndTabsRead` branch
                    let newTitle = window.bestEffortTitle(a.title)
                    let changed = window.title != newTitle
                    if changed { window.title = newTitle; window.lastSearchQuery = nil }
                    window.isMainWindow = a.isMain ?? false
                    TrackedWindowStateBridge.dispatch(.titleAndTabsRead(wid: wid, tabTitles: tabSiblingTitles,
                        reconcileTabs: reconcileTabs, changedSoFar: changed))
                }
            }
        }
    }

    /// Re-read the AX-only facts WindowServer can't deliver, for all tracked windows, in case events were
    /// incomplete: title, the main-window flag, and tab siblings. Geometry/fullscreen/minimized are
    /// WindowServer-maintained (806/807 + the tags), so those are NOT re-read or overwritten here.
    static func reviewExistingWindows() {
        for window in Windows.list {
            guard !window.isWindowlessApp,
                  let axUiElement = window.axUiElement,
                  let wid = window.cgWindowId else { continue }
            refreshWindowTitleAndTabs(axUiElement, wid, window.application)
        }
    }

    static func addRunningApplications(_ runningApps: [NSRunningApplication], _ needToVerifyFrontmostPid: Bool) {
        runningApps.forEach { runningApp in
            let bundleIdentifier = runningApp.bundleIdentifier
            let processIdentifier = runningApp.processIdentifier
            if bundleIdentifier == "com.apple.dock" {
                DockEvents.observe(processIdentifier)
            }
            // com.apple.universalcontrol always fails subscribeToNotification. We blacklist it to save resources on everyone's machines
            guard bundleIdentifier != "com.apple.universalcontrol" else { return }
            // classify off-main (process & sysctl IPC), then create on main if it's a real app (#5721).
            // findOrCreate stays synchronous for the rarer AX-event new-pid path (it re-checks the list).
            ProcessCallScheduler.isActualApplication(processIdentifier, bundleIdentifier) { isActual in
                if isActual { createActualApp(runningApp) }
            }
        }
    }

    // The post-classification half of findOrCreate, for the discovery path where classification already
    // ran off-main via ProcessCallScheduler. Runs on main; dedups by pid so it can't race a parallel creation.
    private static func createActualApp(_ runningApp: NSRunningApplication) {
        let pid = runningApp.processIdentifier
        guard !(list.contains { $0.pid == pid }) else { return }
        list.append(Application(runningApp))
    }

    static func removeRunningApplications(_ terminatingApps: [NSRunningApplication]) {
        let existingAppsToRemove = list.filter { app in terminatingApps.contains { tApp in app.runningApplication.isEqual(tApp) } }
        let existingWindowstoRemove = Windows.list.filter { window in terminatingApps.contains { tApp in window.application.runningApplication.isEqual(tApp) } }
        if existingAppsToRemove.isEmpty && existingWindowstoRemove.isEmpty { return }
        for tApp in terminatingApps {
            let ofQuitApp = Windows.list.filter { $0.application.runningApplication.isEqual(tApp) }
            if !ofQuitApp.isEmpty { Logger.debug { "remove appQuit count=\(ofQuitApp.count) \(ofQuitApp.map { $0.debugId })" } }
            Windows.removeWindows(ofQuitApp, false)
            // comparing pid here can fail here, as it can be already nil; we use isEqual here to avoid the issue
            list.removeAll { $0.runningApplication.isEqual(tApp) }
        }
        for tApp in terminatingApps {
            let pid = tApp.processIdentifier
            AXCallScheduler.shared.removeEntry(key: "pid-\(pid)")
            AXCallScheduler.shared.removeEntries(withPrefix: "pid-\(pid)-")
            AXCallScheduler.shared.removeUnresponsivePid(pid)
        }
        App.refreshOpenUiAfterExternalEvent([])
    }

    static func refreshBadgesAsync() {
        guard SwitcherSession.isActive else { return }
        dockBadgeThrottler.throttleOrProceed {
            let dockPid = list.first { $0.bundleIdentifier == "com.apple.dock" }?.pid
            AXCallScheduler.shared.schedule(key: "badges", context: "badges", pid: dockPid) {
                guard let dockPid,
                    let axDockChildren = try AXUIElementCreateApplication(dockPid).attributes([kAXChildrenAttribute]).children,
                    let axListAttrs = (axDockChildren.lazy.compactMap { try? $0.attributes([kAXRoleAttribute, kAXChildrenAttribute]) }.first { $0.role == kAXListRole }),
                    let axListChildren = axListAttrs.children else { return }
                let axAppDockItemUrlAndLabel: [(URL?, String?)] = try axListChildren.compactMap {
                    let a = try $0.attributes([kAXSubroleAttribute, kAXIsApplicationRunningAttribute, kAXURLAttribute, kAXStatusLabelAttribute])
                    guard a.subrole == kAXApplicationDockItemSubrole && (a.appIsRunning ?? false) else { return nil }
                    return (a.url, a.statusLabel)
                }
                guard !axAppDockItemUrlAndLabel.isEmpty else { return }
                DispatchQueue.main.async {
                    guard SwitcherSession.isActive else { return }
                    refreshBadges_(axAppDockItemUrlAndLabel)
                }
            }
        }
    }

    static func refreshBadges_(_ items: [(URL?, String?)]) {
        Windows.list.enumerated().forEach { (i, window) in
            let view = TilesView.recycledViews[i]
            if let app = findOrCreate(window.application.pid, false) {
                if app.runningApplication.activationPolicy == .regular,
                   let matchingItem = (items.first { $0.0 == app.bundleURL }),
                   let label = matchingItem.1 {
                    app.dockLabel = label
                    view.updateDockLabelIcon(label)
                } else {
                    app.dockLabel = nil
                    assignIfDifferent(&view.dockLabelIcon.isHidden, true)
                }
            }
        }
    }

    @discardableResult
    static func findOrCreate(_ pid: pid_t, _ needToVerifyFrontmostPid: Bool) -> Application? {
        if let app = (list.first { $0.pid == pid }) {
            return app
        }
        guard let runningApp = NSRunningApplication(processIdentifier: pid) else {
            Logger.debug { "NSRunningApplication init failed for pid:\(pid)" }
            return nil
        }
        guard ApplicationDiscriminator.isActualApplication(pid, runningApp.bundleIdentifier) else {
            return nil
        }
        let app = Application(runningApp)
        list.append(app)
        return app
    }

    static func updateAppIcons() {
        for app in list {
            BackgroundWork.screenshotsQueue.addOperation { [weak app] in
                guard let app else { return }
                let r = Application.appIconWithoutPadding(app.runningApplication.icon)
                DispatchQueue.main.async { [weak app] in
                    app?.icon = r?.image
                    app?.iconSourcePixels = r?.sourcePixels
                }
            }
        }
    }
}
