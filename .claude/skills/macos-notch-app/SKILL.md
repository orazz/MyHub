---
name: macos-notch-app
description: AppKit rules for MyHub's notch "island" window layer — NSPanel setup, click-through, hover sampling, keyboard focus, multi-display, drag & drop, idle CPU. Use when touching anything under Sources/MyHub/Island/ or App/, or when a bug involves hover, clicks passing through, focus, cursor, or displays.
---

# The island window layer

MyHub runs as a menu-bar-only app (`LSUIElement`). It is never the active app,
and it draws through one `IslandWindow` (an `NSPanel`) per display. Most of the
rules below were learned from a bug, which is named where it helps.

## How the pieces fit
```
IslandCoordinator ── one per app; owns HubModel, rebuilds on display changes
  └─ IslandScreen ── one per display; wires window + tracker + session
       ├─ IslandWindow     NSPanel: level, key handling, editing shortcuts
       │    └─ IslandHostView   hit-testing, arrow cursor, file drops
       │         └─ NSHostingView(IslandRootView)   everything visible
       ├─ HoverTracker     samples the pointer (Ticker) → HoverMachine (pure)
       └─ ScreenSession    per-display state: open, drop target, keyboard
```

## The window
- Never resize it. Its frame is the largest body plus room for the shadow, and
  only the SwiftUI shape inside animates.
- **Stacking-order bug (2026-09-30):** `isFloatingPanel = true` also sets
  `level` to `.floating`, below the menu bar. If it runs after `level` is
  set, AppKit pushes the window down past the menu bar. The island is then
  drawn lower than the area that takes clicks, and its bottom edge goes dead.
  - So set `isFloatingPanel` first, then `IslandWindow.islandLevel`.
  - Override `constrainFrameRect` to return the frame as it is.
  - `IslandWindowTests` covers this. To check by hand, the window should be
    on layer 26 at y = 0 in `CGWindowListCopyWindowInfo`.
- Force `darkAqua` on the window. The island is black whatever the system
  appearance is.
- **Keyboard:** `allowsTyping` gates `canBecomeKey`, and only sections with a
  text field turn it on.
  - Becoming key never activates MyHub, because the panel is `.nonactivatingPanel`.
  - To give key status back, call `dropKeyboard()`, which orders the window
    out and straight back in. Call it only after the fold has finished.
- **Editing shortcuts:** with no Edit menu, the window's `sendEvent` routes
  ⌘A/X/C/V/Z and ⇧⌘Z itself.
  - Match on `kVK_ANSI_*` key codes, not characters, so ⌘C still works on a
    Cyrillic or Greek layout.
  - Send the action to the first responder with `tryToPerform`.
- **Clicks into fields:** SwiftUI tap gestures never fire on a `TextEditor`,
  so a click into a field is caught as `.leftMouseDown` in `sendEvent`, before
  `super`.

## Clicks that should reach the app underneath
- `ignoresMouseEvents` is the only real click-through. `HoverTracker` flips it
  from `interactiveRect(_:)` on every sample.
- Returning nil from `hitTest` throws a click away. It does **not** pass the
  click to the window below. `IslandHostView.hotArea` is only a guard for the
  moments between two samples.
- While a file drag is over the island, `dropInProgress` makes the whole view
  a target, so the drag survives the island growing under the pointer.

## Hover
- Read `NSEvent.mouseLocation` on a `Ticker`. Event monitors don't work here:
  global monitors don't see MyHub's own windows, and local monitors need
  MyHub to be the active app.
- Use two rates:
  - Brisk (60 Hz) only while the island is open, or while the pointer is
    moving in the warm zone.
  - Lazy (8 Hz) otherwise, including when the pointer has rested for 3 s.
  - Drop back to lazy only once the pointer is 80 pt beyond the warm zone.
- Dwell before opening:
  - 50 ms on a real notch, 200 ms on a drawn strip.
  - 50 ms before closing.
  - About 150 ms before a hover switches tabs.
  - Use separate open and close rects so the edge doesn't flicker.
