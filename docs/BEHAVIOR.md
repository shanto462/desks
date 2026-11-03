# Desks: exact behavior (as implemented)

This file describes what the code does today. It was written by reading all of `Sources/DesksCore/*.swift` and `Sources/Desks/*.swift`, plus `scripts/desks`.

How to read it:

- File names and function or constant names in brackets show where a number or rule lives. Example: `[LiveEngine.swift, performSwitch]`.
- "Layout id" is the internal number, 0 to 9. "Layout number" is what the user sees, 1 to 10.
- "Display" means one connected screen. Each display has its own layouts.
- All window moves use the macOS Accessibility (AX) API. Coordinates are AX coordinates (top-left origin, y goes down).

Contents

1. Layouts per display
2. Creating and removing layouts
3. Switching layouts
4. New windows and which windows are tracked
5. Sticky windows
6. Move overlay
7. Rules
8. Apps to open
9. Saved arrangements
10. Displays
11. Persistence
12. Pause, rescue, quit, Accessibility revoked
13. The bar
14. Menu bar menu and Settings pages
15. URL scheme and CLI
16. Default keyboard shortcuts
17. Known limitations and private API calls
18. Timing and limit reference

---

## 1. Layouts per display

- Every display has its own list of layouts and its own "current" layout. Displays are keyed by the macOS display UUID `[Displays.swift, Screens.uuid]`.
- A new display starts with one layout, id 0, named "First" `[LayoutModel.swift, ensureDisplay]`.
- Maximum 10 layouts per display: ids 0 to 9 `[LayoutModel.swift, maxLayoutId = 9, appendLayout]`.
- Ids are always compact: 0 to count-1, with no gaps. When a layout is removed, higher ones move down by one `[LayoutModel.swift, removeLayout]`. Old state files with gaps are compacted when loaded `[LayoutModel.swift, compactOnLoad]`.
- The first layout (id 0) always exists. It cannot be deleted `[LiveEngine.swift, deleteLayout]` and it is never removed automatically `[LiveEngine.swift, isDisposable]`. Loading a state file without id 0 adds it `[LayoutModel.swift, load]`.
- Id 0 is also the fallback: a window whose saved layout no longer exists goes to layout 0 `[LiveEngine.swift, adopt]`, and a deleted layout's windows go to layout 0.

### Numbering seen by the user

| Where | Layout id 0 | Layout id 8 | Layout id 9 |
|---|---|---|---|
| Bar chip, menu, overlay, Settings badge | 1 | 9 | 0 |
| Shortcut digit (ctrl+option+digit) | 1 | 9 | 0 |
| URL and CLI (`switch N`, `move N`) | 1 | 9 | 10 |
| Rule picker ("Layout N") | 1 | 9 | 10 |

The digit label is `(id + 1) % 10` `[AppModel.swift, LayoutInfo.keyLabel]`. So the tenth layout shows "0" on the bar and uses the 0 key, but it is "10" in URLs, the CLI and the rule picker.

### Names

- Default name is an ordinal word of the id: First, Second, Third, Fourth, Fifth, Sixth, Seventh, Eighth, Ninth, Tenth `[LayoutModel.swift, ordinals, defaultName]`.
- Rename: from the bar right-click menu "Rename..." (a small dialog, "Leave it empty to use the default name"), or by editing the name in Settings > Layouts and pressing Return (also saved when the row disappears) `[AppModel.swift, promptRename]`, `[SettingsPages.swift, LayoutRow]`.
- Rules for a name `[LayoutModel.swift, renameLayout]`: trimmed; empty or digits only becomes the default ordinal name; longer than 40 characters is cut to 40.
- When a layout moves down after a removal, a default name follows the new position ("Third" becomes "Second"). A custom name stays `[LayoutModel.swift, removeLayout]`.
- On load, old names "Main", empty names and digits-only names become the default ordinal `[LayoutModel.swift, migratedName]`.
- Names are compared with the default name of the id, as text. A custom name that equals the default ordinal of its own position counts as "not renamed".

---

## 2. Creating and removing layouts

### Creating

- A shortcut digit for a layout that does not exist does nothing to the windows. The bar of that display shakes (see section 13) as feedback. With Reduce Motion on, there is no shake `[AppModel.swift, switchFromHotkey]`, `[Bar.swift, shake]`.
- The URL `desks://switch/N` and the CLI for a missing layout do nothing, with no feedback `[LiveEngine.swift, performSwitch: "A switch to a missing layout does nothing"]`.
- "New layout" (the "+" chip, Settings "Add Layout", menu "New Layout", ctrl+option+N, `desks://new`) `[LiveEngine.swift, createLayout]`:
  - adds one empty layout at the end (id = count) and switches to it;
  - it is created with the default name, no apps to open, no arrangement;
  - if all 10 exist, nothing is created and the system beep plays `[AppModel.swift, createLayout]`;
  - the "+" chip is hidden when there are 10 layouts `[Bar.swift, ChipRow canAdd]`; "Add Layout" in Settings is disabled at 10.
- If the layout you are on is empty and unnamed, "New layout" has no visible effect: the new layout is added, you switch to it, and the old empty one is removed, so the new one takes its number.
- Moving a window to a missing layout does not do nothing: it adds one layout at the end (section 6).

### Automatic removal

When you leave a layout, it is removed if all of these are true `[LiveEngine.swift, isDisposable]` `[LayoutModel.swift, isDefaultAndUnused]`:

- it is not the first layout;
- it has zero windows (sticky windows do not count; windows of a closed app that are waiting to come back, see section 11, do count);
- it still has its default name;
- it has no apps to open and no saved arrangement;
- no enabled rule points at that layout number (an enabled rule protects layout N from automatic removal, on every display).

This runs in every switch, including a switch caused by focus (Cmd-Tab). It does not run when a layout becomes empty while you are on it, or when you stay on it. It also happens at app launch: empty default-named layouts that are not first and not current are dropped from the saved file `[LayoutModel.swift, compactOnLoad]`.

### Deleting

- Delete is in the bar (hover badge, right-click "Delete") and in Settings > Layouts (trash button). There is no confirmation `[Bar.swift, DeleteBadge]`, `[SettingsPages.swift, LayoutRow]`.
- All windows of the deleted layout move to the first layout (id 0). Sticky windows are not touched `[LayoutModel.swift, removeLayout]`.
- If the deleted layout was the current one, Desks switches to the first layout. If not, placement is re-synced: if the first layout is the current one, the moved windows appear on screen `[LiveEngine.swift, deleteLayout]`.
- The deleted layout's apps to open and saved arrangement are gone with it. Its MRU list is merged into the first layout's MRU.

### What happens to numbers after a removal (delete or automatic)

| Thing | What happens |
|---|---|
| Layouts above the removed one | Move down by one: id and number change. |
| Default names | Follow the new position. |
| Custom names | Stay with the layout. |
| Windows | The removed layout's windows go to id 0. Windows of higher layouts get id minus 1. Windows of the same display that were orphans (see section 10) are shifted the same way on the main display. |
| The current layout | Id is shifted the same way. |
| Apps to open, saved arrangement | They are stored on the layout, so they move with it. They are lost if their own layout is deleted. |
| Waiting saved windows (relaunch matching) | Shifted the same way. |
| Launch targets (apps to open, 15 s) | Shifted; a target for the removed layout is dropped. |
| Shortcuts | Shortcuts are by number (position), not by layout. Nothing is remapped. Shortcut 3 always means "the third layout that exists now". |
| Rules (global, by number) | Rule targets are fixed numbers. They never shift when a layout is removed. A rule that points at a number that no longer exists adds one layout at the end when it matches (section 7). |

