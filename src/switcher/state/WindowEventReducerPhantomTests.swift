import XCTest

/// Pins the EFFECTS the reducer emits when the CGS phantom pass (`cgsWindowListsRead`) flips a window's
/// derived phantom. Drives `WindowEventReducer.reduce` directly and inspects the returned effects, because
/// `.removeWindowlessPlaceholder` is display-side: the replay harness deliberately swallows it, so a
/// scenario replay cannot observe it. See WindowEventReducerPhantomSpecs.md.
final class WindowEventReducerPhantomTests: XCTestCase {

    private static let slackPid: pid_t = 89789
    private static let slackWid: CGWindowID = 140743
    private static let otherPid: pid_t = 1471
    private static let otherWid: CGWindowID = 194

    /// Slack's real window, on the current Space, latched phantom by an earlier CGS pass.
    private func slackWindow(latchedPhantom: Bool = true, lastFocusOrder: Int = 0) -> TrackedWindow {
        TrackedWindow(id: "wid-\(Self.slackWid)", wid: Self.slackWid, pid: Self.slackPid, title: "Slack",
            size: CGSize(width: 2056, height: 1204), position: CGPoint(x: 0, y: 40),
            spaceIds: [1], spaceIndexes: [1], isOnAllSpaces: false, spaceIsBorrowed: false,
            isFullscreen: false, isFullscreenMirrored: false, isMinimized: false, isMainWindow: false,
            isWindowlessApp: false, cgsPhantomLatch: latchedPhantom, lastFocusOrder: lastFocusOrder,
            creationOrder: 1, hasThumbnail: true)
    }

    /// Another app's window, so the MRU has somewhere to shift a bump to (`bumpFocus` is a no-op on a
    /// one-window list) and so "not frontmost" has a plausible owner.
    private func otherAppWindow(order: Int) -> TrackedWindow {
        TrackedWindow(id: "wid-\(Self.otherWid)", wid: Self.otherWid, pid: Self.otherPid, title: "Chrome",
            size: CGSize(width: 2056, height: 1204), position: CGPoint(x: 0, y: 40),
            spaceIds: [1], spaceIndexes: [1], isOnAllSpaces: false, spaceIsBorrowed: false,
            isFullscreen: false, isFullscreenMirrored: false, isMinimized: false, isMainWindow: false,
            isWindowlessApp: false, cgsPhantomLatch: false, lastFocusOrder: order,
            creationOrder: 2, hasThumbnail: true)
    }

    private func state(_ windows: [TrackedWindow], appIsActive: Bool = false) -> TrackedWindowState {
        var s = TrackedWindowState()
        s.windows = windows
        s.apps[Self.slackPid] = TrackedApp(
            state: ApplicationState(pid: Self.slackPid, bundleIdentifier: "com.tinyspeck.slackmacgap",
                                    localizedName: "Slack", isHidden: false),
            isActive: appIsActive)
        s.apps[Self.otherPid] = TrackedApp(
            state: ApplicationState(pid: Self.otherPid, bundleIdentifier: "com.google.Chrome",
                                    localizedName: "Google Chrome", isHidden: false),
            isActive: false)
        s.visibleSpaces = [1]
        s.currentSpaceId = 1
        s.spaceIndexById = [1: 1]
        s.frontmostPid = appIsActive ? Self.slackPid : nil
        return s
    }

    private func dropsPlaceholder(_ effects: [ReducerEffect]) -> Bool {
        effects.contains(.removeWindowlessPlaceholder(pid: Self.slackPid))
    }

    // MARK: - A. Un-phantoming drops the app's stale windowless placeholder (#5849)

    /// The captured bug: Slack's window is latched phantom, so its app also carries a windowless
    /// placeholder tile. The CGS pass then sees the window in both lists and clears the verdict. Without
    /// the effect the placeholder survives forever and the app shows TWO tiles ("appears twice in the list
    /// and won't change even if I wait or switch windows").
    func testUnphantomingEmitsRemoveWindowlessPlaceholder() {
        var s = state([slackWindow(latchedPhantom: true)])
        let effects = WindowEventReducer.reduce(&s, .cgsWindowListsRead(
            visible: [Self.slackWid], all: [Self.slackWid]))
        XCTAssertFalse(s.isPhantom(s.windows[0]), "precondition: the verdict must have cleared")
        XCTAssertTrue(dropsPlaceholder(effects))
    }

    /// The reverse flip (real → phantom) must NOT drop a placeholder: the app is becoming windowless, which
    /// is exactly when the placeholder is legitimate.
    func testBecomingPhantomDoesNotEmitRemoveWindowlessPlaceholder() {
        var s = state([slackWindow(latchedPhantom: false)])
        let effects = WindowEventReducer.reduce(&s, .cgsWindowListsRead(visible: [], all: [Self.slackWid]))
        XCTAssertTrue(s.isPhantom(s.windows[0]), "precondition: the weak signal must have flagged it")
        XCTAssertFalse(dropsPlaceholder(effects))
    }

