import Foundation

/// Pure decision for the artificial key-repeat: given wall-clock timestamps, should this repeat tick actually
/// advance the selection? Extracted from `KeyRepeatTimer` so the timing rule is unit-tested in isolation
/// (no timer, no DispatchSource, no AppKit). See `KeyRepeatTimerSpecs.md`.
enum KeyRepeatTimerTestable {
    /// If NEITHER anchor is known, fall back to arm-relative timing after this extra budget so hold-to-cycle
    /// can't get permanently wedged. A genuine safety net now — it used to be the normal path, see below.
    static let missedVisibleSignalBudget: TimeInterval = 1

    /// A slow show (WindowServer busy after a fullscreen/Space transition) can present the panel ~500ms after
    /// the timer was armed. The initial-delay grace must be measured from when the user could actually SEE the
    /// switcher, else repeats queued during the invisible gap fire the instant it appears and jump the
    /// selection several tiles.
    ///
    /// **Two anchors, because the accurate one can be absent.** `panelBecameVisibleAt` is the true "pixels on
    /// screen" moment (our own panel's WindowServer `orderedIn`) and wins whenever it is known — but it is not
    /// known today at all: order-in delivery needs the per-window opt-in (`WindowServerEvents.wsWindows`) and
    /// the panel is not in it, so that notification never arrives. Every tick therefore took the fallback and
    /// the first cycle landed a full second late — measured live at 1377ms against a system `InitialKeyRepeat`
    /// of 417ms, on EVERY hold, not merely a slow show. `panelShownAt` is the anchor that cannot go missing
    /// (`TilesPanel.show()` sets it as it orders the panel front). It is slightly EARLY, since the WindowServer
    /// paints after the order-front call returns, which is exactly why the visible signal stays above it rather
    /// than replacing it.
    static func shouldApplyArtificialRepeat(now: TimeInterval, armedAt: TimeInterval,
                                            panelBecameVisibleAt: TimeInterval?, panelShownAt: TimeInterval?,
                                            initialDelay: TimeInterval) -> Bool {
        if let anchor = panelBecameVisibleAt ?? panelShownAt {
            return now - anchor >= initialDelay
        }
        return now - armedAt >= initialDelay + missedVisibleSignalBudget
    }
}