Rules are not remapped on load either.

---

## 3. Switching layouts

### How a switch starts

- By shortcut, bar click, menu item, Settings "Show", URL, CLI: `switchTo` or `switchRelative`. Switching to the current layout does nothing `[LiveEngine.swift, switchTo]`.
- Previous/next wraps around the layouts that exist on the display. With one layout it does nothing `[LiveEngine.swift, switchRelative]`.
- By focus: Cmd-Tab, clicking a parked window's app, or any focus into a parked window (see below).
- Display used when none is given: the display of the focused window, else the last display where a managed window had focus, else the main display `[LiveEngine.swift, resolveDisplay]`.

### Order of work in one switch `[LiveEngine.swift, performSwitch]`

1. Set the new current layout.
2. Drop launch targets for the layout you just left (same display).
3. If "Restore saved arrangement when switching" is on: set the pinned frames of the target layout as home frames (section 9).
4. If the switch came from `switchTo` or `switchRelative`: launch the layout's apps to open (section 8).
5. If the layout you left is empty and unnamed: remove it (section 2).
6. Ignore focus-driven switches for 0.5 s.
7. Sync windows (see below), then set focus.

### Show first, then park `[ParkingEngine.swift, sync]`

1. Windows that must be visible but are parked (or flagged) are moved to their home frame first, each on its own app queue.
2. The park phase starts when all shows are done, or after 0.25 s, whichever is first. A slow app does not hold back the others.
3. Before any park is sent, the crash journal is written to disk (section 11).
4. Windows of other layouts are parked.

Windows that are minimized or in native full screen are skipped: never parked, never moved `[LiveEngine.swift, syncPlacements]`.

### Show a window `[ParkingEngine.swift, show, move]`

- If the size differs by more than 1 pt: set size, position, size (the order AeroSpace found to work). Otherwise only position.
- AXEnhancedUserInterface is switched off on the app during the move and restored after.
- Verify: the final position must be within 2 px of the target. If not, wait 50 ms and try once more. That is one retry.

### Park a window `[ParkingEngine.swift, sendPark]`

- Only the position changes. The size is not changed.
- Verify within 2 px. If not, wait 30 ms and retry once.
- The frame before parking is saved as the window's home frame (only for windows that were visible and not already in a corner) `[LiveEngine.swift, parked]`.

### Where windows are parked `[Displays.swift, parkCorners, parkPoint]`

- Corner choice is per display, set in Settings > General "Hide windows in": Auto (best corner), Bottom left, Bottom right. Default: Auto `[EngineOptions.ParkCorner]`.
- Auto: for each side Desks checks three points just outside the display (2 px outside the edge; at 10% of the height or width from the bottom corner; and the diagonal corner point, which counts 10). It counts how many connected displays contain those points. The side with the lower score wins. A tie goes to bottom right.
- If the chosen corner still touches another display, a warning is shown (see section 14).
- The park point is on the display's visible frame (so the Dock and menu bar are excluded):
  - bottom right: top-left corner of the window at (maxX - 1, maxY - 1);
  - bottom left: right edge of the window at minX + 1, top at maxY - 1.
- That leaves about 1 px of the window on screen (the "sliver").
- Zoom exception: for the bundle id `us.zoom.xos` the offset is 0 instead of 1, because Zoom jumps back with a 1 px offset `[Displays.swift, parkPoint]`.
- A window "looks parked" when no display shows more than 8 x 8 px of it `[Displays.swift, looksParked]`.

### If a window moves back by itself

- Parked window that comes back on screen (moved more than 4 px from its park point and not in a corner): Desks parks it again. At most 3 times per park target `[ParkingEngine.swift, requestRepark]`, `[LiveEngine.swift, updateKnown]`.
- Shown window that is still in a corner (slow app): Desks shows it again, at most 3 times `[LiveEngine.swift, showRetry]`.
- Events for a window in the first 1.0 s after Desks moved it are treated as Desks' own `[ParkingEngine.swift, isInTransit]`.

### Focus after a switch

