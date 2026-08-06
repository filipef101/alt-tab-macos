import Cocoa

/// The WindowServer event tap: AltTab's source of truth for window lifecycle, focus, geometry and Space
/// membership. Window state comes from SkyLight's notify-proc stream — immune to a busy or AX-lying app
/// (e.g. Electron throwing away its AX tree) — instead of Accessibility notifications. See
/// `SkyLight.framework.swift` for the underlying calls and `windowserver/` for the pure decision layer
/// (routing, decode, acquisition). AX is kept only for on-demand reads (subrole/title/tabs) and the actions.
class WindowServerEvents {
    /// The wids opted in for per-window delivery (mandatory since Sequoia). Order in/out, focus, and the
    /// removal side of the model all depend on it: a wid absent here is one we are deaf to.
    ///
    /// Two things measured on macOS 26.5 shape everything below. Create/destroy (811/804) and the Space
    /// notifications are connection-wide, but only once the connection has opted at least one window in:
    /// with every `SLSRequestNotificationsForWindows` call skipped, not even 811 arrived. And the call
    /// REPLACES this list rather than adding to it, so the request must always carry the whole set and
    /// removing a wid from it is a real unsubscribe (see `requestNotifications` and `pruneSubscriptions`).
    ///
    /// Grown by `subscribe`, from the inventory sweep and from discovery, both of which opt in only once the
    /// WindowServer has confirmed application window level. Chrome (menus, tooltips, Dock indicators) is
    /// therefore never subscribed. The price is that a brand-new window is unheard between its create and
    /// its level query answering; `Applications.discoverWindow` documents that gap and its measurement.
    private static var wsWindows = Set<CGWindowID>()
    /// Wids the WindowServer told us are NOT at application window level: menus, tooltips, notification
    /// banners, the Dock's `StatusIndicator` layers. Chrome is never subscribed, but its creates and moves
    /// reach us anyway (those are connection-wide), and each one used to cost a hop to main, a full model
    /// snapshot, and a repeat WindowServer query that could only reach the verdict we already had —
    /// measured on macOS 26, one Dock reveal re-queried the same wid six times in 14s. Remembering the
    /// verdict here is what makes a piece of chrome cost one query in its whole life, after which
    /// `notifyProc` drops its events before they cost anything.
    ///
    /// Wids are RECYCLED, so an entry must not outlive the window it describes. Both lifecycle edges clear
    /// it: `windowDestroyed` (the OS confirming the number is free) and `windowCreated` (the number handed
    /// out again, whether or not we saw the destroy). Only the LEVEL verdict is remembered — a WindowServer
    /// fact about this window. The AX rejection is deliberately NOT: that one is transient by design (#5785).
    ///
    /// Read from the WindowServer's own thread in `notifyProc` and written from main, hence the lock.
    private static let notApplicationLevel = ConcurrentMap<CGWindowID, Bool>()
    private static var started = false

    /// The cadence the shell re-arms the reducer's re-checks on (hold-release, drag-out). The reducer owns the
    /// attempt CAPS (`WindowEventReducer.holdReleaseMaxAttempts` / `dragOutMaxAttempts`); the wall-clock
    /// backstop is `cap × this`, so changing this silently rescales those caps — keep the two in view together.
    static let recheckInterval: TimeInterval = 0.4
    /// Space switches emit storms of transient animation/snapshot windows; ignore create/destroy briefly
    /// around a Space transition so they aren't mistaken for real windows (RE "transition noise").
    private static var spaceTransitionUntil: TimeInterval = 0
    /// Also read by the switcher's show path, which re-reads the topology while this holds — see
    /// `Windows.updatesBeforeShowing`.
    static var inSpaceTransition: Bool { ProcessInfo.processInfo.systemUptime < spaceTransitionUntil }
    /// debounces the 1329/1401 Space-change burst into one settled handler (replaces SpacesEvents)
    private static var spaceChangeWorkItem: DispatchWorkItem?
    /// The window AltTab itself just focused (switcher selection / CLI --focus), consumed by the next
    /// didActivate of that app: the target is KNOWN, so the activation bumps it directly instead of divining
    /// it from a racy 808 / AX read (see `ActivationFocusResolver.onActivation`). Time-bounded and one-shot.
    private static var altTabInitiatedFocus: ActivationFocusResolver.AltTabFocusIntent?

