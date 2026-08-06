import XCTest

/// Pins where MRU slot 0 goes when the window holding it is removed
/// (`WindowEventReducer.refrontAfterRemovingTheFocusedWindow`). The captured #5346 sequence is replayed
/// through `TestReducerRunner` because the bug is a sequence, not a single decision; the rule-level
/// scenarios drive `WindowEventReducer.reduce` directly. See WindowEventReducerFocusSpecs.md.
final class WindowEventReducerFocusTests: XCTestCase {

    private static let reaperPid: pid_t = 15690
    private static let finderPid: pid_t = 681
    private static let reaperMainWid: CGWindowID = 4274   // "Country Dance - REAPER v7.78"
    private static let reaperDialogWid: CGWindowID = 4557 // "Insert Multiple Media Items"
    private static let finderWid: CGWindowID = 664        // "Liebesleid"

    private func window(_ wid: CGWindowID, _ pid: pid_t, _ title: String, order: Int,
                        isMinimized: Bool = false) -> TrackedWindow {
        TrackedWindow(id: "wid-\(wid)", wid: wid, pid: pid, title: title,
            size: CGSize(width: 800, height: 600), position: CGPoint(x: 10, y: 10),
            spaceIds: [4], spaceIndexes: [1], isOnAllSpaces: false, spaceIsBorrowed: false,
            isFullscreen: false, isFullscreenMirrored: false, isMinimized: isMinimized, isMainWindow: false,
            isWindowlessApp: false, cgsPhantomLatch: false, lastFocusOrder: order,
            creationOrder: Int(wid), hasThumbnail: true)
    }

    /// Finder frontmost with its window in front, REAPER's main window behind it — the state the capture
    /// starts from (the reporter had just alt-tabbed to Finder to drag the audio files).
    private func state(_ windows: [TrackedWindow], frontmost: pid_t) -> TrackedWindowState {
        var s = TrackedWindowState()
        s.windows = windows
        s.apps[Self.reaperPid] = TrackedApp(state: ApplicationState(pid: Self.reaperPid,
            bundleIdentifier: "com.cockos.reaper", localizedName: "REAPER", isHidden: false),
            isActive: frontmost == Self.reaperPid)
        s.apps[Self.finderPid] = TrackedApp(state: ApplicationState(pid: Self.finderPid,
            bundleIdentifier: "com.apple.finder", localizedName: "Finder", isHidden: false),
            isActive: frontmost == Self.finderPid)
        s.frontmostPid = frontmost
        s.visibleSpaces = [4]
        s.currentSpaceId = 4
        s.spaceIndexById = [4: 1]
        return s
    }

    private func order(_ state: TrackedWindowState, _ wid: CGWindowID) -> Int? {
        state.window(wid)?.lastFocusOrder
    }

    // MARK: - A. The captured #5346 sequence

    /// The reporter's transcribed capture: a dialog opened by a drag (REAPER still in the background) is
    /// discovered and fronted, the click that dismisses it activates REAPER — so the main window's own 808
    /// is swallowed as the activation's raise tail — and then the dialog is removed. Slot 0 must not fall
    /// through to Finder, or every alt-tab lands back on the REAPER window the user is already in.
    func testDialogClosingLeavesTheFrontmostAppInFront() {
        let runner = TestReducerRunner(initial: state([
            window(Self.finderWid, Self.finderPid, "Liebesleid", order: 0),
            window(Self.reaperMainWid, Self.reaperPid, "Country Dance - REAPER v7.78", order: 1),
        ], frontmost: Self.finderPid))
        runner.run(capturedDialogSteps(withActivation: true))
        XCTAssertEqual(order(runner.state, Self.reaperMainWid), 0)
        XCTAssertEqual(order(runner.state, Self.finderWid), 1)
    }

    /// The same sequence minus the activation: the main window's 808 is then an ordinary focus and bumps on
    /// its own, so the removal has nothing to repair. Isolates the activation as the trigger.
    func testTheSameSequenceWithoutTheActivationNeedsNoRepair() {
        let runner = TestReducerRunner(initial: state([
            window(Self.finderWid, Self.finderPid, "Liebesleid", order: 0),
            window(Self.reaperMainWid, Self.reaperPid, "Country Dance - REAPER v7.78", order: 1),
        ], frontmost: Self.finderPid))
        runner.run(capturedDialogSteps(withActivation: false))
        XCTAssertEqual(order(runner.state, Self.reaperMainWid), 0)
        XCTAssertEqual(order(runner.state, Self.finderWid), 1)
    }