- Switch by shortcut, bar and so on: Desks focuses the most recently used visible window of the target layout (the layout's MRU list, up to 30 entries `[LayoutModel.swift, mruLimit]`). A usable window is live, not minimized, visible, on that display. If none in the MRU list is usable, it picks any usable window on that display, non-sticky ones first `[LiveEngine.swift, focusMRU]`.
- If there is no window at all (empty layout), and the focused window is parked, Desks activates Finder so typing does not go into a hidden window. Focus-driven switches are ignored for 1.0 s after that `[LiveEngine.swift, focusAwayFromParked]`.
- Focus-driven switch (the window you went to is in another layout): Desks switches to that layout and focuses that exact window `[LiveEngine.swift, handleFocus]`.
- How a window is focused `[Focus.swift, focus]`: on the app's queue set AXMain and AXRaise; then activate the app. If after 0.15 s the app is still not frontmost, use the private SkyLight call and raise again.

### Cmd-Tab or focus into a parked window `[LiveEngine.swift, reconcile, handleFocus, scheduleFocusSwitch]`

- A real focus change, or an app activation (Cmd-Tab), makes Desks check the focused window of that frontmost app. A poll that sees the same focus does not switch.
- If the window is visible: only its MRU position is updated.
- If the window is parked in another layout: wait 0.15 s, then switch to its layout. The switch is dropped if:
  - the focus-switch block is still active (0.5 s after our own switch or move, 0.3 s after a close, 2.0 s after launch or resume);
  - that app closed, minimized, hid or quit something less than 0.6 s ago;
  - focus moved to another window, or the app is no longer frontmost.
- A new window that a rule or an apps-to-open launch put into a hidden layout does not switch layouts if it gets focus within 3 s. Desks focuses the MRU window of the visible layout instead `[LiveEngine.swift, autoPlacedAt]`.
- A dialog or panel (follower) of an app whose last focused window is parked: Desks switches to that window's layout, without changing focus (the dialog already has it).
- A focus-driven switch does not launch apps to open.

### After a close (Cmd-W, minimize, hide, quit) `[LiveEngine.swift, noteClose, focusAfterClose]`

- On a destroyed or minimized window event, app hide, app quit, or a window that vanished from the app's window list, Desks records the time, and blocks focus-driven switches for 0.3 s.
- After 0.35 s: if the frontmost app's focused window is shown, nothing happens. Otherwise Desks focuses the MRU window of the current layout on the last focused display (else main). If none, it hands focus to Finder if the focused window is parked.
- This stops macOS from throwing you into another layout because focus fell into a parked window.

### Verification summary

| What | Check | Retry |
|---|---|---|
| Show | within 2 px `[ParkingEngine.swift, landed]` | 1 retry after 50 ms |
| Park | within 2 px | 1 retry after 30 ms |
| Parked window came back | moved more than 4 px | at most 3 re-parks per target |
| Shown window still in a corner | looks parked | at most 3 re-shows |
| Pause or quit | verify every parked window | waits up to 2.5 s total `[LiveEngine.swift, stopManaging]` |
| AX call timeout | 0.5 s per element `[AXSupport.swift, messagingTimeout]` | none; only that app's queue waits |

---

## 4. New windows and which windows are tracked

### Which apps

Only apps with a normal Dock presence (activation policy "regular") are watched. Desks itself is excluded. Background and menu-bar-only apps are not watched `[WindowTracker.swift, scanApps]`. If AX cannot be set up for an app, Desks retries up to 15 times on its 4 s scan `[WindowTracker.swift, scanApps]`.

### Which windows become members

A window becomes a member of a layout only if all of these are true `[LiveEngine.swift, reconcile]` `[WindowTracker.swift, LiveWindow.isStandard]`:

- AX role is a window and subrole is "standard window";
- it is not minimized;
- width at least 30 and height at least 30;
- it has a window id (private API) and a readable frame;
- the app is not hidden (Cmd-H) at that moment;
- it is not ignored by a rule.

### Dialogs and floating windows (followers)

- Windows with subrole dialog, floating window or system dialog are not members `[WindowTracker.swift, isFollower]`.
- They follow the layout of their app's last focused member window. They are parked and shown with it. Their own home frame is remembered `[LiveEngine.swift, followers, followerHome, syncPlacements]`.
- If the app has no known leader window, the follower is never parked (and is shown again if Desks parked it before).
- Other kinds of window (popovers, menus, unknown subroles) are ignored.

### Which layout a new window joins `[LiveEngine.swift, adopt]`

The display is the one that holds the center of the window frame (else the nearest, else the first). Then, in this order:

1. A window that matches a saved window from the last run or from a quit app: it gets that window's display, layout and sticky flag (section 11). Rules are not applied to it.
2. An app launched by "apps to open" in the last 15 s, first window only: that layout on that display (section 8).
3. The first enabled rule that matches (section 7): a layout, or sticky.
4. Otherwise: the current layout of that display.

An "ignore" rule is checked before all this: an ignored window never reaches adopt.

If a new window opens in a corner (for example after a crash), its home frame is moved to the middle of the display.

### Native tabs

There is no special code for native tabs. Desks only sees what AX lists. macOS lists a tabbed window group as one window, so the group is one member.

### Full screen

- A window in native full screen is never parked or moved, even if its layout is hidden `[LiveEngine.swift, syncPlacements, updateKnown]`.
- Its stored home frame is not updated while in full screen. A window first seen already in full screen gets its home frame when it leaves full screen (it does not keep the full screen frame as home).
- Windows on other Spaces or in full screen are not in the AX list but still exist. Desks checks `CGWindowList` and keeps them in the model `[WindowTracker.swift, existingWindowIds]`.
- The bar hides on a display while a full screen window is frontmost there, unless "Show the bar over full screen apps" is on (section 13).

### Closed windows

When an app answers fully and a known window is missing from its list and from `CGWindowList`, the window is removed from the model `[LiveEngine.swift, reconcile]`. If the app does not answer, nothing is treated as closed.

### Window events used `[WindowTracker.swift, event]`

| Event | Re-read after |
|---|---|
| Window created, element destroyed | 0.05 s, again at 0.5 s and 1.5 s |
| Focus changed, main window changed | at once |
| Moved, resized | 0.25 s (merged) |
| Minimized, deminimized | 0.05 s |
| App launched | scan now, and again after 1.0 s |
| App unhidden | 0.1 s |
| Space changed | 0.3 s |
| Poll (all apps) | every 4.0 s |

---

## 5. Sticky windows

- A sticky window is never parked. It is visible in every layout of its display `[LayoutModel.swift, isVisible]`.
- It is not counted in a layout's window count, it gives no app icon in the bar, and it is not in any MRU list. It is not saved in arrangements.
- Make sticky: ctrl+option+S, menu "Show Window in All Layouts", overlay row "S", `desks://sticky`, or a rule with action Sticky. Toggle works on the focused managed window `[LiveEngine.swift, toggleStickyFocusedWindow]`.
- Turn off sticky: the window joins the current layout of its display (the layout you see it in). For an orphan it joins the main display's current layout `[LiveEngine.swift, setSticky]`.
- Moving a window to a layout clears sticky `[LiveEngine.swift, moveWindow]`.
- Dragged to another display: the display changes, the layout number is not changed (sticky windows keep being visible) `[LiveEngine.swift, updateKnown]`.
- Rescue does not touch sticky windows.
- As a last choice, focus after a switch may land on a sticky window if nothing else is usable `[LiveEngine.swift, focusMRU]`.

---

## 6. Move overlay

Open with ctrl+option+M, menu "Move Window to...", or `desks://overlay`. The same call closes it if it is open `[AppDelegate.swift, openMoveOverlay]`.

- The window to move is captured before the panel takes focus: the focused managed window of the frontmost app `[LiveEngine.swift, focusedWindowToken]`. Dialogs and unmanaged windows are not valid. If Desks itself is frontmost (for example Settings), there is no target.
- The panel is centered on the display of the focused window, 10% of the height above the center. Window level is "modal panel". Width 340.
- Rows: one per layout of that display (key digit, name, "N windows", app icons up to 4, "Current" badge), then a divider and "All layouts (sticky)" with key "S". The sticky row shows a check when on and says "Pick it again to turn it off" `[MoveOverlay.swift, MoveOverlayModel.load]`.
- Start selection: the first row that is not the current layout.
- If there is no managed focused window: "No window to move. Click a window first, then try again." If there are no rows because of no Accessibility: "No layouts yet. Desks needs Accessibility access to see your windows."

Keys `[MoveOverlay.swift, handle]`:

| Key | Action |
|---|---|
| 1 to 9, 0 (also number pad by key code) | Pick that layout (0 is the tenth). A digit for a layout that is not listed is swallowed and nothing happens; the panel stays open. |
| S | Toggle sticky |
| Up, Down | Move selection (wraps) |
| Return, Enter | Pick selected row |
| Esc | Close |
| Any other key | Swallowed (the panel stays open) |

Mouse: hover selects a row, click picks it. Clicking outside the panel closes it (it resigns key) without handing focus back.

Targets: a layout of the same display as the window, or the sticky toggle.

Focus:

- The panel is a non-activating panel. If it cannot become key, Desks activates itself, and gives focus back to the previous app when the panel closes by Esc or pick (not when you click outside) `[MoveOverlay.swift, show, close]`.
- After a pick, the window moves. If the moved window was focused and its new layout is not the current one, it is parked and focus goes to the most recently used visible window of the current layout (else Finder if needed). If the target is the current layout, the window stays and focus stays `[LiveEngine.swift, moveWindow]`.
- Focus-driven switches are blocked for 0.5 s after a move.

Related, not from the overlay: the move shortcuts ctrl+option+shift+digit and `desks://move/N` call the same `moveWindow`. If the layout does not exist, one new layout is added at the end and the window goes there, whatever the digit was. If all 10 exist and the id is missing, nothing happens `[LiveEngine.swift, ensureLayout]`. An orphan window (its display is unplugged) becomes a window of the main display for good when moved `[LiveEngine.swift, moveWindow]`.

Move all windows: right-click a chip > "Move All Windows To" moves all non-sticky windows of one layout to another on the same display (disabled with 0 windows or with fewer than 2 layouts) `[LiveEngine.swift, moveAllWindows]`.

---

## 7. Rules

Rules are global (not per display). They are edited in Settings > Rules and stored in `state.json`.

### Fields `[Contract.swift, WindowRule]`

| Field | Meaning |
|---|---|
| `enabled` | On or off. |
| `bundleID` | Required. Exact match with the app's bundle id. An app with no bundle id cannot match (Desks gives it a fake id `pid.N`). |
| `titlePattern` | Optional. Empty or missing means any title. |
| `action` | Layout N, Sticky, or Ignore. |

### Title pattern

- It is a regular expression (`NSRegularExpression`), case-insensitive. It matches anywhere in the title (not anchored) `[LiveEngine.swift, compileRules, matchRule]`.
- The title is cut to 512 characters before matching `[LiveEngine.swift, maxTitleLength]`.
- The pattern may be at most 200 characters `[LiveEngine.swift, maxPatternLength]`.
- A pattern with a repeated group that already contains a repeat (like `(a+)+`, `(.*)*`, `(x+){2,}`) is refused as too slow `[LiveEngine.swift, hasNestedQuantifier]`. A `?` is not counted as a repeat. Escaped characters and `[...]` classes are skipped.
- A pattern that is too long, invalid or nested is skipped: that rule never matches, matching goes on with the next rule, and a warning is shown (section 14).
- In the rule row, the pattern is saved on Return or when the field loses focus (not per key). The row only checks that the regex is valid ("This is not a valid pattern."); it does not check the length or nesting `[SettingsRules.swift, RuleRow]`. Spaces at both ends are trimmed.

### Actions

| Action | Effect on a new window |
|---|---|
| Layout N | Joins layout N of the display it opened on. If that layout does not exist, one layout is added at the end and used (the same missing number reuses that new layout later). If all 10 exist, the window joins the current layout. |
| Sticky | Window is sticky. |
| Ignore | Window is never managed (never parked or moved). |

In the picker, layouts are listed from the focused window's display. "New layout at the end" stores the next number; "Layout N (not created yet)" is shown for a stored number that is too high `[SettingsRules.swift, RuleRow]`.

### Start state and order

- "Add Rule" (pick a running app or choose an app) adds a rule that is disabled, with action Layout 1 `[SettingsRules.swift, RulesPage]`. The user turns it on.
- Rules are checked top to bottom. The first rule that is enabled, has the same bundle id, and whose pattern matches (or has none) wins. Order is changed with the up and down buttons or the context menu `[LiveEngine.swift, matchRule]`.

### When rules are evaluated

- Only for new windows, once, when the window is first seen. Later title changes do not move a window.
- If the app has an enabled rule with a title pattern and the new window has no title yet, Desks waits up to 1.0 s (re-reading at 1.05 s) for a title. The wait data is dropped after 30 s `[LiveEngine.swift, waitForTitle]`.
- Order for a new window: wait for title, ignore rule, saved-window match, apps-to-open launch target, layout or sticky rule, current layout.
- Windows that match a saved window (relaunch, app reopened) are not run through layout or sticky rules.
- "Apply Now" (Settings > Rules, enabled when running and there is at least one rule) runs the rules on all windows already managed, as if new `[LiveEngine.swift, applyRulesToExistingWindows]`:
  - Layout N: window goes to that layout on its home display and is no longer sticky;
  - Sticky: window becomes sticky;
  - Ignore: the window is shown at its home frame (verified, with a journal entry kept until it is seen on screen), removed from the model, and kept as ignored.
- Ignored windows are remembered in memory only. Editing or deleting an ignore rule releases the windows it caught: they become managed again. They are also released by "Apply Now" when no ignore rule matches them, or when Desks restarts.

---

## 8. Apps to open

Set per layout and per display: Settings > Layouts > chevron on the row > "Open these apps when switching" > "Add App" (running apps with a Dock icon, or "Choose App..." in /Applications), or bar right-click "Apps to Open...". Duplicates and empty ids are removed `[LayoutModel.swift, setAppsToOpen]`.

### When it triggers `[LiveEngine.swift, performSwitch(launchApps:), switchTo, switchRelative]`

| Switch path | Launches apps? |
|---|---|
| Shortcut digit, bar chip click, menu item, Settings "Show", `desks://switch`, CLI `switch` | Yes |
| Previous or next (shortcut, `desks://next`, `desks://previous`) | Yes |
| Cmd-Tab or any focus-driven switch | No |
| New layout, delete layout, move window, rescue | No |
| Switching to the layout you are already on | No (nothing happens) |

### What is launched `[LiveEngine.swift, launchAppsToOpen]`

- For each listed bundle id: skipped if any process with that bundle id is already running, or if no app with that id is installed.
- Otherwise it is opened with `NSWorkspace.openApplication`, with `activates = false` (in the background, no focus steal).
- Desks remembers a launch target for that bundle id: (display, layout, expiry = now + 15 s) `[LiveEngine.swift, pendingTargets]`. One target per bundle id (a later one replaces an earlier one).

### The 15 second window and the first new window

- `takePendingTarget` is called when Desks adopts new windows of that app. It removes expired targets, and takes the target once. So only the first adopted window batch of that app within 15 s uses it. This counts even if that window matches a saved window. A later Cmd-N joins the current layout.
- That window joins the target layout (created at the end if missing) on the target display, and its home frame is moved into that display if its center is on another one `[Displays.swift, fit]`.
- If you leave the target layout (same display) before the window opens, the target is dropped.
- A window that an ignore rule catches never uses the target; the target waits until it expires.

---

## 9. Saved arrangements

A saved arrangement is a set of window frames pinned to one layout. Stored on the layout record in `state.json` `[LayoutModel.swift, LayoutRecord.arrangement]`.

### Save `[LiveEngine.swift, saveArrangement]`

- Which windows: non-sticky members whose placement is that layout on that display (orphans count on the main display).
- Frame saved: the window's live frame if it is visible, not minimized, not full screen and not in a corner. Otherwise its stored home frame (or orphan frame).
- Saved as `[x, y, width, height]` by the window's key (Desks' own id, which survives relaunch through matching, section 11). Windows are not matched by title or app at restore time.
- Save replaces the whole previous arrangement of that layout.
- Entry points: bar right-click "Save Arrangement" (disabled with 0 windows), Settings > Layouts row details "Save Arrangement", `desks://save-arrangement`, CLI, and an optional shortcut (no default). The last three act on the current layout of the focused window's display (or `?display=`).

