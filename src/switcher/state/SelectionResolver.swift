import Foundation

/// One window as seen by the selection kernel — just the fields selection logic needs.
/// Decouples the pure decision from the `Window` AppKit class so this is unit-testable.
struct SelectionWindow: Equatable {
    let id: String
    let visible: Bool
    let lastFocusOrder: Int
    let isMinimized: Bool
    let isWindowlessApp: Bool
    /// This window was NOT in the list when the shortcut was pressed. It belongs wherever the model puts it
    /// (the drawn list must show the truth, so a window created and focused behind the switcher takes tile
    /// 0), but it was not among the windows the user was choosing between, so the default pick steps over it.
    ///
    /// Presence at the summon, NOT "gained focus since" — two live bugs came from the latter. A tab group
    /// re-electing a different member of ITSELF as the drawn one is a focus change with no newcomer, and
    /// stepping over it slid the pick a tile further every time. And marking on focus needed a hook in the
    /// reducer dispatch, which runs AFTER the shell has already inserted the window and recomputed the
    /// selection: measured 2ms in which a genuine newcomer was present but not yet marked. Derived from the
    /// summon snapshot there is nothing to race.
    ///
    /// Being a newcomer is not on its own a reason to step over it — see `secondVisibleIndexAsOfSummon`,
    /// which only does so for the ones that lengthened the list rather than replaced a window that left it.
    var appearedAfterSummon = false
}

/// Snapshot of everything the kernel needs to pick the next selection. No globals, no AppKit.
struct SelectionInputs: Equatable {
    let list: [SelectionWindow]
    let selectedIndex: Int
    let selectedTarget: String?
    /// True iff `Preferences.windowOrder[shortcutIndex] != .recentlyFocused`
    /// AND `Applications.frontmostPid != nil`. Gates the alpha/space-ordering initial-pick path.
    let useLastFocusedRule: Bool
    /// How many windows were VISIBLE when the shortcut was pressed. Compared against the visible count now,
    /// it says how many of the newcomers actually lengthened the list — see `secondVisibleIndexAsOfSummon`.
    let visibleCountAtSummon: Int
    /// True once the user moved the selection themselves. Until then `selectedTarget` is merely where the
    /// DEFAULT landed, not a commitment to that window — see `SwitcherSession.userPickedSelection`.
    let userPickedSelection: Bool
    let restoreDefaultOnSearchClear: Bool
    let bestMatchOnSearchChange: Bool
}

/// What the kernel recommends. Wrapper translates this into side effects (highlight redraws,
/// scroll-to-visible, thumbnail preview, etc.).
enum SelectionDecision: Equatable {
    /// Post-firstVisible-guard empty case. Wrapper: clear `selectedTarget` and `hoveredIndex`.
    case clearTargetAndHover

    /// "From scratch" initial-pick path with a valid pick. Wrapper: clear hovered + reset
    /// `selectedTarget` first, then move selection to `index`.
    case resetThenSelect(Int)

    /// "From scratch" but list has nothing to land on (e.g. search-clear with no visible).
    /// Wrapper: clear hovered + reset `selectedTarget`; leave `selectedIndex`.
    case resetWithoutSelection

    /// Move selection to `index`. `selectedTarget` follows to `list[index].id`.
    case selectAt(Int)

    /// `selectedIndex` is fine; just ensure `selectedTarget == list[index].id` (backfill).
    case ensureTargetSet(Int)
}

enum SelectionResolver {
    /// Pure port of `Windows.updateSelectedWindow`. Branching order matches the original so the
    /// behavior-preserving extraction can be verified against the running app before we touch
    /// the logic.
    static func decide(_ i: SelectionInputs) -> SelectionDecision {
        // 1) Search-clear path takes precedence — runs even when no visible windows.
        if i.restoreDefaultOnSearchClear {
            return resetInitialPick(i)
        }
        // 2) Empty visible list.
        let visibleIndexes = i.list.indices.filter { i.list[$0].visible }
        guard let firstVisibleIndex = visibleIndexes.first else {
            return .clearTargetAndHover
        }
        // 3) Search-best-match path.
        if i.bestMatchOnSearchChange {
            return .selectAt(firstVisibleIndex)
        }
        // 4) Re-pick from scratch while the selection is still just the DEFAULT — no target yet, or the user
        // hasn't moved it. The window set is still settling as the switcher opens (tabs group, Spaces settle),
        // so a default computed a moment ago may no longer BE the second visible window; re-deriving keeps it
        // meaning "the window you were on before". Only a target the USER chose is followed by id below —
        // that's what must not jump when AX events reorder the list mid-show (#5665). Conflating the two made
        // the default lock onto whatever occupied the slot mid-churn and then trail it across the list.
        if i.selectedTarget == nil || !i.userPickedSelection {
            return resetInitialPick(i)
        }
        // 5) Try to restore the user's chosen target by id.
        if let targetIndex = findTarget(i.list, i.selectedTarget) {
            return .selectAt(targetIndex)
        }
        // 6) Target gone — adapt to the closest visible.
        return adapt(i, visibleIndexes: visibleIndexes, lastVisible: visibleIndexes.last!)
    }

    /// Mirrors `setInitialSelectedAndHoveredWindowIndex` — picks the index, defers reset to wrapper.
    static func initialPickIndex(_ i: SelectionInputs) -> Int? {
        if i.useLastFocusedRule, let idx = getLastFocusedOrderWindowIndex(i.list) {
            return idx
        }
        // Edge case: top two windows both minimized — land on index 0 rather than cycling past.
        if i.list.count >= 2 && i.list[0].isMinimized && i.list[1].isMinimized {
            return i.list[0].visible ? 0 : nil
        }
        return secondVisibleIndexAsOfSummon(i.list, i.visibleCountAtSummon)
    }