    /// The capture, input by input (timestamps are the log's own, in seconds since its first event).
    private func capturedDialogSteps(withActivation: Bool) -> [TestReducerRunner.Step] {
        var steps: [TestReducerRunner.Step] = [
            // 13:28:13.588-.845 — the dialog appears while REAPER is in the background: created at 0×0,
            // sized a beat later, focused before it is tracked, then discovered.
            .input(.windowCreated(wid: Self.reaperDialogWid, now: 13.588, inSpaceTransition: false)),
            .input(.windowMovedOrResized(wid: Self.reaperDialogWid, inSpaceTransition: false)),
            .input(.windowOrderedIn(wid: Self.reaperDialogWid, now: 13.622, inSpaceTransition: false)),
            .input(.windowFocused(wid: Self.reaperDialogWid, now: 13.634)),
            .track(window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 0)),
            .input(.discoveryLanded(wid: Self.reaperDialogWid, accepted: true, newlyTracked: true,
                adoptedAsInactiveTab: false, queriedSpaceIds: [4], tabTitles: nil)),
            // 13:28:14.96 — the click on the dialog's button brings REAPER to the front.
            .setAppActive(pid: Self.finderPid, isActive: false),
            .setAppActive(pid: Self.reaperPid, isActive: true),
            .setFrontmost(pid: Self.reaperPid),
        ]
        if withActivation {
            steps.append(.input(.appActivated(pid: Self.reaperPid, now: 14.960, altTabTargetWid: nil)))
        }
        steps += [
            // 13:28:14.961-.962 — the two 808s, 1 ms apart: the dialog, then the main window.
            .input(.windowFocused(wid: Self.reaperDialogWid, now: 14.961)),
            .input(.windowOrderedIn(wid: Self.reaperDialogWid, now: 14.962, inSpaceTransition: false)),
            .input(.windowFocused(wid: Self.reaperMainWid, now: 14.962)),
            .input(.windowOrderedIn(wid: Self.reaperMainWid, now: 14.962, inSpaceTransition: false)),
            // 13:28:16.92-.96 — the dialog goes off-screen and the AX probe confirms it closed.
            .input(.windowOrderedOut(wid: Self.reaperDialogWid, inSpaceTransition: false)),
            .input(.livenessConfirmedDead(wid: Self.reaperDialogWid)),
        ]
        return steps
    }

    // MARK: - C. Restoring a minimized window (QA I-11, #5439's shape)

    private static let textEditPid: pid_t = 95772
    private static let teRestoredWid: CGWindowID = 90112 // the minimized window the user picked
    private static let teSiblingWid: CGWindowID = 90106  // the one they never touched

    private func restoreState() -> TrackedWindowState {
        var s = TrackedWindowState()
        s.windows = [
            window(Self.finderWid, Self.finderPid, "lwouis", order: 0),
            window(Self.teRestoredWid, Self.textEditPid, "Untitled", order: 1, isMinimized: true),
            window(Self.teSiblingWid, Self.textEditPid, "Untitled 2", order: 2),
        ]
        s.apps[Self.textEditPid] = TrackedApp(state: ApplicationState(pid: Self.textEditPid,
            bundleIdentifier: "com.apple.TextEdit", localizedName: "TextEdit", isHidden: false),
            isActive: false)
        s.apps[Self.finderPid] = TrackedApp(state: ApplicationState(pid: Self.finderPid,
            bundleIdentifier: "com.apple.finder", localizedName: "Finder", isHidden: false), isActive: true)
        s.frontmostPid = Self.finderPid
        s.visibleSpaces = [4]
        s.currentSpaceId = 4
        s.spaceIndexById = [4: 1]
        return s
    }

    /// The QA I-11 capture (2026-07-31). AltTab focuses a MINIMIZED window, so it deminiaturizes first —
    /// and unlike every other AltTab focus, that stirs the app's other windows. macOS answered with a focus
    /// 808 for the SIBLING 38ms into the activation; with an AltTab activation's empty snapshot that was not
    /// a raise, so it took slot 0 off the window the user had just restored (#5439's shape).
    ///
    /// This pins the reducer end of the fix: `ActivationFocusResolver.onActivation` only knows to keep the
    /// snapshot because `appActivated` tells it the target was minimized, and the kernel tests cannot prove
    /// that call site passes it.
    func testRestoringAMinimizedWindowKeepsItInFrontOfItsSibling() {
        let runner = TestReducerRunner(initial: restoreState())
        runner.run([
            .setAppActive(pid: Self.finderPid, isActive: false),
            .setAppActive(pid: Self.textEditPid, isActive: true),
            .setFrontmost(pid: Self.textEditPid),
            // 02:04:04.833 — our own focus, so the target is known and bumped directly.
            .input(.appActivated(pid: Self.textEditPid, now: 4.833, altTabTargetWid: Self.teRestoredWid)),
            // 02:04:04.871 — the deminiaturize tail: the sibling, which the user never asked for.
            .input(.windowFocused(wid: Self.teSiblingWid, now: 4.871)),
            .input(.windowOrderedIn(wid: Self.teSiblingWid, now: 4.871, inSpaceTransition: false)),
            // 02:04:04.874 — the window actually being restored arrives 3ms later.
            .input(.windowOrderedIn(wid: Self.teRestoredWid, now: 4.874, inSpaceTransition: false)),
        ])
        // The restored window takes slot 0 and everything else keeps its relative order: Finder shifts down
        // to 1, and the sibling — whose focus was swallowed as the tail — does not move at all.
        XCTAssertEqual(order(runner.state, Self.teRestoredWid), 0)
        XCTAssertEqual(order(runner.state, Self.finderWid), 1)
        XCTAssertEqual(order(runner.state, Self.teSiblingWid), 2)
    }

    /// The same tail against a NON-minimized target must still bump: that is #5785's second alt-tab, where
    /// muting the sibling's genuine 808 left every following alt-tab on the window the user was already in.
    /// The two live behaviours differ only by whether AltTab had to deminiaturize.
    func testFocusingANonMinimizedWindowStillLetsTheSiblingsFocusBump() {
        var initial = restoreState()
        initial.windows[1].isMinimized = false
        let runner = TestReducerRunner(initial: initial)
        runner.run([
            .setAppActive(pid: Self.finderPid, isActive: false),
            .setAppActive(pid: Self.textEditPid, isActive: true),
            .setFrontmost(pid: Self.textEditPid),
            .input(.appActivated(pid: Self.textEditPid, now: 4.833, altTabTargetWid: Self.teRestoredWid)),
            .input(.windowFocused(wid: Self.teSiblingWid, now: 4.871)),
        ])
        XCTAssertEqual(order(runner.state, Self.teSiblingWid), 0)
    }

    // MARK: - B. The rule

    /// Another app holds slot 1, but focus never crosses apps because a window closed: the frontmost app's
    /// own next window takes the front, and `.applyFocus` names it so the live model agrees.
    func testRemovingTheFocusedWindowPromotesTheFrontmostAppsNextWindow() {
        var s = state([
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 0),
            window(Self.finderWid, Self.finderPid, "Liebesleid", order: 1),
            window(Self.reaperMainWid, Self.reaperPid, "Country Dance - REAPER v7.78", order: 2),
        ], frontmost: Self.reaperPid)
        let effects = WindowEventReducer.reduce(&s, .windowDestroyed(wid: Self.reaperDialogWid))
        XCTAssertTrue(effects.contains(.applyFocus(Self.reaperMainWid)))
        XCTAssertEqual(order(s, Self.reaperMainWid), 0)
    }

    /// An ordinary close of a background window leaves slot 0 alone — nothing to repair, nothing bumped.
    func testRemovingANonFrontWindowPromotesNothing() {
        var s = state([
            window(Self.reaperMainWid, Self.reaperPid, "Country Dance - REAPER v7.78", order: 0),
            window(Self.finderWid, Self.finderPid, "Liebesleid", order: 1),
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 2),
        ], frontmost: Self.reaperPid)
        let effects = WindowEventReducer.reduce(&s, .windowDestroyed(wid: Self.reaperDialogWid))
        XCTAssertFalse(effects.contains { if case .applyFocus = $0 { return true } else { return false } })
        XCTAssertEqual(order(s, Self.reaperMainWid), 0)
    }

    /// The frontmost app's last window closes: there is nothing of its own left to promote, so the global
    /// shift stands (the app is on its way to windowless).
    func testRemovingTheFrontmostAppsOnlyWindowPromotesNothing() {
        var s = state([
            window(Self.reaperMainWid, Self.reaperPid, "Country Dance - REAPER v7.78", order: 0),
            window(Self.finderWid, Self.finderPid, "Liebesleid", order: 1),
        ], frontmost: Self.reaperPid)
        let effects = WindowEventReducer.reduce(&s, .windowDestroyed(wid: Self.reaperMainWid))
        XCTAssertFalse(effects.contains { if case .applyFocus = $0 { return true } else { return false } })
    }

    /// A minimized window is off screen and never received the focus the closing window gave up.
    func testMinimizedWindowsAreNotPromoted() {
        var s = state([
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 0),
            window(Self.reaperMainWid, Self.reaperPid, "Country Dance - REAPER v7.78", order: 1,
                isMinimized: true),
            window(Self.finderWid, Self.finderPid, "Liebesleid", order: 2),
        ], frontmost: Self.reaperPid)
        let effects = WindowEventReducer.reduce(&s, .windowDestroyed(wid: Self.reaperDialogWid))
        XCTAssertFalse(effects.contains(.applyFocus(Self.reaperMainWid)))
    }

    /// An inactive tab is off screen too — what the user sees is its group's representative.
    func testInactiveTabsAreNotPromoted() {
        let backgroundTab: CGWindowID = 4600
        var s = state([
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 0),
            window(backgroundTab, Self.reaperPid, "background tab", order: 1),
            window(Self.reaperMainWid, Self.reaperPid, "Country Dance - REAPER v7.78", order: 2),
        ], frontmost: Self.reaperPid)
        s.formGroup([Self.reaperMainWid, backgroundTab], representative: Self.reaperMainWid, reason: "test")
        XCTAssertTrue(s.isTabbed(s.window(backgroundTab)!), "precondition: an inactive tab")
        let effects = WindowEventReducer.reduce(&s, .windowDestroyed(wid: Self.reaperDialogWid))
        XCTAssertTrue(effects.contains(.applyFocus(Self.reaperMainWid)))
        XCTAssertFalse(effects.contains(.applyFocus(backgroundTab)))
    }
}