    /// No flip, no effect — a steady-state pass must stay silent, or every CGS read would churn the list.
    func testNoFlipEmitsNothing() {
        var s = state([slackWindow(latchedPhantom: false)])
        let effects = WindowEventReducer.reduce(&s, .cgsWindowListsRead(
            visible: [Self.slackWid], all: [Self.slackWid]))
        XCTAssertFalse(dropsPlaceholder(effects))
    }

    // MARK: - B. The focused window is exempt from the weak signal (#5849)

    /// Slack reopened from the Dock: CGS still tags the window invisible, but it IS the focused window of
    /// the frontmost app. It must not be flagged phantom — otherwise it is hidden while still holding MRU
    /// slot 0, and the switcher's "previously-focused window" default skips a window and lands on the
    /// wrong app.
    func testFocusedWindowSurvivesTheWeakSignal() {
        var s = state([slackWindow(latchedPhantom: false, lastFocusOrder: 0)], appIsActive: true)
        _ = WindowEventReducer.reduce(&s, .cgsWindowListsRead(visible: [], all: [Self.slackWid]))
        XCTAssertFalse(s.isPhantom(s.windows[0]))
    }

    /// Same window, same CGS tagging, but its app is NOT frontmost → the weak signal still applies.
    func testUnfocusedWindowStillFlaggedByTheWeakSignal() {
        var s = state([slackWindow(latchedPhantom: false, lastFocusOrder: 0)], appIsActive: false)
        _ = WindowEventReducer.reduce(&s, .cgsWindowListsRead(visible: [], all: [Self.slackWid]))
        XCTAssertTrue(s.isPhantom(s.windows[0]))
    }

    /// The app is frontmost but this window is not the one in front (MRU slot 3), so it is not the window
    /// the user is looking at and stays subject to the weak signal.
    func testNonFrontWindowOfActiveAppStillFlagged() {
        var s = state([slackWindow(latchedPhantom: false, lastFocusOrder: 3)], appIsActive: true)
        _ = WindowEventReducer.reduce(&s, .cgsWindowListsRead(visible: [], all: [Self.slackWid]))
        XCTAssertTrue(s.isPhantom(s.windows[0]))
    }

    // MARK: - C. Focus clears a stale phantom immediately (#5849)