### Restore `[LiveEngine.swift, restoreArrangement, applyArrangement]`

- For each pinned key whose window still exists, is not sticky, and is still in that layout on that display: its home frame is set to the pinned frame. If it is visible now, it is moved at the next sync with a forced move (size and position). If it is parked, it is only updated, and it appears there when shown.
- Windows without a pin, sticky windows, and windows that left the layout are not touched.
- Entry points: bar right-click "Restore Arrangement" (disabled when nothing is saved; works on the layout you clicked, not only the current one), Settings "Restore", URL, CLI, shortcut.
- "Restore saved arrangement when switching" (Settings > Layouts, saved in `state.json`) applies it automatically in every switch to a layout that has one, including focus-driven ones.
- A layout with a saved arrangement is never auto-removed.
- Pinned entries of windows that no longer exist stay in the stored arrangement until the next save.

---

## 10. Displays

### Identity and order

Displays are identified by UUID. The list is: main display first, then the others left to right `[Displays.swift, Screens.current]`. "Main" for Desks is the first in that list.

### Unplug

When a display disappears (after the delay below) `[LiveEngine.swift, applyScreenChange, placement]`:

- Every window whose home display is gone becomes an "orphan". It gets `orphanLayout` = the main display's current layout at that moment, and no orphan frame.
- Orphans count as members of the main display, in that fixed layout number (it does not follow the main display's current layout later).
- Their frame is the home frame fixed to the main display: kept if at least half of it is on some display, else centered on the main display with a minimum 200 x 150 `[Displays.swift, sanitize]`.
- The gone display's layouts stay in the saved state. They are not deleted.
- While orphaned, moving the window on the main display updates its orphan frame. Dragging it to another connected display (not main) makes it join that display for good, in that display's current layout. Moving it to a layout (overlay, shortcut) makes it a main display window for good.

### Reconnect

When the display comes back, its orphans lose the orphan data and are moved to their own display, layout and old home frame (forced move) `[LiveEngine.swift, applyScreenChange]`. The saved layouts of that display are used again.

### Drag a window between displays `[LiveEngine.swift, updateKnown]`

If a visible window's center ends up on another connected display (checked at each snapshot, 0.25 s after a move event, not during settle, not in the first 1.0 s after a Desks move):

- Its home display becomes that display;
- it joins that display's current layout (unless sticky);
- its home frame is the new frame, and its MRU position there is updated.

### Sleep, wake, display changes

- Wake, screens wake, and display parameter changes all call the same handler `[LiveEngine.swift, observeSystem, screensChanged]`.
- Settling: for 2.5 s after the event, window frame and display updates are ignored (screen frames may be stale).
- Delay: the real handling runs 2.0 s after the last event (new events cancel and restart the 2.0 s timer).
- The handler re-reads displays, adds layouts for new displays, recomputes park corners, handles unplug and reconnect (above), re-reads every app, and syncs placement.
- Before sleep, the state is saved at once.
- Bars: one per connected display with layouts; when a display disappears its bar is removed at once, and new displays get a bar `[Bar.swift, refresh]`.

---

## 11. Persistence

### Files `[Store.swift]`

Directory: `~/Library/Application Support/Desks/`

| File | Content | When written |
|---|---|---|
| `state.json` | version, displays (label, current layout, layouts with name, apps to open, arrangement), window records (fingerprints), rules, restore-on-switch flag. Pretty printed, sorted keys, atomic write. | About 1.0 s after the last change (debounced, each change restarts the 1.0 s) `[Store.swift, scheduleSave]`. Saved at once on quit, pause, and before sleep (not when Accessibility is revoked) `[Store.swift, saveNow]`. Encoding is on the main thread; the write is on a utility queue. |
| `journal.json` | One entry per parked window: pid, bundle id, window id, title, home frame. | At once, on the calling thread, before any park is sent. Skipped if unchanged. The file is deleted when the list is empty `[Store.swift, writeJournal]`. |
| `state.json.bad-<yyyyMMdd-HHmmss>` | A state file that could not be decoded, moved aside. | At load. Desks starts fresh and shows a warning. If the move fails, writes to `state.json` are blocked so the bad file is never overwritten. |

Window records hold: key, bundle id, title, subrole, index among the app's standard windows, home display, layout, sticky, home frame, window id, pid, orphan layout and frame. MRU lists are not saved; they start empty at each launch `[LayoutModel.swift, load]`.

UI settings are in UserDefaults (not in these files): bar visible, show over full screen, menu bar icon, bar size, opacity, chip style (`barChipStyle`), park corner, bar locked, bar positions per display, and the shortcuts (KeyboardShortcuts) `[AppModel.swift, Prefs]`.

### Crash journal restore `[LiveEngine.swift, rescueFromJournal]`

At every start of management (launch with Accessibility, resume, Accessibility granted later), after the tracker starts:

1. Read `journal.json`.
2. For each entry find the app: same pid and same bundle id, else the first running app with that bundle id. Entries of apps that are not running are dropped.
3. On the app's own queue, find windows of that app that look parked. Pick: same pid and same window id; else same title; else the first parked one. Not used twice.
4. Move it to its saved home frame (fixed to the display), with the verified show (section 3).
5. Entries that could not be verified stay in the journal and are removed once the window is seen on screen later.

### Matching windows after a relaunch `[LiveEngine.swift, adopt, matchScore]`

Saved windows wait in `pendingSaved`. For a new window of the same bundle id, a score is computed against each saved window:

| Point | Score |
|---|---|
| Same window id and same pid (Desks relaunched, app kept running) | +10 |
| Same non-empty title | +3 |
| Same subrole | +1 |
| Frame within 40 pt for x, y, width and height | +2 |
| Same index among the app's standard windows | +1 |

- A pair needs a score greater than 3.
- Pairs are taken from the highest score down. Each saved window and each live window is used once.
- A match keeps the saved key, display, layout and sticky flag. The home frame is updated from the live frame (unless in a corner or full screen). If the display is connected and the saved layout no longer exists, the window goes to layout 0. If the display is not connected, the window becomes an orphan.
- Saved windows that match nothing expire 600 s (10 minutes) after management starts `[LiveEngine.swift, beginManaging]`. They are also dropped from `state.json` after that time.
- Keep time for quit apps: when an app quits, its windows leave the model and wait 600 s (10 minutes) to return to their layouts if the app opens again `[LiveEngine.swift, appGone]`. A layout that only has such waiting windows is not auto-removed.

### Load-time clean up `[LayoutModel.swift, load, compactOnLoad]`

Layouts without id 0 get one; layouts are sorted by id; names are migrated; MRU is cleared; the current layout falls back to 0 if missing; empty default-named layouts (not first, not current) are removed and the rest renumbered.

---

## 12. Pause, rescue, quit, Accessibility revoked

### Pause `[LiveEngine.swift, pause, stopManaging]`

- From menu "Pause Desks", Settings > General toggle, or `desks://pause`. Only works while running.
- Every parked window is shown at its home frame (verified; up to 2.5 s total). Unverified ones stay in the journal. Tracking stops, state is saved, status becomes "paused".
- While paused, or while Accessibility is missing, switching, creating a layout and moving a window do nothing (shortcuts, bar, menu, URL and CLI). Nothing changes in the saved state.
- Layout membership and the current layout are kept. The bar is hidden. The menu bar icon is `pause.rectangle`.
- Resume (menu, toggle, `desks://resume`): starts management again. If Accessibility is missing, the status becomes "needs Accessibility". Windows are parked again at the first snapshot according to the current layouts. Apps that quit while paused are moved to the waiting list.

### Rescue "Bring all windows back" `[LiveEngine.swift, rescueAllWindows]`

What it does to layouts: it changes membership.

- Every non-sticky window moves into the current layout of its display (orphans: the main display's current layout).
- Windows that look parked are forced back to their home frame.
- Then every window of every regular app (other than Desks) that sits in a corner is moved to the middle of its display, even windows Desks does not manage (managed ones are skipped when running). Needs Accessibility.
- Layouts are kept, but they are empty except the current one. Empty unnamed ones are removed as you leave them.
- Entry points: menu "Bring All Windows Back" (enabled unless Accessibility is missing), ctrl+option+shift+R, Settings > Permissions & About "Bring Back...", `desks://rescue`. A confirmation dialog (Bring All Back, Cancel, Pause Instead) is shown for the menu item, the Settings button and `desks://rescue`. The shortcut ctrl+option+shift+R runs it at once, because it is the emergency key `[SettingsPages.swift, confirmRescue]`.
- To see everything without changing layouts, use Pause.

### Quit `[AppDelegate.swift, shutDownEngine]` `[LiveEngine.swift, shutdown]`

- Quit from the menu (Cmd-Q), or SIGTERM, SIGINT, SIGHUP: all parked windows are shown (verified, up to 2.5 s), the journal keeps any unverified ones, state is saved at once, the timer stops.
- A crash or SIGKILL does not run this. The journal is used at the next launch.
- Opening the app again (Dock or Finder) opens Settings.

### Accessibility missing or revoked `[LiveEngine.swift, start, onTimer]`

- At launch without permission: status is "needs Accessibility". Desks asks for it once per launch (system prompt). The Settings window opens on "Permissions & About" `[AppDelegate.swift]`.
- A 1 s timer checks trust. If trust appears, Desks starts managing (and restores the journal).
- If trust is taken away while running: tracking stops at once, nothing can be moved back, status becomes "needs Accessibility", the bar disappears, the menu icon is `exclamationmark.triangle` and the menu shows "Desks needs Accessibility access" with "Open Accessibility Settings...". The journal on disk is kept as is. When trust returns, the journal restore runs.

---

## 13. The bar

### What it is `[Bar.swift, BarController]`

A small pill panel, one per display. It does not take focus (non-activating, never key). It floats above normal windows (window level "status bar"), on all Spaces, and ignores Cmd-Tab and window cycling. It is shown only while Desks status is "running" (hidden when paused or without Accessibility).

### Visibility

- "Show the layout bar" (Settings > General, ctrl+option+B, menu "Show Bar", default on). Fades in or out in 0.18 s.
- A bar is hidden on a display while a native full screen window is frontmost on it, unless "Show the bar over full screen apps" is on (default off; it adds `fullScreenAuxiliary`) `[Bar.swift, refresh]`.

### Position, drag, grip, lock, reset

- Default position: bottom center of the display's visible frame (above the Dock) `[Bar.swift, BarPositions.origin]`.
- Position is saved per display UUID as two fractions of the visible frame (center x, bottom y), so it survives resolution changes. It is kept 2 pt inside the visible frame `[Bar.swift, BarPositions]`.
- Drag with the grip above the pill (a 36 x 5 capsule, hit area 44 x 14) or by dragging the pill background (4 pt threshold, so a click is never a drag). The grip fades in on hover (0.15 s) and out 0.6 s after the pointer leaves (0.25 s fade) `[Bar.swift, hoverChanged]`.
- A bar cannot be dragged to another display: it is clamped to its own display.
- Lock: Settings > Appearance "Lock bar position" hides the grip and turns off dragging. "Reset Bar Position" in the right-click menu still works when locked.
- Reset: right-click the pill background or a chip > "Reset Bar Position" (that display), or Settings > Appearance "Reset Bar Position" (all displays).

### Chips

- One chip per layout, in id order: the layout digit label (1 to 9, then 0) in a monospaced digit font.
- With labels "Number and app icons" (default): up to 3 app icons after the number (then "..." if there are more apps). Icons are one per running process (by pid), most recently used first, sticky windows excluded `[Bar.swift, maxIcons = 3]` `[LayoutModel.swift, apps]`. With "Number only": numbers only.
- Current layout chip: white label on an accent color capsule that slides between chips.
- Empty layout (no windows and no apps): label at 40% opacity.
- Tooltip: "<name>: N windows".
- Click: switch. "+" chip: new layout (only below 10 layouts).
- Hover delete badge: on every chip except the first, hovering shows a small round "x" (14 pt) at the top-right corner. Click deletes the layout at once, with no confirmation. Its tooltip says how many windows move to the first layout's name `[Bar.swift, DeleteBadge, deleteHelp]`.
- Right-click menu on a chip: Rename..., Move All Windows To, Save Arrangement, Restore Arrangement, Apps to Open..., Delete (disabled for the first), Reset Bar Position.

### Animations and Reduce Motion

| Item | Normal | With Reduce Motion `[Bar.swift, Motion]` |
|---|---|---|
| Current highlight | One capsule slides, spring (response 0.3, damping 0.82) | No slide. Each chip fills itself, quick fade (0.15 s ease out). |
| Chips added or removed | Scale from 0.5 and fade, spring (0.32, 0.85) | Quick fade only |
| Hover | Chip scales to 1.05 | No scale |
| Delete badge | Scale from 0.4 and fade | Fade only |
| Missing layout hotkey | Bar shakes: 6 steps at 0.035 s: -7, 6, -4, 3, -1, 0 pt | No shake |
| Move overlay | Fades in with scale from 0.96, 0.16 s | Fade only |
| Number change | Numeric text transition (macOS 14 and up) | Same, quick |
| Bar show or hide fade (0.18 s) | Yes | Same (not changed by Reduce Motion) |

Other: pressing a chip shrinks it to 0.92. The bar width shrinks 0.4 s after the content gets narrower, so the pill edges are not clipped.

### Appearance options (Settings > Appearance) `[AppModel.swift, BarSize, BarLabels]`

| Option | Values | Default |
|---|---|---|
| Bar size | Small (height 24, font 11, icon 14) or Medium (height 30, font 12, icon 18) | Medium |
| Labels | Number and app icons, or Number only | Number and app icons |
| Opacity | 30% to 100% (slider) | 100% |
| Lock bar position | on or off | off |
| Reset Bar Position | button (all displays) | |

A live preview with sample data is at the top of the page. Also in Settings > General: "Menu bar icon": Grid, Columns, Windows, or Current layout number. The number choice shows the current layout of the focused (or first) display. The icon changes to a warning triangle (needs Accessibility) or a pause symbol (paused) whatever the choice.

---

## 14. Menu bar menu and Settings pages

### Menu bar menu `[MenuBar.swift]`

The menu is rebuilt each time it opens. Top to bottom:

1. Status line: "Desks is on", "Desks is paused", or "Desks needs Accessibility access" followed by "Open Accessibility Settings...".
2. One yellow line per warning. A click opens Settings > General.
3. Separator. For each display, its layouts as "1  First" with a check on the current one. With more than one display, a header with the display name is shown above each group. Clicking switches (this also counts as a switch that launches apps to open).
4. Separator. "New Layout" (ctrl+option+N), "Move Window to..." (ctrl+option+M), "Show Window in All Layouts" (ctrl+option+S): these three are enabled only while running. "Show Bar" (check; ctrl+option+B).
5. Separator. "Bring All Windows Back" (enabled unless Accessibility is missing; asks for confirmation). "Pause Desks" or "Resume Desks" (none when Accessibility is missing).
6. Separator. "Settings..." (ctrl+option+comma), "Quit Desks" (Cmd-Q).

Shortcut hints are read from the current key settings.

The app is an accessory app (no Dock icon). While Settings is open it becomes a regular app (Dock icon, small main menu with Settings, Hide, Quit, Edit, Window) and goes back when Settings closes `[SettingsWindow.swift]`.

### Settings pages `[SettingsWindow.swift, SettingsPages.swift, SettingsRules.swift]`

Window 820 x 600 by default, minimum 760 x 480. Sidebar order: General, Layouts, Shortcuts, Rules, Appearance, Permissions & About.

| Page | What it offers |
|---|---|
| General | Open Desks at login (SMAppService). Pause Desks toggle (disabled without Accessibility). Show the layout bar. Show the bar over full screen apps (disabled if the bar is off). "Hide windows in" corner. Menu bar icon. Warning banner on top. |
| Layouts | Explanation. "Restore saved arrangement when switching" toggle. One section per display: a row per layout with the digit badge, an editable name, a pin icon if an arrangement is saved, up to 3 app icons, window count, "Current" badge or "Show" button, a trash button (hidden for the first layout), and a chevron that opens the details: apps to open (Add App, remove each), and "Save Arrangement" and "Restore". "Add Layout" button (disabled at 10). Opens on a given layout when you choose "Apps to Open..." in the bar. |
| Shortcuts | Recorders in groups: Switch layouts (previous, next, 10 digit switches), Move windows (overlay, sticky, 10 digit moves), App (new layout, show or hide bar, bring all windows back, open Settings), Arrangements (save, restore). A warning with "Clear the Other" when two Desks actions have the same shortcut. "Reset to Defaults". |
| Rules | The rules list (enable switch, app, action picker, up and down, delete, title field), "Add Rule", and "Apply rules to open windows" with "Apply Now". |
| Appearance | Preview, size, labels, opacity, lock, reset. |
| Permissions & About | Accessibility status and "Open Privacy & Security". Help: "Bring Back..." (with confirmation). About: version. Credits: KeyboardShortcuts, AeroSpace. Warning banner. |

### Warnings (engine) `[LiveEngine.swift, updateWarnings]`

Checked at start, on display refresh, on rules change, and every 5 s (5 ticks of the 1 s timer). Shown in the banner (General, Permissions & About) and as menu lines:

- Stage Manager is on (read from the `com.apple.WindowManager` preference `GloballyEnabled`). Text: Desks keeps working, but it works best with Stage Manager off.
- A display has no free bottom corner, so parked windows may show on a neighbour display.
- A rule has an invalid, too long or too slow title pattern. The rule is skipped.
- Saved layouts could not be read, so Desks started fresh; the old file name is given.
- The private window-id call is missing: windows cannot be managed on this macOS version.

---

## 15. URL scheme and CLI

### URLs `[URLCommands.swift]`

Scheme `desks` (case-insensitive), command in the host (lowercased), arguments in the path. Layout numbers are 1 to 10 and mean layout id N-1.

| URL | Action | Accepts `?display=` |
|---|---|---|
| `desks://switch/N` | Switch to layout N | Yes |
| `desks://next` | Next layout (wraps) | Yes |
| `desks://previous` | Previous layout (wraps) | Yes |
| `desks://new` | New layout and switch to it | Yes |
| `desks://move/N` | Move the focused window to layout N | No |
| `desks://sticky` | Toggle sticky on the focused window | No |
| `desks://overlay` | Toggle the move overlay | No |
| `desks://rescue` | Rescue, after a confirmation dialog | No |
| `desks://pause` | Pause | No |
| `desks://resume` | Resume | No |
| `desks://settings` | Open Settings | No |
| `desks://settings/<page>` | Open one page: `general`, `layouts`, `shortcuts`, `rules`, `appearance`, `about` (or `permissions` for the same page). Case-insensitive. | No |
| `desks://save-arrangement` | Save arrangement of the current layout | Yes |
| `desks://restore-arrangement` | Restore arrangement of the current layout | Yes |

Argument rules:

- Commands that take no argument are rejected if there is a path part (for example `desks://next/2`). Rejected means: logged, nothing happens, no dialog.
- `switch` and `move` need exactly one path part: an integer from 1 to 10 (`Int` parsing, so `03` would also pass in the app; the CLI refuses it). Otherwise rejected.
- The only allowed query item is `display=<UUID>` with a non-empty value. Any other query item rejects the whole URL. The UUID must be a connected display, else the whole URL is rejected. If given twice, the last one wins.
- A `?display=` on a command that does not take a display rejects the whole URL (it is not ignored).
- Without `display`, the display is the focused window's display (then last focused, then main).
- `move/N` for a missing layout adds a new layout at the end (section 6). `switch/N` for a missing layout does nothing.
- Unknown commands and wrong schemes are logged and ignored.
- Rescue always asks (dialog "Bring all windows back?" with Bring All Back, Cancel, Pause Instead). Any app can open a URL, so the dialog is a guard.

### CLI `scripts/desks`

Linked to `~/.local/bin/desks` by `scripts/install-cli.sh`. It builds a `desks://` URL and runs `/usr/bin/open -g` (background, no focus). `DESKS_DRY_RUN=1` prints the URL instead.

```
desks <command> [--display UUID|display-N]
  switch N | move N     N is 1 to 10
  next | previous | new | sticky | overlay | rescue | pause | resume
  save-arrangement | restore-arrangement
  settings [page]
  help
```

Rules the script checks (exit code 2 and a usage line on error; `help`, `-h`, `--help` print usage and exit 0):

- The command must be the first argument. Unknown command: error.
- At most one positional argument. Any other word starting with `-` is an unknown option.
- `switch` and `move` need N: `1` to `9` or `10`, no leading zero, digits only.
- `next previous new sticky overlay rescue pause resume save-arrangement restore-arrangement` take no argument.
- `settings` takes an optional page: lowercase letters and dashes only, at most 32 characters. The app then checks the page name.
- `--display ID` needs a value: either a UUID (hex digits and dashes only, length 8 to 64) or the fallback id `display-` followed by 1 to 10 digits (the app uses it for a display without a UUID). It is allowed only for `switch next previous new save-arrangement restore-arrangement`. For any other command the script fails.
- The CLI has no confirmation of its own. `desks rescue` leads to the app's confirmation dialog.

---

## 16. Default keyboard shortcuts `[Hotkeys.swift]`

All can be changed in Settings > Shortcuts. Modifiers: control and option (written ctrl+option).

| Keys | Action |
|---|---|
| ctrl+option+1 to 9, then 0 | Switch to layout 1 to 9, then layout 10 (key 0) on the display of the focused window. A missing layout: bar shakes. |
| ctrl+option+shift+1 to 9, 0 | Move the focused window to layout 1 to 9, 10. A missing layout adds a new one at the end. |
| ctrl+option+Left / Right | Previous / next layout (wraps) |
| ctrl+option+M | Move overlay |
| ctrl+option+S | Toggle sticky on the focused window |
| ctrl+option+N | New layout |
| ctrl+option+B | Show or hide the bar |
| ctrl+option+shift+R | Rescue (no confirmation) |
| ctrl+option+comma | Open Settings |
| none | Save arrangement |
| none | Restore arrangement |

Number pad digits: each digit shortcut has a hidden mirror with the same modifiers and the number pad digit (for example ctrl+option+keypad 1). Mirrors follow the main shortcut. A mirror is cleared when the main shortcut is empty, is not a top-row digit, or when the mirror combination is already used by another shortcut `[Hotkeys.swift, syncKeypadMirrors]`. They are never shown in Settings. The move overlay also accepts number pad digits (by key code).

On the first launch of a build with 1-based digits, all 20 digit shortcuts are reset once to the defaults above, which also overwrites custom digit shortcuts `[Hotkeys.swift, migrateDigitShortcuts]`.

---

## 17. Known limitations and private API calls

### Known limitations

- 1 px sliver: a parked window keeps about 1 px visible on a display corner (top-left of the window at the visible-frame corner, 1 px inside). macOS does not allow a window to be fully off screen. The Zoom exception uses 0 offset.
- Mission Control, Exposé and similar views show parked windows (small). Desks does not change Dock settings.
- A display where both bottom corners touch other displays can show parked windows on a neighbour display (warning shown).
- Stage Manager: not tested. A warning is shown. Windows may fight with parking.
- Not notarized: `scripts/build-app.sh` builds arm64 only, signs with the hardened runtime using a self-signed "Desks Dev" identity (or ad-hoc), and has no notarization step. It is not sandboxed. macOS 13 or newer (`Package.swift`, `Info.plist`).
- Minimized and native full screen windows are not parked.
- Native tabs have no special handling.
- Apps with no regular Dock presence are not managed.
- Layout membership of a window cannot be changed by Desks while Accessibility is off.
- Switching is not animated. Windows jump.

### Private or undocumented calls used

| Call | File and function | Use | If missing |
|---|---|---|---|
| `_AXUIElementGetWindow` (HIServices, loaded with `dlopen` and `dlsym`) | `AXSupport.swift`, `PrivateAPI.getWindow` | Get the CGWindowID of an AX window | Warning; no window can be managed |
| `GetProcessForPID` (HIServices or ApplicationServices, loaded with `dlsym`) | `AXSupport.swift`, `PrivateAPI.getProcessForPID` | Get a process serial number for the focus fallback | Fallback is skipped |
| `_SLPSSetFrontProcessWithOptions` (SkyLight, mode `0x200`) | `AXSupport.swift`, `PrivateAPI.setFrontProcess`, `bringToFront`; used in `Focus.swift` | Bring an app to front when `activate()` did not work (after 0.15 s) | Fallback is skipped |
| `AXEnhancedUserInterface` and `AXFullScreen` AX attributes | `AXSupport.swift` | Switch off animation lag when moving; read full screen state | |
| `com.apple.WindowManager` preference `GloballyEnabled` (undocumented key) | `Focus.swift`, `SystemState.isStageManagerOn` | Detect Stage Manager | Treated as off |

Public but notable: `CGWindowListCopyWindowInfo` with `.optionAll` (window ids on all Spaces, `WindowTracker.swift`). No private Spaces APIs.

---

## 18. Timing and limit reference

| Value | Meaning | Where |
|---|---|---|
| 10 layouts, ids 0 to 9 | Max per display | `LayoutModel.swift`, `maxLayoutId` |
| 30 | MRU entries per layout | `LayoutModel.swift`, `mruLimit` |
| 40 | Max layout name length | `LayoutModel.swift`, `renameLayout` |
| 0.5 s | AX messaging timeout | `AXSupport.swift`, `messagingTimeout` |
| 2 px | Position check after show or park | `ParkingEngine.swift`, `landed`, `sendPark` |
| 50 ms, 30 ms | Wait before the one retry (show, park) | `ParkingEngine.swift`, `show`, `sendPark` |
| 0.25 s | Max wait for shows before parks start | `ParkingEngine.swift`, `sync` |
| 1.0 s | Window events count as Desks' own | `ParkingEngine.swift`, `isInTransit` |
| 3 | Re-parks per target; re-shows per window | `ParkingEngine.swift`, `requestRepark`; `LiveEngine.swift`, `updateKnown` |
| 8 px | "Looks parked" threshold | `Displays.swift`, `looksParked` |
| 1 px (0 for Zoom) | Sliver | `Displays.swift`, `parkPoint` |
| 50% area, 200 x 150 | Frame fix rule | `Displays.swift`, `sanitize` |
| 30 x 30 | Min window size to manage | `LiveEngine.swift`, `reconcile` |
| 0.5 s | Block focus-driven switches after a switch, move, move all | `LiveEngine.swift`, `performSwitch`, `moveWindow`, `moveAllWindows`, `focusMRU` |
| 1.0 s | Same, after handing focus to Finder | `LiveEngine.swift`, `focusAwayFromParked` |
| 2.0 s | Same, after start or resume | `LiveEngine.swift`, `beginManaging` |
| 0.3 s, 0.35 s | After a close: block, then refocus | `LiveEngine.swift`, `noteClose` |
| 0.15 s | Wait before a focus-driven switch | `LiveEngine.swift`, `scheduleFocusSwitch` |
| 0.6 s | A close this recent cancels a focus-driven switch | `LiveEngine.swift`, `scheduleFocusSwitch` |
| 0.15 s | Fallback focus (private call) | `Focus.swift`, `focus` |
| 3 s, 10 s | Auto-placed window focus rule; cleanup time | `LiveEngine.swift`, `handleFocus`, `adopt` |
| 15 s | Apps-to-open launch target life | `LiveEngine.swift`, `launchAppsToOpen` |
| 600 s | Keep time for saved or quit-app windows | `LiveEngine.swift`, `beginManaging`, `appGone` |
| 2.0 s, 2.5 s | Display change delay, settle time | `LiveEngine.swift`, `screensChanged` |
| 1.0 s timer, 5 ticks | Trust check; warnings refresh | `LiveEngine.swift`, `onTimer` |
| 2.5 s | Pause and quit wait for verified shows | `LiveEngine.swift`, `stopManaging` |
| 1.0 s, 1.05 s, 30 s | Title wait; re-read; cleanup | `LiveEngine.swift`, `waitForTitle`, `reconcile` |
| 200, 512 | Max pattern and title length for rules | `LiveEngine.swift`, `maxPatternLength`, `maxTitleLength` |
| 10, 3, 1, 2, 1 and > 3 | Match scores and threshold | `LiveEngine.swift`, `matchScore`, `adopt` |
| 40 pt | Frame tolerance for matching | `LiveEngine.swift`, `matchScore` |
| 4 px | Moved enough to count as "came back" | `LiveEngine.swift`, `updateKnown` |
| 4.0 s | Poll of all apps | `WindowTracker.swift`, `start` |
| 15 | Max AX watcher retries | `WindowTracker.swift`, `scanApps` |
| 1.0 s | State save debounce | `Store.swift`, `scheduleSave` |
| 0.18 s | Bar fade | `Bar.swift`, `setVisible` |
| 0.6 s, 0.4 s | Grip hide delay; bar shrink delay | `Bar.swift`, `hoverChanged`, `layout` |
| 30% to 100% | Bar opacity range | `Bar.swift`, `targetAlpha` |
| 3 (bar), 4 (overlay) | Max app icons | `Bar.swift`, `maxIcons`; `MoveOverlay.swift`, `OverlayRow` |
