import CoreGraphics
import Foundation

/// The per-app state tracked from a `didActivateApplication` notification: which windows the activation may
/// raise (each raise 808 consumes its entry), until when the activation is considered in flight, and whether
/// the activation's focus 808 has already bumped the MRU.
struct ActivationEntry: Equatable {
    var wids: Set<CGWindowID>
    var until: TimeInterval
    var focusBumped = false
    /// `wids` as it was BUILT, never drained. The 808 path consumes `wids` (a wid still in it is a raise, so
    /// each entry is spent once), which makes the set useless to the 815 path: a raise tail's order-ins
    /// arrive AFTER its focus events have emptied it, so "the set is empty" is not "the storm is over" — the
    /// reason `movedResizedOrOrderedIn` gates on `until` alone. That is right for a tail we did not cause and
    /// WRONG when there is no tail at all: an AltTab-initiated activation raises exactly one window, so it
    /// snapshots nothing, and the time gate still swallowed the user's own Cmd+` inside the 0.5s (#5875 —
    /// alt-tab into Preview, cycle its windows a beat later, and the MRU kept the window you left, so the
    /// next alt-tab back landed on it). An empty snapshot means "nothing here is a raise"; keeping the
    /// undrained copy is what lets the 815 path read that, while a real storm's order-ins stay muted.
    var raiseTail = Set<CGWindowID>()
}

/// Pure decisions for MRU focus around app activation, extracted from `WindowServerEvents` after two
/// regressions in a row (#5596). The recorded ground truth (TextEdit, iTerm; Cmd+Tab and click activations):
/// on activation macOS emits 808s for the app's on-Space windows — the FIRST is the genuinely FOCUSED window,
/// the rest (when there is a storm at all) are RAISES front-to-back; sometimes there is NO storm, just the
/// single focus 808. So the first 808 of an activation must bump (it is the truth, and
/// `NSRunningApplication.isActive` can still read false at that instant), the raise tail must be swallowed
/// (re-fronting it reverses the app's MRU), and the async AX focused-window read (the backstop for
/// activations that emit no 808) must YIELD once a real 808 has spoken — it races the app's internal focus
/// update and can return the PREVIOUS window (iTerm). See `ActivationFocusResolverSpecs.md`.
enum ActivationFocusResolver {
    /// The verdict for one focus event (808): whether to bump the MRU, and the entry state to store back.
    struct FocusDecision: Equatable {
        var bump: Bool
        var entry: ActivationEntry?
    }

    /// Decide a tracked window's 808. `entry` is the app's activation state (nil when no activation is in
    /// flight); an expired entry is pruned (returned nil) and ignored. A brand-new window's first focus always
    /// bumps (it may arrive while the app already went background — cmd-N spam). The first 808 of a live
    /// activation bumps regardless of `appIsActive` (separate clocks); a subsequent 808 for a wid still in the
    /// snapshot is a raise and is swallowed; anything else falls to the normal rule: bump iff the app is active.
    static func onFocusEvent(_ entry: ActivationEntry?, wid: CGWindowID, now: TimeInterval,
                             wasJustCreated: Bool, appIsActive: Bool) -> FocusDecision {
        guard var entry, entry.until > now else {
            return FocusDecision(bump: wasJustCreated || appIsActive, entry: nil)
        }
        let isFirstFocusOfActivation = !entry.focusBumped
        let isActivationRaise = entry.focusBumped && entry.wids.contains(wid)
        entry.wids.remove(wid)
        if isFirstFocusOfActivation { entry.focusBumped = true }
        let bump = wasJustCreated || isFirstFocusOfActivation || (appIsActive && !isActivationRaise)
        return FocusDecision(bump: bump, entry: entry)
    }