    /// Whether this focus is worth recording is `ActivationFocusResolver.altTabIntentToRecord`'s decision (it
    /// carries the rationale); the tap only supplies the ambient facts and holds the slot. A focus that isn't
    /// worth recording leaves any pending intent alone — that one's activation may still be on its way.
    static func noteAltTabInitiatedFocus(_ wid: CGWindowID, _ pid: pid_t) {
        if let intent = ActivationFocusResolver.altTabIntentToRecord(
            wid: wid, pid: pid, frontmostPid: Applications.frontmostPid,
            at: ProcessInfo.processInfo.systemUptime) {
            altTabInitiatedFocus = intent
        }
    }

    static func observe() {
        guard !started else { return }
        started = true
        // Register our notify procs on the (AppKit-shared) main connection. The per-window opt-in is NOT seeded
        // here: `SLSGetOnScreenWindowList` sees only the current Space's on-screen windows, which is a subset
        // of what the inventory sweep enumerates a beat later and misses exactly the windows this opt-in is
        // for (hidden ones that come back). `subscribe` owns the set; see it for why the sweep feeds it.
        // We deliberately DO NOT call `SLSConnectionDispatchNotificationsToMainQueueIfNotMainThread`: on the
        // shared connection it overrode AppKit's own coordinated-notification routing, so AppKit's
        // `activeSpaceChanged:` / appearance handlers started firing inline on the `_NSEventThread` (whichever
        // thread snarfs the datagram), crashing on their main-thread-only AppKit work. Our `notifyProc` hops to
        // main itself, so we don't need that call — letting AppKit keep its main-thread delivery.
        for n in WsEventRouting.Notification.allCases {
            SLSRegisterConnectionNotifyProc(CGS_CONNECTION, notifyProc, n.rawValue, nil)
        }
        Logger.info { "WindowServerEvents: tap installed on cid \(CGS_CONNECTION)" }
        // app activation + hidden state have no WindowServer equivalent (they're AppKit concepts) — NSWorkspace
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            if let app = runningApp(note) {
                let pid = app.processIdentifier
                Applications.frontmostPid = pid
                // Re-evaluate the "ignore shortcuts" exception the moment an app becomes frontmost, whatever
                // happens to the window MRU below (#5842). The window-focus paths also call this, but they only
                // fire once a window is resolved and bumped — an activation that emits no 808 and whose AX
                // focused-window read fails or races (iTerm2 is AX-heavy) would never disable the shortcut, and
                // an app already frontmost when AltTab (re)launches never got a bump at all. This app-activation
                // floor restores the pre-WS-migration guarantee (the `checkIfShortcutsShouldBeDisabled(nil, app)`
                // that closed #5228). `focusedWindow` may be stale/nil; it only feeds the `.whenFullscreen` rule,
                // and the app itself is what the `.always` rule keys off.
                if let frontmostApp = Applications.findOrCreate(pid, false) {
                    App.checkIfShortcutsShouldBeDisabled(frontmostApp.focusedWindow, frontmostApp)
                }
                // The activation decisions — which windows the 808 storm may raise, whether an
                // AltTab-initiated target bumps directly, when the AX backstop runs — live in
                // `WindowEventReducer.appActivated` (+ `ActivationFocusResolver`); the timing/consume of the
                // one-shot AltTab-initiated intent stays here (it's this tap's own bookkeeping).
                let now = ProcessInfo.processInfo.systemUptime
                var knownTarget: CGWindowID? = nil
                if ActivationFocusResolver.altTabIntentApplies(altTabInitiatedFocus, activatedPid: pid, now: now) {
                    knownTarget = altTabInitiatedFocus?.wid
                    altTabInitiatedFocus = nil
                }
                TrackedWindowStateBridge.dispatch(.appActivated(pid: pid, now: now, altTabTargetWid: knownTarget))
            }
        }
        center.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main) { note in
            if let app = runningApp(note) { applicationVisibilityChanged(app.processIdentifier, hidden: true) }
        }
        center.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main) { note in
            if let app = runningApp(note) { applicationVisibilityChanged(app.processIdentifier, hidden: false) }
        }
    }

    /// Non-capturing C callback. The WindowServer calls it on whichever thread snarfs the datagram (often the
    /// `_NSEventThread`, since we don't route this connection's notifications to the main queue — that broke
    /// AppKit's own coordinated handlers). The payload pointer is only valid for this call, so extract the
    /// integers synchronously, then hop to main ourselves before touching the model.
    private static let notifyProc: CGSConnectionNotifyProc = { event, data, len, _, _ in
        // Stamp the ARRIVAL, not the processing: the hop to main can queue behind our own work (a show, a
        // capture), which stretches the apparent gap between two events the WindowServer emitted in the same
        // instant. Every timing decision downstream — above all how long an activation's raise burst is
        // considered in flight — is only as good as this stamp.
        let at = ProcessInfo.processInfo.systemUptime
        var w0: UInt32 = 0, w8: UInt32 = 0
        var s0: UInt64 = 0
        if let d = data, len >= 4 { memcpy(&w0, d, 4) }
        if let d = data, len >= 8 { memcpy(&s0, d, 8) }
        if let d = data, len >= 12 { memcpy(&w8, d.advanced(by: 8), 4) }
        // Chrome we already judged is dropped HERE, not on main: the hop is the expensive part of a chrome
        // event (a block enqueue plus a main-thread wake-up), and a menu or a Dock indicator has nothing to
        // tell us. Create and destroy are exempt — they are what keeps the verdict honest across recycling.
        if let n = WsEventRouting.notification(event), isKnownNonApplicationWindow(n, w0, w8) { return }
        if Thread.isMainThread {
            handle(event, w0, s0, w8, at)
        } else {
            DispatchQueue.main.async { handle(event, w0, s0, w8, at) }
        }
    }

    private static func handle(_ event: UInt32, _ w0: UInt32, _ space: UInt64, _ widInSpace: UInt32,
                              _ at: TimeInterval) {
        guard let n = WsEventRouting.notification(event) else { return }
        switch n {
        case .activeSpaceChanged, .spaceCurrentChanged:
            // The same clock that mutes the transition's window storm also names the burst's LEADING edge:
            // "not already in a transition" is the first 1329/1401 of this switch. That edge gets the cheap
            // half of the reaction (`WindowEventReducer.spaceTransitionStarted`); `route` below debounces
            // the expensive half to the trailing edge, as it always has.
            let isLeadingEdge = !inSpaceTransition
            spaceTransitionUntil = ProcessInfo.processInfo.systemUptime + 0.5
            if isLeadingEdge { TrackedWindowStateBridge.dispatch(.spaceTransitionStarted) }
        case .windowCreated:
            // the brand-new / lastCreated bookkeeping lives in the reducer (`.windowCreated`); the tap keeps
            // the opt-in and the recycling edge — this number is now a DIFFERENT window than the one any
            // remembered verdict was about, so the verdict goes before the subscription arrives.
            clearLevelVerdict(w0)
            // Forget the corpse: `wsWindows` is a dedup set, and `windowDestroyed` often never comes for a
            // window that closed (an app that retains its CGWindow — measured: 90 creates, 0 destroys over a
            // churn run), so the number may still be in it from the PREVIOUS window. Now that requests carry
            // only the delta, a dedup hit would mean never asking for THIS window: deaf to it for its whole
            // life. The full-array resend used to hide this. The subscription itself is sent by discovery,
            // once the level is known.
            wsWindows.remove(w0)
        case .windowDestroyed:
            clearLevelVerdict(w0)
            unsubscribe(w0)
        case .windowOrderedIn:
            // Our own panel's orderedIn is the true "pixels on screen" moment — it can trail the show's
            // main-thread work by ~500ms while the WindowServer settles a Space transition. Anchor the
            // key-repeat grace to it (see `SwitcherSession.panelBecameVisibleAt`).
            if let session = SwitcherSession.current, session.panelBecameVisibleAt == nil,
               let panel = TilesPanel.shared, panel.windowNumber > 0, w0 == CGWindowID(panel.windowNumber) {
                session.panelBecameVisibleAt = ProcessInfo.processInfo.systemUptime
            }
        default:
            break
        }
        // The raw notification is NOT logged here. Every one of them routes to the reducer, which logs the
        // input plus everything it decided as a single line (`TrackedWindowStateBridge.dispatch`), so a line
        // here just doubled every event — and that duplication is what made `--logs=debug` the firehose a
        // second log channel was invented to escape. The one notification that reaches no reducer input is
        // the Space transition, which is debounced; it logs below.
        route(n, w0, space, widInSpace, at)
    }

    /// A per-window event for a wid already judged not-an-application-window. Everything downstream would
    /// end in the rejection it ended in last time, so this is the whole cost skipped: the model snapshot in
    /// `TrackedWindowStateBridge.dispatch`, the reducer pass, and discovery's WindowServer re-query.
    /// Create and destroy are exempt — they are what keeps the verdict honest across wid recycling — and so
    /// is the Space transition, which carries no wid of its own.
    private static func isKnownNonApplicationWindow(_ n: WsEventRouting.Notification, _ w0: CGWindowID,
                                                    _ widInSpace: CGWindowID) -> Bool {
        switch WsEventRouting.action(for: n) {
            case .acquireAndDiscriminate, .remove, .spaceTransition: return false
            case .updateSpaceMembership: return notApplicationLevel.withLock { $0[widInSpace] != nil }
            case .updateGeometry, .refreshVisibility, .bumpFocusOrder:
                return notApplicationLevel.withLock { $0[w0] != nil }
        }
    }

    /// Discovery found this wid is not at application window level (`WindowDiscriminator.isApplicationWindow`).
    static func noteNotApplicationLevel(_ wid: CGWindowID) {
        notApplicationLevel.withLock {
            // A window CAN be re-leveled after creation (SLSSetWindowLevel) and no event says so. This cap and
            // the sweep's `noteApplicationLevel` are the two ways an entry leaves without its window dying, so
            // the worst case is a re-query, never a window we stay deaf to for the session.
            if $0.count > 2048 { $0.removeAll(keepingCapacity: true) }
            $0[wid] = true
        }
    }

    /// The inventory sweep enumerated this wid AT application level. Clears any stale verdict, which is what
    /// makes a re-leveled window (or one whose destroy we never saw) recoverable at the next switcher show.
    static func noteApplicationLevel(_ wid: CGWindowID) {
        clearLevelVerdict(wid)
    }

    private static func clearLevelVerdict(_ wid: CGWindowID) {
        notApplicationLevel.withLock { $0.removeValue(forKey: wid) }
    }

    /// Turn a WindowServer notification into a `ReducerInput` and dispatch it through the reducer — which owns
    /// every decision this switch used to make inline (`WindowEventReducer.reduce`). Window events key off
    /// `w0` (the wid); Space-membership events (1325/1326) key off `widInSpace`/`space` from the payload.
    /// Runs on main.
    private static func route(_ n: WsEventRouting.Notification, _ w0: CGWindowID, _ space: CGSSpaceID,
                              _ widInSpace: CGWindowID, _ now: TimeInterval) {
        switch WsEventRouting.action(for: n) {
        case .bumpFocusOrder:
            TrackedWindowStateBridge.dispatch(.windowFocused(wid: w0, now: now))
        case .remove:
            TrackedWindowStateBridge.dispatch(.windowDestroyed(wid: w0))
        case .updateGeometry, .refreshVisibility:
            if n == .windowOrderedOut {
                TrackedWindowStateBridge.dispatch(.windowOrderedOut(wid: w0, inSpaceTransition: inSpaceTransition))
            } else if n == .windowOrderedIn {
                TrackedWindowStateBridge.dispatch(.windowOrderedIn(wid: w0, now: now, inSpaceTransition: inSpaceTransition))
            } else {
                TrackedWindowStateBridge.dispatch(.windowMovedOrResized(wid: w0, inSpaceTransition: inSpaceTransition))
            }
        case .updateSpaceMembership:
            TrackedWindowStateBridge.dispatch(.spaceMembershipChanged(wid: widInSpace, spaceId: space,
                added: n == .windowAddedToSpace, now: now, inSpaceTransition: inSpaceTransition))
        case .acquireAndDiscriminate:
            TrackedWindowStateBridge.dispatch(.windowCreated(wid: w0, now: now, inSpaceTransition: inSpaceTransition))
        case .spaceTransition:
            // 1329/1401 fire during the transition (manuallyRefreshAllWindows above stays muted ~0.5s to
            // ignore the create/destroy storm). Debounce, then refresh topology + reconcile once it settles.
            // The half of that reaction a summon can't wait 250ms for already ran on the leading edge, in
            // `handle` above.
            Logger.debug { "WS \(n) space=\(space)" }
            scheduleSpaceChangeHandling()
        }
    }

    /// Arm the hold-release re-check (the reducer's `scheduleHoldReleaseCheck` effect): the shell owns the
    /// timer (`recheckInterval`), the reducer owns the release decision (`.holdReleaseCheck`). Re-checking rather than
    /// waiting a fixed delay is what makes the hold last exactly as long as a discovery is actually pending
    /// — a hardcoded delay expired mid-gap on a slow/busy OS and the tile vanished anyway.
    static func armHoldReleaseCheck(_ wid: CGWindowID, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + recheckInterval) {
            TrackedWindowStateBridge.dispatch(.holdReleaseCheck(wid: wid, attempt: attempt))
        }
    }

    /// Arm the drag-out re-check (the reducer's `scheduleDragOutCheck` effect), mirroring the hold-release
    /// split: shell timer, reducer verdict (`.dragOutCheck`).
    static func armDragOutCheck(_ wid: CGWindowID, previousRepWid: CGWindowID, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + recheckInterval) {
            TrackedWindowStateBridge.dispatch(.dragOutCheck(wid: wid, previousRepWid: previousRepWid, attempt: attempt))
        }
    }

    /// AppKit app-activation is the backstop for a window-focus (808) that never arrives (808 and
    /// NSRunningApplication.isActive are separate clocks; some activations emit no 808 at all). Read the
    /// now-front app's focused window from AX and bump the MRU, same as a focus event would. Mirrors yabai's
    /// APPLICATION_FRONT_SWITCHED handler. This is the WEAK signal: the AX read races the app's internal focus
    /// update and can return the PREVIOUS window (iTerm, #5596), so it YIELDS to the activation's first 808
    /// (`focusBumped`) — decided at apply time on main by the reducer's `.axFocusedWindowRead`, since the read
    /// is async and can land after the 808. The shell's job here ends at the READ: the gate and the bump (and
    /// with it the phantom-latch clear every focus arrival owes, #5849) belong to the one focus path.
    static func bumpFocusOnActivation(_ pid: pid_t) {
        guard let app = Applications.findOrCreate(pid, false), let appAx = app.axUiElement else { return }
        AXCallScheduler.shared.schedule(key: "pid-\(pid)-activation-focus", pid: pid) {
            // Our own windows (e.g. Preferences) are tracked like any app's, so self activation gets the same MRU
            // bump; both AX reads here go through the pid-aware guards so the own-process ones run on main.
            guard let focused = try? appAx.attributes([kAXFocusedWindowAttribute], pid: pid).focusedWindow,
                  let wid = try? focused.cgWindowId(pid: pid) else { return }
            DispatchQueue.main.async {
                TrackedWindowStateBridge.dispatch(.axFocusedWindowRead(wid: wid, viaActivationBackstop: true))
            }
        }
    }

    /// 1329/1401 can fire several times during one Space transition; debounce so the topology refresh + UI
    /// reconcile run once, after it settles. The settled reaction (topology refresh + Space re-sync +
    /// fullscreen re-read + shortcut re-check + UI reconcile) is the reducer's `.spaceChangeSettled` branch.
    private static func scheduleSpaceChangeHandling() {
        spaceChangeWorkItem?.cancel()
        let work = DispatchWorkItem { TrackedWindowStateBridge.dispatch(.spaceChangeSettled) }
        spaceChangeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private static func runningApp(_ note: Notification) -> NSRunningApplication? {
        note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }

    /// Replaces AX's kAXApplicationHidden/Shown: "hidden" is an AppKit state the WindowServer doesn't own.
    private static func applicationVisibilityChanged(_ pid: pid_t, hidden: Bool) {
        guard let app = Applications.list.first(where: { $0.pid == pid }) else { return }
        app.isHidden = hidden
        App.refreshOpenUiAfterExternalEvent(Windows.list.filter { $0.application.pid == pid })
    }

    private static func requestNotifications() {
        var list = Array(wsWindows)
        guard !list.isEmpty else { return }
        // The WHOLE set goes out every time, not the delta. `SLSRequestNotificationsForWindows` REPLACES this
        // connection's watch list; it does not add to it. Sending only the new wids left exactly one window
        // watched and every previously-watched one deaf: measured over a QA run, 0 order-outs, 0 destroys and
        // 0 focus events arrived (vs 91 / 143 / 51 for the same tests with the full array), while the
        // connection-wide creates/moves kept coming, so the app looked alive and simply never removed a
        // closed window, never noticed a minimize, and never updated the MRU.
        SLSRequestNotificationsForWindows(CGS_CONNECTION, &list, Int32(list.count))
        // How many wids we can hear from at all. A window missing from the switcher with no event trail in a
        // capture is either not enumerated or not opted in; this separates the two.
        Logger.debug { "opted in to \(list.count) windows" }
    }

    /// Opt the WindowServer into per-window notifications for a wid. Called for EVERY app-level wid the
    /// inventory sweep enumerates, not only the ones we end up tracking: an app that hides its window instead
    /// of closing it (Electron: QQ, WeChat, Notion, Slack) also tears down its a11y tree, so the sweep can
    /// acquire no element and rejects the window — and if rejection also meant "unsubscribed", the re-show
    /// would be silent (it emits no `windowCreated`; the per-window events are the ONLY signal it is back) and
    /// the window stayed invisible until the next switcher-show sweep, seconds later (#5785). Subscribing is a
    /// WindowServer fact (CGS lists this wid at an app window level); being tracked is an AX one. Coalesced so
    /// a sweep sends one request.
    ///
    /// "App-level" is a precondition, not a formality: both callers gate on it (the sweep filters its
    /// enumeration, `Applications.discoverWindow` runs `isApplicationWindow` first). Subscribing before that
    /// verdict is what put every menu, tooltip and Dock indicator on this connection's per-window stream.
    static func subscribe(_ wid: CGWindowID) {
        guard wsWindows.insert(wid).inserted else { return }
        scheduleRequestNotifications()
    }

    /// Drop a wid from the opt-in set. Only for a wid the OS confirmed gone: the destroy event (804), or the
    /// phantom sweep's CGS existence check. Our own model removals never unsubscribe — see `subscribe`.
    /// Dropping IS the unsubscribe, since the next request carries the set as it stands and the call
    /// replaces the watch list; SkyLight exports no explicit counterpart (re-checked with `dyld_info
    /// -exports` on macOS 26.5: no `SLSRemoveNotificationsForWindows` / `SLSStopNotificationsForWindows`).
    /// No request is sent from here: a dead window has nothing left to tell us, and the next real
    /// subscribe carries the shortened set anyway.
    static func unsubscribe(_ wid: CGWindowID) {
        wsWindows.remove(wid)
    }

    /// Drop from the dedup set every wid the WindowServer no longer lists, called with the inventory sweep's
    /// all-Space enumeration. `windowDestroyed` is not a reliable eraser (an app that retains its CGWindow
    /// closes a window without one), so without this the set is the size of the session's HISTORY rather than
    /// of its current windows.
    ///
    /// Dropping a wid here is a real unsubscribe, not just bookkeeping: the next request carries the set as
    /// it stands, and the call replaces the watch list. So the enumeration alone must NOT decide — a window
    /// it happens to miss (an inactive tab, an other-Space window CGS omits, #1324) would go silently deaf,
    /// which is the same failure the delta request caused. Anything still in the model is kept whatever the
    /// enumeration says; what's left to drop is a wid that is neither listed by the OS nor tracked by us.
    static func pruneSubscriptions(_ alive: Set<CGWindowID>) {
        let before = wsWindows.count
        let tracked = Set(Windows.list.compactMap { $0.cgWindowId })
        wsWindows.formIntersection(alive.union(tracked))
        let dropped = before - wsWindows.count
        if dropped > 0 { Logger.debug { "pruned \(dropped) dead subscriptions (\(wsWindows.count) left)" } }
    }

    private static var requestNotificationsPending = false
    /// Coalesce re-requests to once per main-runloop tick — a discovery pass appends many windows at once.
    private static func scheduleRequestNotifications() {
        guard !requestNotificationsPending else { return }
        requestNotificationsPending = true
        DispatchQueue.main.async {
            requestNotificationsPending = false
            requestNotifications()
        }
    }
}
