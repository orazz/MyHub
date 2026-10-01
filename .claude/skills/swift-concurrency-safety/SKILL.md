---
name: swift-concurrency-safety
description: Swift 6 strict-concurrency and thread-safety rules for MyHub — actor boundaries, Sendable, callback APIs (EventKit, QuickLook, NSWorkspace), timers, cancellation, testing with TSan. Use whenever writing async code, actors, Tasks, callbacks, or fixing a Sendable/isolation compiler error.
---

# Thread safety in MyHub (Swift 6 language mode)

## Isolation map
| Layer | Isolation |
|---|---|
| Views, `HubModel`, every `*Store`, `Preferences`, `ContentShield`, Island/* | `@MainActor` |
| `UsageEngine`, `JSONLTailReader`, any cache touched from multiple tasks | `actor` |
| Providers, `HTTPClient`, `SigV4Signer`, parsers | `Sendable` structs with immutable config, stateless |
| `Keychain` | `enum` with static funcs (Security framework is thread-safe) |

## Rules
1. **Only `Sendable` values cross isolation.** Use `Data`, `String`, `Date`, `CGImage`, and value-type snapshots. Convert `NSImage`/`NSColor`/`EKEvent`/`NSURL` on the owning side first (for example, `EKEvent` → `Meeting` struct with the color as hex, or `QLThumbnail` → `CGImage` + `CGSize`).
2. **Callback-based APIs** are wrapped once, in the actor that owns the framework object, as an `async` function built on a continuation. Callers just `await` it, and no callback closure ever lives on a `@MainActor` type, where it would inherit main-actor isolation and trap when the framework calls it from its own queue. Example: `CalendarSource.requestAccess()`, which wraps `requestFullAccessToEvents`. If a closure has to live on a main-actor type, mark it `@Sendable` and hop back explicitly.
3. **Notifications:** observe them as async sequences in a stored `Task`, for example `for await _ in center.notifications(named: …).map({ _ in () })`, mapping to `Void` so no non-Sendable `Notification` crosses isolation. Cancel the task in `stop()`/`teardown()`. See `IslandCoordinator.on(_:in:_:)` and `AgendaStore.observe()`.
4. **Repeating work on main:** use `Ticker` (Core/Ticker.swift). It runs in `.common` run-loop modes, takes a slack fraction, and `halt()` stops it. Don't hand-roll `Timer`s. For async polling off main, store a `Task { while !Task.isCancelled { …; try await Task.sleep(for: …) } }`.
5. **Own your tasks.** Every long-lived `Task` is stored in a property and cancelled in `stop()`/`deinit`-equivalent. Avoid fire-and-forget `Task {}` for anything that loops or does network I/O.
6. **Parallel fetches** use `withTaskGroup` with a per-child timeout (`withThrowingTaskGroup` racing `Task.sleep`). A failing provider must not cancel its siblings, so return `Result` per child.
7. **Actor reentrancy:** state can change across every `await` inside an actor. Re-check invariants after an await, and dedupe in-flight work with a stored `Task` per key:
   ```swift
   if let running = inFlight[id] { return try await running.value }
   ```
8. **No `DispatchQueue` + shared mutable state** in new code. No locks unless wrapping a C API. The only allowed `@unchecked Sendable` needs a comment proving immutability or internal locking.
9. **No `nonisolated(unsafe)`** unless it's a `let` of a thread-safe type, with a comment.
10. **Main thread budget:** nothing over ~2 ms on main. File reads over 64 KB, JSON decoding of network responses, log parsing and thumbnailing all happen off main.
11. **`[weak self]`** in escaping closures stored by long-lived objects (timers, observers, sinks). Don't use it in `Task` inside actors, where structured lifetime is preferred.

## Checking
- `swift build -Xswiftc -strict-concurrency=complete` produces no warnings.
- `swift test --sanitize=thread` runs for the store and engine tests.
- Look for runtime `dispatch_assert_queue` traps in Console. They mean a closure inherited the wrong isolation (see rule 2).