    /// The gap the CGS pass alone leaves: the verdict is only recomputed on a show, a beat AFTER the
    /// switcher appears. Opening Slack and tapping the shortcut straight away hit the switcher while the
    /// stale latch still hid the window the user had just focused. Focus is proof, so it clears the latch
    /// the moment it happens, without waiting for a pass.
    func testFocusClearsAStalePhantomLatch() {
        var s = state([slackWindow(latchedPhantom: true, lastFocusOrder: 3)], appIsActive: true)
        XCTAssertTrue(s.isPhantom(s.windows[0]), "precondition: latched phantom")
        _ = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.slackWid, now: 10.0))
        XCTAssertFalse(s.isPhantom(s.windows[0]))
    }

    /// Un-phantoming by focus must also drop the placeholder its app grew while it looked windowless —
    /// otherwise the fast path trades the wrong-window bug for the duplicate-tile one.
    func testFocusUnphantomingEmitsRemoveWindowlessPlaceholder() {
        var s = state([slackWindow(latchedPhantom: true, lastFocusOrder: 3)], appIsActive: true)
        let effects = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.slackWid, now: 10.0))
        XCTAssertTrue(dropsPlaceholder(effects))
    }

    /// Focusing an already-real window changes nothing: no spurious placeholder removal on every focus.
    func testFocusingARealWindowEmitsNoPlaceholderRemoval() {
        var s = state([slackWindow(latchedPhantom: false, lastFocusOrder: 3)], appIsActive: true)
        let effects = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.slackWid, now: 10.0))
        XCTAssertFalse(dropsPlaceholder(effects))
    }

    // MARK: - D. Focus that arrives as an AX READ clears it too (#5849, second report)

    /// Reopening Slack from the Dock reaches the front through the ACTIVATION, and that activation emits no
    /// 808 for the window — the AX backstop is the only focus signal. It used to bump the MRU straight from
    /// the shell, so the latch survived: summoning the switcher 130 ms later hid the window the user was
    /// looking at while it held slot 0, and the default pick skipped past the previous window onto a third
    /// app (System Settings, in the capture).
    func testActivationBackstopClearsAStalePhantomLatch() {
        var s = state([slackWindow(latchedPhantom: true, lastFocusOrder: 1), otherAppWindow(order: 0)],
            appIsActive: true)
        XCTAssertTrue(s.isPhantom(s.windows[0]), "precondition: latched phantom")
        let effects = WindowEventReducer.reduce(&s, .axFocusedWindowRead(wid: Self.slackWid,
            viaActivationBackstop: true))
        XCTAssertFalse(s.isPhantom(s.windows[0]))
        XCTAssertEqual(s.window(Self.slackWid)?.lastFocusOrder, 0)
        XCTAssertTrue(dropsPlaceholder(effects))
    }

    /// The backstop is the weak signal: once the activation's own 808 has bumped, the read is stale (it can
    /// name the PREVIOUS window, iTerm/#5596) and must decide nothing at all.
    func testActivationBackstopYieldsToTheActivations808() {
        var s = state([slackWindow(latchedPhantom: true, lastFocusOrder: 1), otherAppWindow(order: 0)],
            appIsActive: true)
        s.carried.pendingActivationRaises[Self.slackPid] = ActivationEntry(wids: [], until: 99, focusBumped: true)
        let effects = WindowEventReducer.reduce(&s, .axFocusedWindowRead(wid: Self.slackWid,
            viaActivationBackstop: true))
        XCTAssertTrue(s.isPhantom(s.windows[0]))
        XCTAssertEqual(s.window(Self.slackWid)?.lastFocusOrder, 1)
        XCTAssertTrue(effects.isEmpty)
    }

    /// A backstop read landing after the user moved on to another app must not front that app's window.
    func testActivationBackstopIgnoresANoLongerFrontmostApp() {
        var s = state([slackWindow(latchedPhantom: true, lastFocusOrder: 1), otherAppWindow(order: 0)],
            appIsActive: true)
        s.frontmostPid = Self.otherPid
        let effects = WindowEventReducer.reduce(&s, .axFocusedWindowRead(wid: Self.slackWid,
            viaActivationBackstop: true))
        XCTAssertEqual(s.window(Self.slackWid)?.lastFocusOrder, 1)
        XCTAssertTrue(effects.isEmpty)
    }

    /// The other AX read: a window discovered while its app was already frontmost (cold launch, #5665). Same
    /// clear, same placeholder drop.
    func testCreationSeedClearsAStalePhantomLatch() {
        var s = state([slackWindow(latchedPhantom: true, lastFocusOrder: 1), otherAppWindow(order: 0)],
            appIsActive: true)
        let effects = WindowEventReducer.reduce(&s, .axFocusedWindowRead(wid: Self.slackWid,
            viaActivationBackstop: false))
        XCTAssertFalse(s.isPhantom(s.windows[0]))
        XCTAssertEqual(s.window(Self.slackWid)?.lastFocusOrder, 0)
        XCTAssertTrue(dropsPlaceholder(effects))
    }

    /// `kAXFocusedWindow` answers "which window WOULD take keys", which every app has at all times — so a
    /// read for a BACKGROUND app proves nothing and must not front its window over the one the user is on
    /// (#5785, a re-discovered QQ window offered as "the window you were on before").
    func testCreationSeedIgnoresABackgroundApp() {
        var s = state([slackWindow(latchedPhantom: true, lastFocusOrder: 1), otherAppWindow(order: 0)],
            appIsActive: false)
        let effects = WindowEventReducer.reduce(&s, .axFocusedWindowRead(wid: Self.slackWid,
            viaActivationBackstop: false))
        XCTAssertTrue(s.isPhantom(s.windows[0]))
        XCTAssertEqual(s.window(Self.slackWid)?.lastFocusOrder, 1)
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - E. An app whose last window turns phantom gets its placeholder in the SAME pass (#5849)

    /// The other half of the placeholder's lifecycle, which had no owner: the app is now windowless, so the
    /// icon tile must appear with this verdict. It used to come from the shell's per-app sweep, which runs
    /// BEFORE the verdicts are applied and therefore judged the previous latch — so closing Slack's window
    /// gave three different switchers in three consecutive summons (open window / nothing at all / closed-app
    /// icon).
    func testLastWindowTurningPhantomEmitsAddWindowlessPlaceholder() {
        var s = state([slackWindow(latchedPhantom: false)])
        let effects = WindowEventReducer.reduce(&s, .cgsWindowListsRead(visible: [], all: [Self.slackWid]))
        XCTAssertTrue(s.isPhantom(s.windows[0]), "precondition: the weak signal must have flagged it")
        XCTAssertTrue(effects.contains(.addWindowlessPlaceholder(pid: Self.slackPid)))
    }

    /// One window of several turning phantom leaves the app with something to show, so no placeholder: that
    /// is the duplicate-tile bug in the other direction.
    func testPhantomWithAnotherRealWindowLeftEmitsNoAdd() {
        let secondWid: CGWindowID = Self.slackWid + 1
        var second = slackWindow(latchedPhantom: false, lastFocusOrder: 1)
        second.wid = secondWid
        second.id = "wid-\(secondWid)"
        var s = state([slackWindow(latchedPhantom: false), second])
        let effects = WindowEventReducer.reduce(&s, .cgsWindowListsRead(
            visible: [secondWid], all: [Self.slackWid, secondWid]))
        XCTAssertTrue(s.isPhantom(s.windows[0]), "precondition: only the first window flipped")
        XCTAssertFalse(s.isPhantom(s.windows[1]))
        XCTAssertFalse(effects.contains(.addWindowlessPlaceholder(pid: Self.slackPid)))
    }

    /// Un-phantoming is the opposite edge and must never ADD one.
    func testUnphantomingEmitsNoAdd() {
        var s = state([slackWindow(latchedPhantom: true)])
        let effects = WindowEventReducer.reduce(&s, .cgsWindowListsRead(
            visible: [Self.slackWid], all: [Self.slackWid]))
        XCTAssertFalse(effects.contains(.addWindowlessPlaceholder(pid: Self.slackPid)))
    }
}
