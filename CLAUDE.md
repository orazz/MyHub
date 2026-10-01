# MyHub

Native macOS notch utility (SwiftUI + AppKit, Swift 6, macOS 15+). Sections: Stash,
Clipboard, Calendar, Notes, AI Usage. The plan and phase status live in `docs/PLAN.md`.

## Build & run
```bash
swift build                              # debug build
swift test                               # unit tests (Swift Testing)
./Scripts/bundle.sh && open build/MyHub.app
```

## Ground rules
- Everything here — code, comments, scripts, docs, skills — is written for MyHub. Don't paste code or prose from other projects; build on Apple's documented APIs.
- Swift 6 language mode, strict concurrency, no warnings. UI and stores are `@MainActor @Observable`, and I/O runs in actors (see the `swift-concurrency-safety` skill).
- Secrets live only in Keychain. Third-party credentials are read-only and opt-in (see the `macos-app-security` skill).
- No third-party dependencies.
- No permission prompts at launch, and no timers while nothing is visible. The target is 0% CPU at idle.
- Tests cover pure logic (stores, parsers, signers, hover state machine), not the panel visuals.

## Skills
- `macos-notch-app`: window, hover, click-through, focus, displays
- `swiftui-macos`: view and state conventions
- `swift-concurrency-safety`: isolation, Sendable, callbacks, cancellation
- `macos-app-security`: Keychain, networking, untrusted input, signing
- `ai-usage-providers`: endpoints and auth for every AI usage source
