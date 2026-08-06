import XCTest

final class KeyRepeatTimerTests: XCTestCase {
    private let initialDelay: TimeInterval = 0.4

    // MARK: A. Visible timestamp known — gate from visibility

    /// visible 0.5s ago, initialDelay 0.4s → applies.
    func testAppliesOnceVisibleForInitialDelay() {
        XCTAssertTrue(KeyRepeatTimerTestable.shouldApplyArtificialRepeat(
            now: 100, armedAt: 99.4, panelBecameVisibleAt: 99.5, panelShownAt: nil, initialDelay: initialDelay))
    }

    /// visible 0.1s ago, initialDelay 0.4s → skips. The core fix: the slow show finally presented the
    /// panel, but the grace hasn't elapsed since it became visible, so a queued repeat mustn't fire.
    func testSkipsWhenNotVisibleLongEnough() {
        XCTAssertFalse(KeyRepeatTimerTestable.shouldApplyArtificialRepeat(
            now: 100, armedAt: 99.5, panelBecameVisibleAt: 99.9, panelShownAt: nil, initialDelay: initialDelay))
    }

    /// visible exactly initialDelay ago → applies (boundary is inclusive).
    func testAppliesExactlyAtInitialDelayBoundary() {
        XCTAssertTrue(KeyRepeatTimerTestable.shouldApplyArtificialRepeat(
            now: 100, armedAt: 99.6, panelBecameVisibleAt: 100 - initialDelay, panelShownAt: nil, initialDelay: initialDelay))
    }

    // MARK: A2. The show-time anchor — the guaranteed one

    /// **The 1.4s bug.** `panelBecameVisibleAt` comes from our own panel's WindowServer `orderedIn`, and that
    /// notification never arrives: order-in needs the per-window opt-in (`WindowServerEvents.wsWindows`), which
    /// the panel is not in. So EVERY tick took the fallback branch below and the first cycle landed at
    /// `armedAt + initialDelay + 1s` — measured live at 1377ms against a system `InitialKeyRepeat` of 417ms,
    /// on every hold-to-cycle, not just a slow show. The 1s budget was the normal path, not a safety net.
    ///
    /// `TilesPanel.show()` supplies an anchor that cannot go missing. It is slightly early (the WindowServer
    /// paints after the order-front returns), which is why the WS signal stays as the correction above it.
    func testAppliesFromTheShowAnchorWhenNoWindowServerSignalArrives() {
        XCTAssertTrue(KeyRepeatTimerTestable.shouldApplyArtificialRepeat(
            now: 100, armedAt: 99.4, panelBecameVisibleAt: nil, panelShownAt: 99.5, initialDelay: initialDelay))
        XCTAssertFalse(KeyRepeatTimerTestable.shouldApplyArtificialRepeat(
            now: 100, armedAt: 99.4, panelBecameVisibleAt: nil, panelShownAt: 99.9, initialDelay: initialDelay))
    }

    /// The WindowServer signal is the CORRECTION, not a peer: it is the true "pixels on screen" moment and
    /// lands after the show, so when both are known it wins — a slow show must not start the grace early.
    func testTheWindowServerSignalOverridesTheShowAnchor() {
        XCTAssertFalse(KeyRepeatTimerTestable.shouldApplyArtificialRepeat(
            now: 100, armedAt: 99.0, panelBecameVisibleAt: 99.9, panelShownAt: 99.1, initialDelay: initialDelay))
    }

    // MARK: B. Neither anchor known — arm-relative fallback

    /// never visible, armed 0.5s ago, initialDelay 0.4s → skips. The queued-burst case: repeats due at
    /// ~arm+initialDelay are suppressed while the panel still isn't up. Fallback opens at initialDelay + 1s.
    func testSkipsBeforeFallbackBudgetWhenNeverVisible() {
        XCTAssertFalse(KeyRepeatTimerTestable.shouldApplyArtificialRepeat(
            now: 100, armedAt: 99.5, panelBecameVisibleAt: nil, panelShownAt: nil, initialDelay: initialDelay))
    }

    /// never visible, armed 1.5s ago, initialDelay 0.4s → applies (>= 0.4 + 1), so a missed visible
    /// signal can't wedge hold-to-cycle forever.
    func testAppliesAfterFallbackBudgetWhenNeverVisible() {
        XCTAssertTrue(KeyRepeatTimerTestable.shouldApplyArtificialRepeat(
            now: 100, armedAt: 98.5, panelBecameVisibleAt: nil, panelShownAt: nil, initialDelay: initialDelay))
    }
}
