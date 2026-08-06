import Foundation

/// Pure scheduling decisions extracted from `Throttler` / `ThrottlerWithKey` and `AXCallScheduler`, so the
/// timing logic is unit-testable without real clocks or queues (same pattern as `SelectionResolver` /
/// `AxQueryRouting`). The owners keep the actual clock reads + queue dispatch; they just branch on these.

/// The coalescing decision for one `throttleOrProceed` call: leading-edge runs immediately; calls within
/// the window collapse to a single trailing run.
enum ThrottleDecision: Equatable {
    case runNow                            // leading edge (or window already elapsed): run now, (re)start the window
    case scheduleTail(remainingNs: UInt64) // within window, no trailing run pending yet: schedule one after `remaining`
    case coalesce                          // within window, a trailing run is already pending: drop (latest runs on the tail)

    static func decide(lastFireNs: UInt64?, nowNs: UInt64, delayNs: UInt64, tailScheduled: Bool) -> ThrottleDecision {
        // first call ever, or a (practically impossible) backwards clock → treat as a fresh leading edge
        guard let last = lastFireNs, nowNs >= last else { return .runNow }
        let elapsed = nowNs - last
        if elapsed >= delayNs { return .runNow }
        return tailScheduled ? .coalesce : .scheduleTail(remainingNs: delayNs - elapsed)
    }
}

/// Backoff + give-up policy for retrying an AX call against an unresponsive app.
enum RetryPolicy {
    static let backoffStepsNs: [UInt64] = [200_000_000, 1_000_000_000, 2_000_000_000, 5_000_000_000] // 200ms, 1s, 2s, 5s…
    static let giveUpAfterNs: UInt64 = 60_000_000_000 // 60s

    /// retry N uses step N, clamped to the last (so it stays at 5s); negative counts floor to the first step.
    static func backoffDelayNs(retryCount: Int) -> UInt64 {
        backoffStepsNs[min(max(0, retryCount), backoffStepsNs.count - 1)]
    }

    static func shouldGiveUp(elapsedSinceStartNs: UInt64) -> Bool {
        elapsedSinceStartNs >= giveUpAfterNs
    }
}

/// May we brute-force this app's AX tree for the inactive tabs its AXTabGroup named but we hold no window for
/// (`Applications.discoverInactiveTabs`)? An inactive tab appears in no CGS list, so this scan is the ONLY way
/// to adopt one — and it is expensive (a full walk of the app's accessibility tree), so it can't simply run on
/// every tab read.
///
/// The gate is per-app and keyed on the SITUATION (the untracked titles plus the app's window count), because
/// that is what says whether anything has changed since we last looked: a tab getting adopted, opened or closed
/// moves the count or the titles. A new situation is always eligible.
///
/// **An attempt that adopted nothing must be RETRYABLE, which is where this went wrong.** The situation used to
/// be recorded before the scan even ran, and once recorded it was refused forever — so a single fruitless
/// attempt (the app's AX tree not ready yet, the classic at launch) permanently gave up on that situation, with
/// no retry and no later trigger. Measured over a QA run: 82 tab reads named untracked tabs and the scan
/// adopted nothing at all, while a run where the first attempt happened to land adopted 57.
///
/// So a situation gets a small number of attempts rather than exactly one. Bounded, because the fruitless case
/// is ORDINARY and not an error: Finder destroys a backgrounded tab's window, so its AXTabGroup routinely names
/// tabs that have no window to find (`testFinderTabsAllUntracked`) and no number of scans will ever resolve
/// them. The cap is what keeps that from re-walking the tree on every show forever.
enum InactiveTabScanPolicy {
    static let maxAttemptsPerSituation = 3

    static func shouldScan(recordedSituation: String?, attempts: Int, situation: String) -> Bool {
        guard recordedSituation == situation else { return true }
        return attempts < maxAttemptsPerSituation
    }

    /// The attempt count to store after a scan: a scan that ADOPTED something made progress, and the situation
    /// it produces is new anyway (the window count moved), so it never needs to spend the budget. Only a
    /// fruitless attempt consumes one.
    static func attemptsAfterScan(previousAttempts: Int, sameSituation: Bool, adopted: Int) -> Int {
        guard adopted == 0 else { return 0 }
        return (sameSituation ? previousAttempts : 0) + 1
    }

    /// How far BELOW an app's lowest known element id a sweep starts. Sized against the measured throughput
    /// (~9.7k ids per 250ms budget) so one attempt still covers a good stretch ABOVE the anchor too.
    static let scanMargin: UInt64 = 4000

    /// **Where to begin the brute-force sweep, which is what actually decides whether it finds anything.** The
    /// scan walks AXUIElementIDs one by one under a wall-clock budget, so it covers a WINDOW of the id space,
    /// never the space — and starting at 0 pointed that window at wherever the app was hours ago. Measured live
    /// (2026-07-30): three attempts covered ids 0..<30000 and adopted nothing, while Finder's window elements
    /// sat at ~31000 — stopping just short, every time, forever.
    ///
    /// A tab's window element is minted when the tab is, so an app's windows cluster in a narrow band, and a
    /// window we already track names that band. Anchor a margin below it (the tabs we are missing are usually
    /// OLDER than the active tab that named them) and the same 250ms lands on them immediately. A `cursor` from
    /// a previous fruitless attempt wins, so retries make progress instead of re-walking what already failed.
    static func scanStart(cursor: UInt64?, lowestKnownId: UInt64?) -> UInt64 {
        if let cursor { return cursor }
        guard let anchor = lowestKnownId else { return 0 }
        return anchor > scanMargin ? anchor - scanMargin : 0
    }
}
