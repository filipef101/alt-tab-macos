import XCTest

/// Pins the split between the two Space-switch reactions: the leading edge reads the topology and nothing
/// else, the trailing edge keeps the work that has to wait for the transition's storm to be over. Drives
/// `WindowEventReducer.reduce` directly — the replay harness buckets both branches' requests together and
/// swallows `.refreshUi`, so it cannot tell them apart. See WindowEventReducerSpaceSpecs.md.
final class WindowEventReducerSpaceTests: XCTestCase {

    private static let pid: pid_t = 4711
    private static let widA: CGWindowID = 5001
    private static let widB: CGWindowID = 5002

    private func window(_ wid: CGWindowID, spaceId: UInt64, order: Int) -> TrackedWindow {
        TrackedWindow(id: "wid-\(wid)", wid: wid, pid: Self.pid, title: "w\(wid)",
            size: CGSize(width: 1200, height: 800), position: CGPoint(x: 0, y: 40),
            spaceIds: [spaceId], spaceIndexes: [Int(spaceId)], isOnAllSpaces: false, spaceIsBorrowed: false,
            isFullscreen: false, isFullscreenMirrored: false, isMinimized: false, isMainWindow: false,
            isWindowlessApp: false, cgsPhantomLatch: false, lastFocusOrder: order,
            creationOrder: order, hasThumbnail: true)
    }

    /// One window on each of two Spaces, sitting on Space 1 — the shape a Space switch acts on.
    private func state() -> TrackedWindowState {
        var s = TrackedWindowState()
        s.windows = [window(Self.widA, spaceId: 1, order: 0), window(Self.widB, spaceId: 2, order: 1)]
        s.apps[Self.pid] = TrackedApp(
            state: ApplicationState(pid: Self.pid, bundleIdentifier: "com.apple.TextEdit",
                                    localizedName: "TextEdit", isHidden: false),
            isActive: true)
        s.visibleSpaces = [1]
        s.currentSpaceId = 1
        s.spaceIndexById = [1: 1, 2: 2]
        s.frontmostPid = Self.pid
        return s
    }

    // MARK: - A. The leading edge is the topology read, and nothing else

    /// The leading edge exists to make ONE cheap fact current before the summon that follows it. A repaint
    /// here is the trap: `refreshOpenUiAfterExternalEvent` is throttled at 200ms leading-edge, so repainting
    /// the instant the Space flips spends that edge and the arriving Space's focus 808 — 14-67ms later,
    /// measured — then waits out the tail (live: 19ms became 220ms). Exact equality, so re-adding any of it
    /// fails here rather than in a QA run weeks later.
    func testSpaceTransitionStartedEmitsTheTopologyReadAlone() {
        var s = state()
        let effects = WindowEventReducer.reduce(&s, .spaceTransitionStarted)
        XCTAssertEqual(effects, [.refreshSpacesTopology])
    }

    /// It asks the shell to re-read `Spaces`; it is not a place to write the model. The per-window
    /// correction that follows a Space switch belongs to `.spacesSynced`, on real CGS answers.
    func testSpaceTransitionStartedTouchesNoWindowState() {
        var s = state()
        let before = s.windows
        _ = WindowEventReducer.reduce(&s, .spaceTransitionStarted)
        XCTAssertEqual(s.windows, before)
        XCTAssertEqual(s.currentSpaceId, 1)
        XCTAssertEqual(s.visibleSpaces, [1])
    }

    // MARK: - B. The trailing edge keeps the expensive half

    /// The half that has to wait for the transition's create/destroy storm to be over: an early answer here
    /// describes a state that stops being true a frame later, and would be written onto `spaceIds` as
    /// authoritative. Collapsing the two branches would either run this early or drop it.
    func testSpaceChangeSettledKeepsMembershipAndTheStateRequery() {
        var s = state()
        let effects = WindowEventReducer.reduce(&s, .spaceChangeSettled)
        XCTAssertTrue(effects.contains(.refreshSpacesTopologyAndSync))
        XCTAssertTrue(effects.contains(.queryWindowServerState(wids: [Self.widA, Self.widB], throttled: false)))
        XCTAssertTrue(effects.contains(.checkShortcutsForFocusedWindow))
        XCTAssertTrue(effects.contains(.refreshUi(wids: [Self.widA, Self.widB], onlyWhileSwitcherOpen: false)))
        XCTAssertFalse(effects.contains(.refreshSpacesTopology),
                       "the settled pass owns the full refresh; emitting the leading edge's cheap read too "
                       + "would re-read the topology twice for nothing")
    }
}