    /// `secondVisibleIndex`, over the MRU as it stood when the shortcut was pressed.
    ///
    /// The list itself must keep showing the truth: a window created and focused behind the switcher takes
    /// tile 0 and pushes everything along. But the user pressed the shortcut to get back to the window they
    /// were on before, and that intent does not change because something else appeared afterwards. Stepping
    /// over such a newcomer keeps "previous window" meaning what it meant at the moment of the press, while
    /// the tiles around it move.
    ///
    /// **Only an arrival pushes the pick along; a replacement does not.** A newcomer can also take a tile
    /// that another window just gave up, and then nothing moved down for the pick to compensate for. Live
    /// case: two Finder windows with tabs, switch a tab, summon. The incoming tab is a window the model had
    /// never seen (untracked inactive tabs are the norm), so it is a newcomer at tile 0 — but the tab it
    /// replaced left the drawn list in the same breath, so tile 1 is still the other Finder window. Stepping
    /// over the newcomer aimed one tile past it, at an unrelated app. The two are told apart by the length of
    /// the list: newcomers are stepped over from the front only while the list is LONGER than it was at the
    /// summon, which is exactly how many of them arrived rather than replaced.
    ///
    /// This is not a pin to one window: it is re-derived every time, so a correction that tells us who was
    /// really frontmost at the press re-answers the question (a correction re-orders windows that were
    /// already there, so none of them is a newcomer), and a window that closes or stops being drawn simply drops out of the answer.
    /// When stepping over leaves nothing to land on, the plain rule takes over.
    static func secondVisibleIndexAsOfSummon(_ list: [SelectionWindow], _ visibleCountAtSummon: Int) -> Int? {
        let visible = list.indices.filter { list[$0].visible }
        var arrivals = max(0, visible.count - visibleCountAtSummon)
        var asOfSummon = [Int]()
        for index in visible {
            if arrivals > 0 && list[index].appearedAfterSummon {
                arrivals -= 1
            } else {
                asOfSummon.append(index)
            }
        }
        guard let current = asOfSummon.first else { return secondVisibleIndex(list) }
        return asOfSummon.count > 1 ? asOfSummon[1] : current
    }

    /// The default pick: the PREVIOUSLY-focused window, i.e. the SECOND visible window in MRU order — you
    /// summon the switcher to get back to the window you were on before this one. Wraps to the only visible
    /// window when there is just one; nil when none is visible.
    ///
    /// Counts VISIBLE windows, not raw indices. It used to start at index 1, assuming index 0 was the current
    /// window — but hidden windows sit in the MRU too: a background tab is fronted the moment it's discovered
    /// and then hidden once it's grouped, so index 0 can be hidden and index 1 IS the current window. Starting
    /// at 1 then selected the current window itself (captured live: `-0:Finder#73841(tfh) *+1:Finder#73377(f)`
    /// — the selection landed on the leftmost tile instead of the one behind it).
    static func secondVisibleIndex(_ list: [SelectionWindow]) -> Int? {
        let visible = list.indices.filter { list[$0].visible }
        guard let current = visible.first else { return nil }
        return visible.count > 1 ? visible[1] : current
    }

    /// Returns the index of the visible non-windowless window with the lowest `lastFocusOrder`.
    static func getLastFocusedOrderWindowIndex(_ list: [SelectionWindow]) -> Int? {
        var bestIndex: Int? = nil
        var bestOrder = Int.max
        for (idx, w) in list.enumerated() {
            if !w.isWindowlessApp && w.visible && w.lastFocusOrder < bestOrder {
                bestOrder = w.lastFocusOrder
                bestIndex = idx
            }
        }
        return bestIndex
    }

    /// Find the user's chosen window by id, returning its current index if visible.
    /// Mirrors the lookup in the old `Windows.restoreSelectionTargetIfVisible`.
    static func findTarget(_ list: [SelectionWindow], _ targetId: String?) -> Int? {
        guard let targetId else { return nil }
        return list.firstIndex { $0.id == targetId && $0.visible }
    }

    // MARK: - Internal

    private static func resetInitialPick(_ i: SelectionInputs) -> SelectionDecision {
        if let idx = initialPickIndex(i) {
            return .resetThenSelect(idx)
        }
        return .resetWithoutSelection
    }

    /// Mirrors `adaptSelectionToVisibleIndexes`. `visibleIndexes` is non-empty by caller's guard,
    /// and `decide()` only invokes `adapt` after the `selectedTarget == nil` early-return — so
    /// the only branching here is "is `selectedIndex` still in `visibleIndexes`?"
    private static func adapt(_ i: SelectionInputs, visibleIndexes: [Int], lastVisible: Int) -> SelectionDecision {
        if !visibleIndexes.contains(i.selectedIndex) {
            let closest = visibleIndexes.last(where: { $0 < i.selectedIndex }) ?? lastVisible
            return .selectAt(closest)
        }
        // selectedIndex is in visibleIndexes (so it's already between firstVisible and lastVisible),
        // and the target is set (non-nil) by decide()'s contract. Return an idempotent target
        // backfill — the wrapper treats a no-change as a no-op.
        return .ensureTargetSet(i.selectedIndex)
    }
}