    /// Build the activation entry when an app activates. When the activation was ALTTAB-INITIATED (the
    /// switcher just focused `altTabTarget`, same app, fresh), the target is KNOWN — no need to divine it
    /// from events: bump it directly and mark the entry `focusBumped`, so the stale-prone AX backstop yields.
    /// Without a known target, a plain entry is returned and the focus comes from the first 808 (or the AX
    /// backstop when none arrives). This closes the last race for the app's own switches: with no 808 and a
    /// stale AX read, the freshly-focused window's bump was otherwise lost.
    ///
    /// An AltTab-initiated activation gets an EMPTY snapshot: there is no raise tail to swallow, because
    /// AltTab raises exactly one window (`_SLPSSetFrontProcessWithOptions` with a wid) rather than fronting
    /// the app's whole stack. #5785's log shows it plainly — three alt-tabs into a 3-window Chrome, one 808
    /// each, always the target's, never the other two. Snapshotting the app's windows there muted focus
    /// events macOS really sent: a second alt-tab a beat later, to another window of the SAME app, had its
    /// genuine 808 read as this activation's raise tail, and since re-focusing an already-focused window
    /// emits nothing at all, no later event ever corrected the order — every following alt-tab landed on the
    /// window the user was already in.
    ///
    /// **Except when the target was MINIMIZED**, which is the one focus where AltTab does more than raise a
    /// single window: it deminiaturizes first (`kAXMinimizedAttribute = false`), and restoring a window
    /// stirs the app's other windows. So "we did not cause a tail" — the whole justification for the empty
    /// snapshot — is false exactly here, and the tail must be muted like any other.
    ///
    /// Measured over five live restores (QA I-11, 2026-07-31). Four emitted no focus 808 at all, the
    /// activation's own known-target bump being the only thing that set the order:
    ///
    ///     --focus=92339 → appActivated | mru bump #92339 → windowOrderedIn #92339
    ///
    /// The fifth emitted one, 38ms in, for the SIBLING the user never touched — and with an empty snapshot
    /// it was not a raise, so it took the front off the window that had just been restored (#5439's shape):
    ///
    ///     --focus=90112 → appActivated | mru bump #90112
    ///                   → windowFocused #90106 | mru bump #90106   ← the sibling wins
    ///                   → windowOrderedIn #90112                    ← the target, 3ms later
    ///
    /// The target itself is never in the tail: it is what the user asked for, it is already bumped here, and
    /// on this path it is minimized so the caller's snapshot excludes it anyway — subtracted regardless so
    /// the guarantee does not depend on how the caller built the set.
    static func onActivation(snapshotWids: Set<CGWindowID>, until: TimeInterval, altTabTarget: CGWindowID?,
                             targetWasMinimized: Bool = false) -> (entry: ActivationEntry, bumpWid: CGWindowID?) {
        if let target = altTabTarget {
            let tail = targetWasMinimized ? snapshotWids.subtracting([target]) : []
            return (ActivationEntry(wids: tail, until: until, focusBumped: true, raiseTail: tail), target)
        }
        return (ActivationEntry(wids: snapshotWids, until: until, raiseTail: snapshotWids), nil)
    }

    // MARK: - the AltTab focus intent

    /// The one-shot record AltTab keeps when IT focused a window: the activation that follows is OURS, so the
    /// target is known (no need to divine it from a racy 808 / AX read) and there is no raise tail to mute.
    struct AltTabFocusIntent: Equatable {
        var wid: CGWindowID
        var pid: pid_t
        var at: TimeInterval
    }

    /// How long a recorded intent stays applicable. A failsafe only: the activation it belongs to normally
    /// lands within a few tens of ms and consumes it.
    static let altTabIntentFailsafe: TimeInterval = 1

    /// Whether AltTab's focus of `pid`'s window is worth recording — i.e. whether an activation is actually
    /// COMING. Focusing a window of the app that is ALREADY frontmost raises no app, so no `didActivate`
    /// follows to consume the record, and it would sit until the failsafe expires.
    ///
    /// A leftover intent is not harmless: it tells the activation that consumes it BOTH which window to front
    /// and that there is no raise tail to mute. So a genuine Cmd+Tab back into the same app, inside the
    /// failsafe, would take a stale target and let the real burst re-front each window in turn (#5596). The
    /// in-app case needs nothing from the record anyway — its focus arrives as an ordinary 808, or as an
    /// order-in for Cmd+` ("Cycle Through Windows").
    static func altTabIntentToRecord(wid: CGWindowID, pid: pid_t, frontmostPid: pid_t?,
                                     at: TimeInterval) -> AltTabFocusIntent? {
        guard frontmostPid != pid else { return nil }
        return AltTabFocusIntent(wid: wid, pid: pid, at: at)
    }

    /// Does a recorded intent belong to THIS activation? Same app, and fresh enough that it is the activation
    /// our own focus caused rather than a later unrelated one.
    static func altTabIntentApplies(_ intent: AltTabFocusIntent?, activatedPid: pid_t, now: TimeInterval) -> Bool {
        guard let intent else { return false }
        return intent.pid == activatedPid && now - intent.at < altTabIntentFailsafe
    }

    /// Whether the AX focused-window backstop may apply its result. It is the WEAK signal — the read races the
    /// app's internal focus update and can return the previous window — so it only applies while the
    /// activation's focus 808 hasn't spoken. (No entry ⇒ apply: the backstop also serves activations whose
    /// entry already expired or was never created.)
    static func axBackstopShouldApply(_ entry: ActivationEntry?) -> Bool {
        entry?.focusBumped != true
    }
}
