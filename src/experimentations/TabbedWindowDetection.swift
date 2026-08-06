// Tabbed Window Detection — Investigation Results
// =================================================
//
// macOS provides no public API to detect whether a window is an inactive OS tab.
// This file documents all approaches tested and their results.
//
// Test setup: Finder with 2 tabbed windows ("lwouis" inactive tab, "git" active tab)
// and 1 non-tabbed window ("Movies").
//
// MARK: - Approaches that DON'T work
//
// 1. CGWindowListCopyWindowInfo
//    Returns the fewest windows. Inactive tabs don't appear at all.
//    Can't distinguish "absent because tabbed" from "absent for other reasons."
//
// 2. CGSCopyWindowsWithOptionsAndTags (current heuristic)
//    Comparing include-invisible vs exclude-invisible lists: inactive tabs appear
//    in the include-invisible list but not the exclude-invisible list. However, so
//    do windows from apps like Teams/WeChat that hide windows without destroying
//    them. This is the source of false positives in the current detection.
//
// 3. SCShareableContent (macOS 13+)
//    Returns the most windows (including inactive tabs). However isActive=false and
//    isOnScreen=false for inactive tabs — same as for hidden, minimized, and
//    other-space windows. No distinguishing signal.
//
// 4. SLSWindowIterator (parentId, tags, attributes, attachedWindows, spaceAttributes)
//    - parentId: returns 0 for all tested windows (tabbed and non-tabbed)
//    - attachedCount/attachedWindows: always 0/empty for tabbed windows
//    - spaceAttributes/spaceTypeMask: no difference between tabbed and non-tabbed
//    - tags (UInt from iterator): different patterns exist between visible and invisible
//      windows, but the same pattern applies to both inactive tabs AND other invisible
//      windows (hidden apps, other-space windows). No tab-specific bit.
//
// 5. SLSGetWindowTags (64-bit tags)
//    Compared binary tag patterns across window states:
//      Active tab (git):    1100000000000000000000000100000000010010000010000000000001
//      Non-tabbed (Movies): 1100000000000000000000000100000000010010000010000000000001
//      Inactive tab (lwouis): 1100000000000000000000000100000000010010000000000000000001
//    The inactive tab differs in a few bits, but the same pattern appears for hidden
//    and other-space windows. Not a reliable tab-specific signal.
//
// 6. SLSGetWindowSubLevel
//    Returns 0 for all normal layer-0 windows regardless of tab state.
//
// 7. CGSCopyWindowGroup (movementGroup, orderingGroup, tabGroup, tabbingGroup)
//    - movementGroup: empty for tabbed windows
//    - orderingGroup: empty for tabbed windows
//    - tabGroup: empty (speculative key, doesn't exist)
//    - tabbingGroup: empty (speculative key, doesn't exist)
//
// 8. CGSCopyWindowProperty (broad key sweep)
//    Tested ~40 speculative keys including kCGSWindowTabGroupID, kCGSWindowIsTab,
//    kCGSWindowTabParent, kCGSWindowTabIndex, kCGSWindowTabbingIdentifier,
//    kCGSWindowContainerID, TabGroupID, IsTab, etc.
//    Only kCGSWindowTitle returned values. No tab-related properties exist.
//
// 9. SLSCopyAssociatedWindows
//    Returns only the queried window itself. No sibling information.
//
// 10. Frame-based clustering (CGWindowListCopyWindowInfo frame comparison)
//     Grouping same-pid windows by identical frame: the active tab's frame is known,
//     but inactive tabs have a DIFFERENT frame (their last known position before being
//     tabbed). Only works if tabs were at the same position before merging, which is
//     not guaranteed. Unreliable.
//
// MARK: - Approach that WORKS: AXTabGroup (Accessibility API)
//
// Querying kAXChildrenAttribute on a window's AXUIElement reveals an AXTabGroup child
// element when the window has OS-level tabs. The AXTabGroup's children are the individual
// tab buttons. This provides a definitive, reliable signal.
//
// How it works:
// 1. Get kAXChildrenAttribute on the window's AXUIElement
// 2. Find the child with kAXRoleAttribute == "AXTabGroup"
// 3. Get that child's kAXChildrenAttribute
// 4. Filter children to those with kAXSubroleAttribute == "AXTabButton"
//    (this excludes the "+" button which has role=AXButton, subrole=nil)
// 5. Each AXTabButton has:
//    - kAXTitleAttribute: the tab's title (matches the window title)
//    - kAXValueAttribute: 1 for active tab, 0 for inactive tab
//    - _AXUIElementGetWindow: returns the parent window's WID (not individual tab WIDs)
//
// Example output for Finder with tabs "lwouis" and "git" (git is active):
//   AXTabGroup has 3 children:
//     [0] role=AXRadioButton subrole=AXTabButton title='lwouis' value=0
//     [1] role=AXRadioButton subrole=AXTabButton title='git'    value=1
//     [2] role=AXButton      subrole=nil          title=''      value=nil  ← "+" button
//
// Non-tabbed windows (e.g. "Movies") have no AXTabGroup child at all.
//
// Properties:
// - Definitive: presence of AXTabGroup = tabbed, absence = not tabbed
// - Rich: provides tab count and all tab titles
// - Public API: uses standard Accessibility framework (no private APIs needed)
// - Works cross-space: querying via an existing AXUIElement reference works even
//   when the window is on a different Space (unlike kAXWindowsAttribute on the app
//   element, which only returns windows on the current Space)
// - Limitation: _AXUIElementGetWindow on tab buttons returns the parent window WID,
//   not individual tab WIDs. Matching tabs to windows must use title comparison.
//
// Implementation: see AXUIElement.tabGroupInfo() in src/api-wrappers/AXUIElement.swift
//
// MARK: - CORRECTION (probed 2026-07-26/27, macOS 26): in FULLSCREEN it is APP-DEPENDENT
//
// "Fullscreen windows expose no readable AXTabGroup" became settled lore in the tab-detection code, and
// several rules were built to work around it (geometry as the only grouping path for fullscreen; the
// fullscreen clause in the geometry confirmation gate; the assumption that a fullscreen active can never
// reach matchSiblings). It is not what macOS does. It was step 1 above — "get kAXChildrenAttribute on the
// window" — looking only at DIRECT children.
//
// Probed by driving a real multi-tab window of each app through Enter Full Screen and dumping the subtree:
//
//   app            windowed              fullscreen                     verdict
//   Finder         AXWindow/AXTabGroup   AXWindow/AXGroup/AXTabGroup    readable
//   Script Editor  AXWindow/AXTabGroup   AXWindow/AXGroup/AXTabGroup    readable
//   Terminal       AXWindow/AXTabGroup   (nothing, at any depth)        NOT readable
//   TextEdit       AXWindow/AXTabGroup   (nothing, at any depth)        NOT readable
//   Notes          (no native tabs — no "Merge All Windows" either)
//   Safari         AXWindow/AXSplitGroup/AXTabGroup with 0 AXTabButton — browsers draw their own tabs, so
//                  this is the expected answer and the >= 2 AXTabButton test already rejects it
//
// WHY the split — and the first answer here was WRONG, which is worth keeping. It looked like the tab bar
// was dropped from the tree in fullscreen ("a titlebar accessory that only some apps re-host"). It is not.
// Terminal's fullscreen tab bar EXISTS, at the same path as Finder's; a coordinate hit-test lands on it:
//
//   AXTabGroup(3 children)  ←  AXGroup(1)  ←  AXWindow(2 children)  ←  AXApplication
//
// The AXGroup's PARENT is the window; the window's own children are [AXSplitGroup, AXStaticText] and do not
// include it. The child→parent link is there, the parent→child link is not, so no downward walk can reach
// it at any depth. Ruled out as explanations:
//   - a DELAY: 12s of retries, nothing;
//   - a SEPARATE overlay window: the app has exactly one AXWindow in fullscreen;
//   - the bar entering the tree only once REVEALED: gliding the pointer to the top edge changed nothing;
//   - a DIFFERENT children list: AXChildrenInNavigationOrder and AXVisibleChildren miss it too;
//   - LAZY generation: a hit-test does not add it to kAXChildren afterwards, on a fresh handle either.
// Finder and Script Editor list the group properly, which is the whole difference between the two columns.
//
// Accessibility Inspector DOES show that tab bar under the window, hosted by an NSToolbarFullScreenWindow —
// a separate AppKit window for the fullscreen toolbar. Inspector builds its hierarchy from the ANCESTRY of
// the element you pick, which is why it can show what a downward walk cannot reach. The toolbar host is not
// in kAXWindows (1 window) nor among the application's children (3: the window, the menu bar, and an
// AXFunctionRowTopLevelElement).
//
// Hit-testing is thus the only route, and it is a VIABLE one — better than first assumed. It works from
// coordinates computed off the window's own frame, with the pointer parked elsewhere, and the result can be
// proven to belong to the window:
//
//   fullscreen window frame (0,36,2048,1116) → hit-test the strip just above the content origin
//   downward walk: nothing        hit-test: ["~", "~"]      (mouse at the bottom of the screen)
//
// Proof of ownership: walk the hit element's parents to the enclosing AXWindow and compare _AXUIElementGetWindow
// against the window you asked about; a hit on some other app's window (or another window occluding the
// strip) fails that test and yields nothing rather than the wrong tabs.
//
// AND THE PRIVATE APIs NAME THAT WINDOW, which removes the guesswork. SLSCopyAssociatedWindows on the
// fullscreen wid returns the toolbar window alongside it (item 9 above says it "returns only the queried
// window itself" — true for a WINDOWED window, where no toolbar window exists; in fullscreen it returns
// both):
//
//   SLSCopyAssociatedWindows(35416) → [35420, 35416]
//     wid=35420  bounds=(0,0 2048x68)      ← the toolbar / tab-bar strip
//     wid=35416  bounds=(0,36 2048x1116)   ← the fullscreen content window
//
// So the full chain is: fullscreen wid → SLSCopyAssociatedWindows → the other wid → its EXACT bounds from
// CGWindowList → hit-test inside them → walk the hit element's parents to an AXWindow → require that wid to
// be ours → read the AXTabGroup passed on the way. Verified end to end (2026-07-27):
//
//   Terminal   fullscreen: downward walk nothing → chain ["~", "~", "~"]
//   TextEdit   fullscreen: downward walk nothing → chain ["Untitled 4", "Untitled", "Untitled 2", ...]
//   Finder     fullscreen: downward walk works   → chain agrees
//   all three, WINDOWED: the association has one entry, and the chain correctly returns nothing
//
// Sample SEVERAL points inside the strip: it overlaps the content window (68 tall, content starts at 36),
// so its centre can land in a transparent region where the hit-test returns the window underneath. A miss
// at one point is not a verdict — that mistake made the first version of this chain report nothing.
//
// NOT implemented in AltTab. Remaining costs, for whoever picks it up: it needs the window ON SCREEN (a
// fullscreen window on another Space fails the wid check and yields nothing — safe, but no answer), and it
// spends one CGS call plus up to a dozen AX hit-tests per fullscreen window per read.
//
// METHOD: the "titlebar accessory" story came from a probe whose Terminal window had only ONE tab — the
// screenshot showed a single title pill. Verify the SETUP produced the state you meant to measure before
// concluding anything from an empty result.
// Nor is there any tab-related ATTRIBUTE on the window to fall back on — the fullscreen window's attribute
// list contains none — so the element tree is the only route either way.
//
// NOT ADOPTED. Descending one level into AXGroup children was written and reverted: it works, but it buys
// fullscreen tab reading for Finder and Script Editor and not for Terminal and TextEdit, and that asymmetry
// is worse than the gap. A fullscreen active that can suddenly read its tabs reaches `matchSiblings`, where
// nothing stopped it claiming a windowed window's tab (the title matches under Finder's duplicate titles,
// and `positionsCompatible` waives the frame test for fullscreen) — a real window hidden, for a capability
// the model does not need: fullscreen grouping is the geometry path's job, since a fullscreen Space holds
// one window and its tabs. See the doc comment on `AXUIElement.tabGroupInfo`.
//
// What this correction changes is the REASONING, not the code: "fullscreen exposes no readable AXTabGroup"
// is not a fact about macOS, it is a fact about a downward walk. The rules built on it still earn their
// keep (Terminal and TextEdit really do expose nothing reachable), so this is not a licence to delete them.
// See TabGroupResolverSpecs.md and TestScenarioSimulatorSpecs.md.
//
