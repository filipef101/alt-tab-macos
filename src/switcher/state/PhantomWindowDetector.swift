import Foundation

/// Detects whether a window is a "phantom": present in macOS APIs (AX hands it back with a valid
/// `CGWindowID`) but not something the app actually means to show the user — alpha=0 Outlook reminders,
/// `orderOut:` / `show:false` Electron windows, WeChat/Teams hidden windows, etc. The pixel content may
/// be absent, black, or anything; what matters is that AltTab shouldn't offer it as a switch target. See
/// `src/experimentations/PhantomWindowDetection.swift` for the full investigation.
///
/// Pure kernel over the test-constructible `WindowState` + `ApplicationState` records (no SkyLight, no
/// `@testable`). Two entry points, by how much CGS data the caller has — they share the same notion of
/// "phantom" but the synchronous one can only observe the *strong* signal:
enum PhantomWindowDetector {
    /// Synchronous, cheap — evaluated on every read (the derived `Window.isPhantom`). Knows only the STRONG
    /// signal: the window has no Space at all (CGS lost track of it — Joplin / Sprig / `show:false`
    /// Electron). The weak signal it can't observe arrives through `s.isPhantom`, which the caller feeds
    /// with the latched CGS verdict (a weak-signal phantom — alpha=0 / `orderOut:` still on a Space — keeps
    /// its Space, so only `cgsVerdict` can see it; that latch is owned by `Window.applyCgsPhantomVerdict`,
    /// #5714).
    ///
    /// EXCEPTION — `isTabbed` clears the flag. AX tab detection is authoritative but lands AFTER a window
    /// is first seen, so an inactive tab is briefly flagged phantom (empty `spaceIds`, not-yet-known
    /// tabbed) by `syncSpacesState` before `TabGroup.updateState` runs. Once AX confirms the tab we must
    /// un-flag it — unlike the weak signal, this path CAN observe `isTabbed`, and a real phantom is never
    /// part of an AXTabGroup, so clearing is safe. Without this the monotonic OR left inactive tabs stuck
    /// phantom, so "Group tabs: separate window for each tab" showed only the active tab (one per app).
    static func syncVerdict(_ s: WindowState, _ app: ApplicationState) -> Bool {
        if s.isTabbed { return false }
        return s.isPhantom || (s.spaceIds.isEmpty && !s.isMinimized && !app.isHidden)
    }

    /// Authoritative — runs ~250ms post-show off-main (`Applications.refreshIsPhantom`) with the two CGS
    /// window lists (`inVisibleList` excludes the `.invisible1/.invisible2` tags, `inAllList` includes
    /// them). Knows BOTH the strong and weak signals; owns the full verdict, including clearing.
    /// Disambiguation order matches `PhantomWindowDetection.swift`.
    ///
    /// `isFocused` = this window is the most-recently-focused one AND its app is frontmost, i.e. the window
    /// the user is looking at right now. It exempts ONLY the weak signal (see below).
    static func cgsVerdict(_ s: WindowState, _ app: ApplicationState,
                           inVisibleList: Bool, inAllList: Bool, visibleSpaceIds: [UInt64],
                           isFocused: Bool = false) -> Bool {
        // Legitimate windows CGS may not list in any Space — an inactive tab (CGS lists no background tab,
        // so its spaceIds are backfilled from the active sibling), a minimized window, a hidden app's
        // window. They must be cleared BEFORE the strong signal, else "absent from every Space" flags them
        // phantom even though they're real (the inactive-tab / fullscreen-tab disappearance). A true phantom
        // is none of these. Mirrors syncVerdict, which exempts the same three from its strong signal.
        if s.isTabbed || s.isMinimized || app.isHidden { return false }
        // strong signal: CGS dropped the WID from every Space (Joplin / Sprig / show:false Electron)
        if !inAllList { return true }
        // tagged invisible by CGS — disambiguate against the legitimate reasons a window lives there
        if inVisibleList { return false }
        // known Spaces, none of them visible → legitimate other-Space window
        if !s.spaceIds.isEmpty && !s.spaceIds.contains(where: { visibleSpaceIds.contains($0) }) { return false }
        // The window the user is looking at cannot be a phantom, whatever CGS tags it. Electron apps
        // (Slack, Telegram) reopened from the Dock keep their window tagged invisible for seconds after it
        // is on screen and focused, so the weak signal below flagged the FOREGROUND window phantom: the app
        // then looked windowless (spawning a placeholder tile) and the hidden window still held its MRU
        // slot, so the switcher's "previously-focused window" default skipped one window too far and landed
        // on the wrong app (#5849). Deliberately placed AFTER the strong signal: a wid CGS dropped from
        // every list is gone regardless of a stale focus record, and resurrecting it would undo #5714.
        if isFocused { return false }
        // weak signal: alpha=0 / orderOut: window still on a visible Space
        return true
    }
}