- `HoverMachine` is a value type: point, time, rects and flags go in, and a
  decision comes out. Keep it free of AppKit so the tests can drive it.

## Cursor
- An always-active `NSTrackingArea` over `hotArea` sets `NSCursor.arrow` on
  `cursorUpdate` and `mouseEntered`. Cursor rects need a key window, so they
  don't apply here.

## Displays
- **Notch size:** the gap between `auxiliaryTopLeftArea.maxX` and
  `auxiliaryTopRightArea.minX`, by `safeAreaInsets.top` high. Without a notch,
  draw a 180 pt strip at the menu-bar height.
- **Matching islands to displays:** match by `CGDirectDisplayID`. `NSScreen`
  objects and their order change with every reconfiguration. An island whose
  `ScreenMetrics` still matches is kept as it is.
- A display that mirrors another gets no island of its own.
- **Collapse:** fold every island on a Space change and when the displays sleep.
- **Where state lives:**
  - Per display: `ScreenSession`, for open/closed, drop target and keyboard.
  - Shared: `HubModel`, for the section and the stores.

## Positions (Settings → Position)
- **Top** hangs from the notch.
- **Left** and **Right** dock the same panel at the middle of that screen
  edge. Closed, it is a 6×180 strip.
- **Edge-aware geometry:** take every rect from `ScreenMetrics`:
  - `bodyRect(_:)`
  - `growingOut(_:by:)`
  - `warmZone`

  Never compute rects from `screen.frame` directly.
- `IslandShape` draws the outline for the top edge and turns it with an affine
  transform for the side edges.
- `MYHUB_SNAPSHOT_POSITION=left|right` renders a docked position offscreen.

## Opening and closing
- The content is laid out at its open size from the first frame, clipped to
  the shape and pinned to the docked edge, so the growing outline uncovers it.
  Content drawn outside the shape is what made the motion look rough.
- **Curves:** use `Motion.open` (springy) and `Motion.close` (quick,
  critically damped). Content fades in late (`contentIn`) and out early
  (`contentOut`).
- **Shadow:** the 25 pt blur appears only after the panel has opened
  (`shadowIn`), and it goes the moment closing starts.
- **Deferred work:**
  - `HubModel.setPanelActive` holds tab work back by `Motion.openSettle`.
  - Releasing the keyboard and shrinking the click area wait for
    `Motion.closeSettle`.
- To look at the in-between frames, the snapshot test renders
  `opening-25/55/85.png` using `ScreenSession.debugBodySize` (DEBUG builds only).

## The closed notch
- Three things can widen it, loudest first: a flash, a focus countdown, the inbox badge.
  - `session.flash` shows a few seconds of news. Feed it through `HubModel.onFlash` or `onBuildFinished`.
  - `session.showsFocus` shows a running focus countdown.
  - `session.showsBadge` shows the unread inbox count: light grey, no colour, no motion. It must never draw attention like a flash does.
- Neither is interactive. The click area stays `collapsedSize`.
- Live text there uses a `TimelineView`, so nothing ticks while it isn't drawn.

## Other windows
- **Ruler** (`RulerController`): one `.screenSaver`-level non-activating panel per display, which takes keys without activating the app.
  - Screen Recording is asked only when the user presses L.
- **Open panels** (`NSOpenPanel` for repos): call `NSApp.activate()` first. Otherwise the dialog opens behind the frontmost app.

## Drag and drop
- Files dragged onto the island select the Stash and open it. Files leave the
  Stash through `FileDragSource`.

## Idle cost and permissions
- **0.0% CPU at rest:** check with Activity Monitor or `sample MyHub`.
  - Every repeating timer is a `Ticker` with slack, and it runs only while
    something on screen needs it.
  - A folded island does not redraw for store changes.
- **No permission prompts at launch:** a prompt comes only from a button in
  the section that needs it.
- **No file reads before the Stash is shown:** the Stash doesn't read its
  files until it is on screen.
