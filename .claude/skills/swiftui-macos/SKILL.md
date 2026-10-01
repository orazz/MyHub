---
name: swiftui-macos
description: SwiftUI conventions for MyHub's panel views — @Observable state, section panes, focus/keyboard in a non-key panel, animation, performance, theming. Use when writing or editing any View under Sources/MyHub/Features/*/ or Design/.
---

# SwiftUI in MyHub

## State
- Stores are `@MainActor @Observable final class`. Views take them as plain `let`/`var` properties or `@Bindable` (for bindings). Don't use `ObservableObject`, `@Published` or Combine forwarding. Observation tracks per property, so the header re-renders only for the properties it reads.
- View-local UI state (hover, the copied-checkmark flash) belongs in `@State`. It never goes in stores.
- Anything that must survive the pane being unmounted (selected note, scroll anchor) belongs in the store.
- Views must not hold references to actors or call `await` for data. They call store methods, and the stores own their `Task`s.

## Structure
- One `XxxView` per section in `Features/Xxx/`, with small `private struct` rows. Keep each `body` under ~60 lines by extracting subviews rather than computed `some View` vars when those parts have their own state.
- Sections are cases of the `Section` enum, which carries the symbol, title, `needsKeyboard`, `canHide` and the dock order (`Section.tools`). Adding one means adding a case and a view, plus a line in `SectionPane`.
- `ForEach` needs stable `Identifiable` ids. Never use `UUID()` minted inside a view.

## Keyboard & focus (panel is usually NOT key)
- Text input works only after the window becomes key through `ScreenSession.wantsKeyboard`. Use `@FocusState` and set focus in `.task`/`.onAppear` **after** the key request.
- Don't rebuild a `TextField`/`TextEditor` on every keystroke. A parent that re-renders per letter drops focus, so keep text-heavy stores out of whatever the header observes.
- Esc (`.onKeyPress(.escape)` / `onExitCommand`) returns the keyboard and never clears text.

## Look
- Everything goes through `HubTheme` (colors, radii, animations). The panel is always dark, so use white with opacity for secondary, tertiary and surface colors.
- Custom `HubButtonStyle` and `HubToggleStyle` (drawn capsule). `NSSwitch`-backed toggles turn grey in non-key windows.
- Animations come from `HubTheme.Motion`: `open`/`close` for the island, `content` for tab swaps, and `dock` for the dock capsule. Animate `scaleEffect`, `opacity` and `offset`, not `frame`.
- SF Symbols only. Use `.monospacedDigit()` for counters, countdowns and percentages.

## Performance
- The panel is hosted in `NSHostingView` with `sizingOptions = []` (the window is fixed-size).
- Use `LazyVStack` in lists of 20+ rows. Thumbnails arrive asynchronously, and rows show a type icon until then.
- Formatting: use cached `static let` formatters or `.formatted()` styles. Don't build a `DateFormatter` in `body`.
- A collapsed panel must not re-render. Guard expensive work with `session.isOpen`.

## Accessibility & localisation
- `Text("English key")` localises automatically. Use `L10n.string("…")` for strings built outside views. Add `.accessibilityLabel` to icon-only buttons.

## Design system (handoff 1b)
- Tokens live in `Design/HubTheme.swift` (panel/card/tile/selected/segment colours, accent `#E8A94A`, radii 34/22/16/14/10/5/4). Shared pieces in `Design/Controls.swift`: `hubCard()`, `selectedRow()`, `GhostPill`, `HubSegmented`, `ProgressLine`, `IndeterminateLine`, `HubToggleStyle`, `ShortcutBadge`, `DropZoneBackground`, `LightCapsuleButtonStyle`. Use them; don't re-derive colours in views.
- Panel: 600×300 by default (content area 200 tall above a 34pt dock). Settings → Panel size (`PanelSize`) makes the panel bigger to show *more* — text and controls never scale. Read `metrics.contentHeight` / the available size; lay out to use extra room (more rows, a second stash row, a taller chart) and scroll what does not fit. Snapshot a size with `MYHUB_SNAPSHOT_SIZE=extraLarge`.
- `layoutPriority` is not a ratio — it makes a view claim space first. For the handoff's 1/1/1.2-style grids, compute widths with `GeometryReader`.

## Checking a UI change by eye
Screenshots need Screen Recording permission, but offscreen rendering does not:
`MYHUB_SNAPSHOT_DIR=/tmp/snaps swift test --filter PanelSnapshots` renders every tab inside the real panel chrome (NSHostingView in an offscreen NSWindow → `cacheDisplay`) with sample data, including ScrollView content. `ImageRenderer` does *not* render ScrollViews — don't use it for this.
