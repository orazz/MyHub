# MyHub — Implementation Plan

A native macOS notch utility (SwiftUI + AppKit): invisible at rest, unfolds from
the notch on hover into a panel with **Stash**, **Clipboard**, **Calendar**,
**Notes**, **Focus**, **AI Usage**, **Builds** and **Dev**.

Design principles: `@Observable` stores on the main actor, actors for all
I/O, security-scoped bookmarks for stashed files, Keychain for every secret,
and zero CPU while nothing is on screen.

---

## 1. Decisions (defaults — change before Phase 0 if needed)

| Topic | Default | Why |
|---|---|---|
| App name / bundle id | `MyHub` / `com.orazz.myhub` | Folder name; change freely |
| Min macOS | 15.0 | `@Observable`, `EKEventStore.requestFullAccessToEvents`, modern SwiftUI |
| Build system | SwiftPM + `Scripts/bundle.sh` | No Xcode project churn, CLI-friendly, reproducible |
| Swift | 6 language mode, strict concurrency | Data-race safety enforced by the compiler |
| Sandbox | **Not sandboxed**, hardened runtime, Developer ID + notarization | AI Usage must read `~/.claude`, `~/.codex`, `~/.aws` and Claude Code's Keychain item — impossible in the sandbox |
| Dependencies | **None** | Supply-chain surface = 0; SigV4, JSON, Keychain are small enough to own |
| Tests | Swift Testing (`import Testing`) on pure logic | Parsers, signers, stores — not the panel |
| Languages | English first; string keys = English text | Add more `.lproj` later |

---

## 2. Architecture

```
main.swift ─► HubAppDelegate ─► StatusMenu (menu bar item)
                    │
                    ▼
            IslandCoordinator  (one per app)          ◄── owns HubModel
                    │  diffs displays by CGDirectDisplayID
                    ▼
            IslandScreen × N   (one per display)
              ├─ IslandWindow   : NSPanel (borderless, non-activating, level statusWindow+1)
              ├─ IslandHostView : NSView (hitTest/hotArea, drop target, arrow cursor)
              ├─ HoverTracker   : timer-sampled pointer, 60 Hz warm / 8 Hz idle
              └─ ScreenSession  : @Observable per-screen state (isOpen, isDropTarget, wantsKeys)

            HubModel (@MainActor @Observable, shared)
              ├─ section: Section            (rail selection)
              ├─ Preferences                 (preferences.json)
              ├─ ContentShield               (hide contents while screen-sharing)
              ├─ StashStore                Features/Stash
              ├─ PasteboardMonitor           Features/Clipboard
              ├─ AgendaStore                 Features/Calendar
              ├─ ScratchpadStore             Features/Notes
              └─ UsageStore  ──► UsageEngine (actor) ──► [UsageProvider] (Sendable)
```

### Folder layout

```
MyHub/
├─ Package.swift
├─ CLAUDE.md
├─ Resources/  MyHub.entitlements, AppIcon.icns, en.lproj/, pricing.json
├─ Scripts/    bundle.sh, dmg.sh, notarize.sh, version
├─ Sources/MyHub/
│  ├─ App/        main.swift, HubAppDelegate, StatusMenu, L10n
│  ├─ Island/     IslandCoordinator, IslandScreen, IslandWindow, IslandHostView,
│  │              HoverTracker, HoverMachine, ScreenMetrics, ScreenSession
│  ├─ Core/       HubModel, Section, Preferences, AppPaths, WriteCoalescer, ContentShield, Log
│  ├─ Security/   Keychain, SecretRef, Redacted, PinnedSession(HTTPClient), FilePermissions
│  ├─ Design/     HubTheme, IslandShape, Controls (HubButtonStyle, HubToggleStyle), ShieldText
│  └─ Features/
│     ├─ Stash/      StashStore, StashItem, StashView, FileDragSource, ThumbnailLoader
│     ├─ Clipboard/  PasteboardMonitor, ClipHistory, ClipEntry, ClipboardView
│     ├─ Calendar/   AgendaStore, CallLinkDetector, AgendaView
│     ├─ Notes/      ScratchpadStore, ScratchpadView
│     └─ AIUsage/
│        ├─ Model/      UsageSnapshot, QuotaWindow, Spend, TokenTally, ProviderConfig
│        ├─ Engine/     UsageEngine (actor), RefreshPolicy, Backoff
│        ├─ Providers/  ClaudePlan, ClaudeLocalLogs, AnthropicAdmin, OpenAIAdmin,
│        │              CodexPlan, CodexLocalLogs, OpenRouter, Bedrock, CustomEndpoint
│        ├─ AWS/        SigV4Signer, AWSCredentialsSource
│        ├─ Logs/       JSONLTailReader (actor), PriceTable
│        └─ UI/         UsageView, UsageCard, QuotaBar, ProviderSetupSheet
└─ Tests/MyHubTests/   HoverMachineTests, PreferencesTests, ClipHistoryTests,
                       CallLinkDetectorTests, SigV4Tests, ProviderDecodingTests,
                       JSONLTailReaderTests, KeyPathMappingTests
```

---

## 3. Platform rules (the non-obvious ones)

The detailed version, with the reasons, is the `macos-notch-app` skill.

1. One fixed-size panel per display; only the SwiftUI shape inside animates.
2. Clicks pass through via `ignoresMouseEvents`, switched by pointer position — a nil `hitTest` swallows clicks rather than passing them on.
3. The pointer is sampled (`Ticker`, brisk only while moving near the island) because event monitors are blind or inactive for a menu-bar app.
4. An always-active tracking area keeps the arrow cursor over the island.
5. The panel takes the keyboard only for typing sections, without activating the app; editing shortcuts are routed by physical key.
6. The panel is always dark (`darkAqua`).
7. Tab switching on hover waits for a short dwell.
8. Nothing repeats while its result is off screen.
9. Permissions are requested only from a button, after an explanation.
10. No file access at launch; the Stash checks its files when shown.

---

## 4. Features

### 4.1 Stash
- Drop files onto the island → opens and switches to Stash. Drag cards out (multi-select with ⌘/⇧).
- **Store bookmarks, not paths** (`URL.bookmarkData(options: .minimalBookmark)`; `.withSecurityScope` only if we ever sandbox). Resolve lazily when the stash is shown, re-save stale bookmarks, so files that are moved/renamed stay on the stash.
- Distinguish *gone* (`NSFileReadNoSuchFileError`) from *not permitted* — never drop cards on a permission denial.
- Thumbnails via `QLThumbnailGenerator`; callback is `@Sendable`, pass `CGImage` + size (not `NSImage`) across to `@MainActor`.
- Optional: "save clipboard screenshots to stash" (writes PNG to `~/Library/Application Support/MyHub/Captures`).

### 4.2 Clipboard
- Poll `NSPasteboard.general.changeCount` every 0.5 s (tolerance 0.2). Read data only when the counter moves.
- **Skip** when any of `org.nspasteboard.ConcealedType`, `TransientType`, `AutoGeneratedType` is present, when our own marker type is present, or when the frontmost app is in the **excluded apps** list (defaults: 1Password, Bitwarden, Keychain Access, Passwords).
- Text, file URLs, images (optional). Dedup, cap 50, **pin** entries (pins survive the cap).
- History **in memory by default**. Opt-in persistence is **AES-GCM encrypted** (CryptoKit) with a key stored in Keychain (`ThisDeviceOnly`).
- Handle Continuity images that arrive late (retry ≤ 6 s, abort if the counter moves).

### 4.3 Calendar
- EventKit, `requestFullAccessToEvents` **only from a button**. Refresh on `EKEventStoreChanged`; countdown timer only while the panel is open.
- 7-day horizon, next meeting highlighted with "Join" button; per-calendar visibility picker.
- `CallLinkDetector`: `NSDataDetector` over location/notes/url; **https + host allowlist** (Meet, Zoom, Teams, Webex, Whereby, Jitsi, Slack huddles, Around). Re-validate at click time. Event text is untrusted input.

### 4.4 Notes (scratchpad)
- Quick notes: new note on arrival if empty, first line = title, blank notes swept on leave, Esc returns keyboard.
- Autosave through `WriteCoalescer` (0.8 s), flush on quit. File `notes.json`, perms 0600.
- Also: pin a note to the top; ⌘F filter.

### 4.5 AI Usage (new)

**Goal:** one glance shows, per configured account: quota windows (e.g. 5-hour / weekly %) with reset times, spend this month, and tokens by model.

#### Model (all `Sendable` value types)
```swift
struct UsageSnapshot: Sendable, Equatable {
  let providerID: ProviderID          // stable per configured account
  let kind: ProviderKind              // .claudePlan, .openAIAdmin, .bedrock, ...
  let accountLabel: String?
  let windows: [QuotaWindow]          // label, usedFraction 0...1, resetsAt
  let spend: Spend?                   // amount (Decimal), currency, period
  let tokens: TokenTally?             // in/out/cacheRead/cacheWrite, byModel
  let fidelity: Fidelity              // .official, .unofficial, .estimated
  let fetchedAt: Date
}
protocol UsageProvider: Sendable {
  var id: ProviderID { get }
  func fetch(now: Date) async throws -> UsageSnapshot
}
```

#### Providers

| # | Provider | Source | Auth | Fidelity |
|---|---|---|---|---|
| 1 | **Claude Pro/Max plan** | `GET https://api.anthropic.com/api/oauth/usage` (header `anthropic-beta: oauth-2025-04-20`) → `five_hour`, `seven_day` (+ model-specific weekly) `utilization`, `resets_at` | Claude Code's OAuth token, read **read-only, opt-in** from Keychain item `Claude Code-credentials` (system prompt appears; user can "Always Allow") | unofficial — may 429; back off, never refresh/write the token |
| 2 | **Claude Code local logs** | `~/.claude/projects/**/*.jsonl` (+ `$CLAUDE_CONFIG_DIR`, `~/.config/claude/projects`) → `message.usage` per assistant turn; dedupe by `requestId`/`message.id` | none (file read) | estimated (cost via `pricing.json`) |
| 3 | **Anthropic API (org)** | `GET /v1/organizations/usage_report/messages`, `GET /v1/organizations/cost_report` | Admin key `sk-ant-admin…` in our Keychain | official |
| 4 | **OpenAI API (org)** | `GET /v1/organization/costs`, `GET /v1/organization/usage/completions` (`bucket_width=1d`, `group_by=model`) | Admin key `sk-admin-…` in our Keychain | official |
| 5 | **ChatGPT / Codex plan** | `GET https://chatgpt.com/backend-api/wham/usage` → `rate_limit.primary_window/secondary_window.used_percent`, `reset_at`, `plan_type` | `~/.codex/auth.json` access token + `ChatGPT-Account-Id`, read-only, opt-in | unofficial |
| 6 | **Codex local logs** | `~/.codex/sessions/**/rollout-*.jsonl` `token_count` events (tokens + last seen `rate_limits`) | none | estimated / last-seen |
| 7 | **OpenRouter** | `GET https://openrouter.ai/api/v1/key` (`usage`, `limit`, `limit_remaining`, `limit_reset`), `GET /api/v1/credits` | API key in Keychain | official |
| 8 | **AWS Bedrock** | CloudWatch `GetMetricData`, namespace `AWS/Bedrock`, `InputTokenCount`/`OutputTokenCount` by `ModelId`; optional Cost Explorer `GetCostAndUsage` filtered to Bedrock (**costs $0.01/request** → max 1/hour, off by default) | SigV4 (own signer, CryptoKit HMAC). Credentials: access key in Keychain **or** read-only named profile from `~/.aws/credentials` (static keys only in v1; SSO later) | official (tokens), official (cost) |
| 9 | **Custom endpoint** | User-defined `GET` URL + auth header + secret; JSON key-path mapping for `used`, `limit`, `spend`, `resetAt`, `windows[]`. Presets: **LiteLLM** (`/key/info` → `spend`, `max_budget`, `budget_reset_at`), **generic OpenAI-compatible proxy** | secret in Keychain | as reported |

Later (not v1): Gemini / Vertex (Cloud Monitoring), Azure OpenAI (Azure Monitor), Cursor, Copilot.

> Items 1 and 5 use **undocumented** endpoints that other open-source menu-bar tools rely on. They can change or rate-limit at any time. UI marks them "unofficial", and each has a local-log fallback (2 and 6). Verify exact response shapes at the start of Phase 6 against live responses (redacted fixtures go into tests).

#### Engine & refresh policy
- `actor UsageEngine` holds provider instances, per-provider `Backoff` (exponential, jitter, honours `Retry-After`, caps at 30 min), last snapshot, last error.
- `refreshAll()` → `withTaskGroup`, each provider under a 20 s timeout; results delivered to `@MainActor UsageStore` as `Sendable` values.
- Triggers: section opened and data older than 60 s; background every 15 min **only if** threshold alerts or the menu-bar meter are enabled; manual refresh button. Nothing when the section is hidden (same "hidden costs nothing" rule).
- Local-log providers: `JSONLTailReader` actor remembers `(inode, offset)` per file, so it parses only appended bytes; watches the folder with `DispatchSource`/FSEvents only while the section is visible.

#### UI
- Grid of `UsageCard`s: provider icon + account, one `QuotaBar` per window (colour by threshold 0–70 / 70–90 / 90+), "resets in 2h 14m", spend this month, top models.
- Badges: `Official` / `Unofficial` / `Estimated`; stale / error state with last-good value kept.
- Setup: Settings → AI Usage → "Add account" sheet per kind; keys pasted into a `SecureField`, stored straight into Keychain, never shown again (only last 4 chars).
- Optional: menu-bar text of the highest utilisation; `UNUserNotificationCenter` alert at 80% / 95% (asked for permission from a button).

---

## 5. Thread-safety model (Swift 6)

- **Swift 6 language mode**, complete strict concurrency; warnings are errors in CI.
- **Everything UI and every store is `@MainActor`** (`@Observable` classes). Views never touch actors directly.
- **All I/O off the main actor:** network in providers (`Sendable` structs using an injected `HTTPClient`), log parsing in `JSONLTailReader` actor, thumbnailing in QuickLook's queue.
- **Only `Sendable` values cross actor boundaries** (`Data`, `CGImage`, value-type snapshots). Never `NSImage`, `NSColor`, `EKEvent` — convert on the actor that owns them.
- **Callback APIs** (EventKit, QuickLook, `NSWorkspace` notifications): closures marked `@Sendable`, hop with `Task { @MainActor in … }` or `MainActor.assumeIsolated` when the queue is `.main`.
- **Cancellation is structural:** every long-running `Task` is stored and cancelled on stop/hide; loops check `Task.isCancelled`; `Task.sleep(for:)` instead of `DispatchQueue.asyncAfter` for new code.
- **No `@unchecked Sendable`** except `Keychain` (documented thread-safe Security API) — each exception has a comment explaining why.
- **No shared mutable statics.** `Preferences` is `@MainActor`; anything read off-main is copied into a `Sendable` config struct first.
- Run with `-Xswiftc -strict-concurrency=complete` and Thread Sanitizer (`swift build --sanitize=thread`) in the debug test pass.

## 6. Security model

- **Secrets only in Keychain**: `kSecClassGenericPassword`, service `com.orazz.myhub.credentials`, account = `ProviderID`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, no iCloud sync. `preferences.json` stores only a `SecretRef` (the id), never the value.
- **`Redacted<String>`** wrapper: `description`/`debugDescription` print `•••• last4`; secrets never reach `Logger` (and `Logger` interpolation uses `privacy: .private` by default).
- **Third-party credentials** (Claude Code Keychain item, `~/.codex/auth.json`, `~/.aws/credentials`): opt-in per provider with an explanation; read-only; never copied, persisted, refreshed or logged; re-read each fetch.
- **Networking**: `URLSession(configuration: .ephemeral)` — no cookies, no cache, no credential storage. HTTPS only (custom endpoint may use `http://localhost`/`127.0.0.1` only). Per-provider **host allowlist**; redirect delegate **drops the request** if the host changes (prevents leaking `Authorization`). Response body cap (4 MB), 20 s timeout. No cert pinning (would break corporate proxies), ATS left at defaults.
- **Untrusted input**: event text, clipboard, JSON from APIs and logs — decode with optional fields, bounded sizes, no `NSAppleScript`/shell with interpolated data, URLs opened only after scheme+host validation.
- **Files**: `~/Library/Application Support/MyHub/` created 0700, files written `.atomic` then chmod 0600. Broken JSON never overwritten (preserve user edits; show a banner).
- **Build/distribution**: hardened runtime, minimal entitlements (`personal-information.calendars` only; add `automation.apple-events` only if ever needed), Developer ID signing + notarization, no dependencies, `codesign --verify --strict`.
- **Privacy**: ContentShield covers Clipboard, Notes, Calendar, AI Usage (account names and spend) for screen sharing.

---

## 7. Phases

**Status (2026-09-30):** Phases 0–8 ✅ · Redesign (handoff `design_handoff_notch_shelf`, direction 1b) ✅: bottom dock, 600×300 panel, all tabs restyled, new Builds tab, shortcuts (⌥Space, ⌘⇧V), launch at login, open on hover, haptics. Open items: live verification of Codex / Admin APIs / OpenRouter / Bedrock / custom; Developer ID certificate for notarization.

Each phase ends with: builds clean under Swift 6 strict concurrency, tests pass, app launched and checked by eye.

| Phase | Scope | Done when |
|---|---|---|
| **0 — Scaffold** | `Package.swift`, `bundle.sh` (Info.plist `LSUIElement`, usage strings, signing), entitlements, `AppPaths`, `Log`, `Preferences`, `Keychain`, `Redacted`, test target | `./Scripts/bundle.sh && open build/MyHub.app` shows a menu-bar item; tests run |
| **1 — Island shell** | `ScreenMetrics`, `IslandWindow`, `IslandHostView`, `HoverMachine`+`HoverTracker`, `ScreenSession`, `IslandScreen`, `IslandCoordinator`, `IslandShape`, `HubTheme`, section rail (left/right), Settings section (show/hide sections, all displays) | Hover opens/closes smoothly on notch + non-notch displays, click-through works, 0% CPU idle |
| **2 — Stash** | `StashStore` (bookmarks), drag in/out, multi-select, thumbnails, reveal/open/copy | Files survive rename; no TCC prompt at launch |
| **3 — Clipboard** | `PasteboardMonitor`, `ClipHistory` (pins, cap), excluded apps, concealed types, optional encrypted persistence, ContentShield | Password-manager copies never recorded |
| **4 — Calendar** | `AgendaStore`, access-on-button, `CallLinkDetector`, join, calendar picker | Only allowlisted https links get a Join button |
| **5 — Notes** | `ScratchpadStore`, `WriteCoalescer`, keyboard handling, pin, filter | Typing never drops focus; flush on quit |
| **6 — AI Usage core** | Model, `UsageEngine`, `HTTPClient`, `Backoff`, `JSONLTailReader`, `PriceTable`; providers **Claude plan, Claude logs, Codex plan, Codex logs**; `UsageView` | Real numbers for a Claude Max + ChatGPT account on this Mac |
| **7 — AI Usage APIs** | **Anthropic Admin, OpenAI Admin, OpenRouter, Bedrock (SigV4 + CloudWatch, optional CE), Custom endpoint + LiteLLM preset**; setup sheets | SigV4 passes AWS test vectors; each provider decodes recorded fixtures |
| **8 — Polish** | Threshold notifications, menu-bar meter, ContentShield auto-on during screen share (optional), icon, DMG, notarization script, docs | Signed, notarized DMG |

### Phase 9 — Developer and designer tools (2026-10-01) ✅

| Feature | Where | How |
|---|---|---|
| Simulator shelf | Dev → Simulators | `xcrun simctl` (list, io screenshot/recordVideo, ui appearance, status_bar, openurl, push, erase) via `CommandRunner`; captures land in the Stash |
| Git at a glance | Dev → Git | `git status --porcelain=v2 --branch`, `git log -1`, `remote get-url`; PR + checks from GitHub REST (`GitHubClient`, api.github.com only, optional Keychain token) |
| CI watcher | Dev → CI | `actions/runs`; polls only while a visible run is in progress, flashes the notch on finish |
| Xcode housekeeping | Dev → Cleanup | sizes measured on demand; delete contents (caches), Trash (Archives), `simctl delete unavailable`; only children of folders under ~/Library |
| Clipboard dev tools | Clipboard tool row | pure `TextTool` transforms; results copied and recorded |
| Screenshot tray | Stash + Settings | `DispatchSource` on the screenshot folder, `kMDItemIsScreenCapture` xattr; opt-in; Annotate in Preview, Copy at 1x |
| Screen ruler + loupe | menu bar, ⌃⌥M | overlay `NSPanel` per display; loupe reads one ScreenCaptureKit still (Screen Recording asked on L only) |
| Focus timer | Focus tab, closed notch | pure `FocusCycle`; one sleep until the phase ends; `TimelineView` only while visible; Shortcuts for Focus modes |
| Snippets | Notes → Snippets, ⌃⌥S | `SnippetStore` (snippets.json, 0600), `{{placeholder}}` expansion, paste via the clipboard path |

### Phase 10 — Jira tab (2026-10-01) ✅

From `design_handoff_jira_tab` (all nine states). Deviation from the handoff: auth is
**email + API token (Basic)**, not OAuth 3LO — Atlassian's 3LO token exchange needs a
client secret, which a distributed desktop app can't keep, and requires an app registered
in the Atlassian developer console. The design's states map 1:1 (Connect → form,
Connecting → verifying `/myself`, Expired → 401). OAuth can be added later behind the same
`JiraStore.Connection` if an app registration (and a small token-exchange backend) exists.

- REST v3 `search/jql` (assigned), issue comments + ADF mention nodes (mentions, last 7 days,
  up to 15 tickets the user watches/owns/reported), Agile API boards/sprints (active sprint).
- Refresh: on view + every 3 min while visible; background every 15 min only with
  "Notify on mentions". Read mentions stored by comment id (last 300).
- Not built: avatar images (initials in a per-person colour instead), the optional unread
  badge on the closed notch.

### Phase 11 — Inbox + notch badge (2026-10-01) ✅

GitHub (token required: `/user`, search `review-requested:@me`, `author:@me` PRs → reviews +
issue/inline comments by others in 7 days, `mentions:@me`) and Jira mentions (from `JiraStore`)
merged newest-first; read state by item id (GitHub in `inbox.read`, Jira shared with the Jira
tab). Closed-notch badge: grey count, only while unread > 0 and nothing louder is showing.

### Phase 12 — Microsoft 365 calendar via Graph (2026-10-01) — built, switched off

Behind `Features.microsoftCalendar = false` until MyHub has its own app registration (in its
own Entra directory, ideally publisher-verified). To turn on: set the flag, ship the client ID
(or keep the Settings field), restore the README setup section from git history.


Why: Exchange Online's EWS shutdown (from 2026-10-01) breaks macOS Calendar's Microsoft 365 sync
until Apple's Graph-based update ships. MyHub signs in with the documented desktop flow (public
client, auth code + PKCE, loopback redirect, no secret), reads `/me/calendarView` for the next week
with `onlineMeeting.joinUrl`, and merges into the agenda (same title ±60 s = one meeting, keep
the one with a link). The user supplies the app registration's client ID (Settings). Open: a
shipped default client ID and publisher verification, for one-click sign-in.

### Phase 13 — Agents: live coding-agent sessions (2026-10-02) ✅ (step A1: Claude Code)

Claude Code hooks → `curl` (async, `|| true`) → `AgentHookServer` (loopback-only NWListener,
`POST /hook/<agent>`, `X-MyHub-Token`, 1 MB cap, immediate `{}`) → `AgentEvent` (parsed,
clipped, memory only) → `AgentStore` sessions (working / waiting / done / ended, last 100 steps,
forgotten after 30 min) → Agents tab, closed-notch pill, finish/attention flash.
`AgentHookInstaller` merges into `~/.claude/settings.json` (backup `.before-myhub`, idempotent,
removes only its own entries, refuses invalid JSON).
A2 ✅ Codex (`~/.codex/hooks.json`, async, trust once via `/hooks`) and Gemini CLI
(`~/.gemini/settings.json`, inline hook printing `{}`, timeout in ms); `AgentHookInstaller.Target`.
C ✅ email stashed files (default mail app via the compose service, or Mail.app when the
`mailto:` handler is a browser). B ✅ approvals: opt-in synchronous `PermissionRequest` command hook (curl prints MyHub's answer),
`/permission/<agent>` held up to 55 s, `PermissionAnswer` sends once, timeout/dismiss = `{}` (no
decision → Claude's own prompt); Claude Code only. D ✅ "Ask Claude Code" about stashed files or a
clicked window (`screencapture -iW`): `ClaudeCodeLauncher` writes a self-deleting 0700 `.command`
(every value single-quoted) that the default terminal opens: `cd` to the file's folder, `exec claude
'<question + paths>'`. The user's own CLI and sign-in; MyHub never calls a model.
D2 ✅ `AskTarget`: Claude Code via its `claude-cli://open?cwd&q` deep link (preferred terminal, prompt
not sent; `.command` fallback), Codex app via `codex://new?path&prompt`, the Claude app (declares
all files and folders) and ChatGPT (only when Launch Services lists it for the files) get the files,
the question on the clipboard. Strict percent-encoding; `q` capped at 5,000.

### Phase 14 — Figma in the Inbox (2026-10-02) ✅

Personal access token (`X-Figma-Token`, Keychain, `api.figma.com` only; scopes `current_user:read`,
`file_comments:read`, `file_metadata:read`, `file_versions:read`, optional `file_comments:write`).
No "my files" API, so the user pastes up to 10 file links (`FigmaLink`, keys validated). Each Inbox
refresh checks comments (+ versions) at most every 5 min; 429 pauses for `Retry-After`. `FigmaInbox`:
unresolved comments by others in 7 days → mention (`@handle`), reply in a thread the user joined, or
comment; named versions by others → new version. Rows: 👍, reply (root thread), copy link
(`/design/<key>?node-id=…#<comment>`). Flash for new mentions/replies/versions after the first check.

## 8. Risks

| Risk | Mitigation |
|---|---|
| Undocumented plan endpoints change / 429 | Fallback to local logs; "unofficial" badge; aggressive backoff; fixtures make breakage obvious |
| Keychain prompt for Claude Code item confuses users | Explain before triggering; allow "use local logs only" |
| Bedrock SSO/role credentials | v1: static keys + named profile; v2: `credential_process` / SSO cache |
| Cost Explorer charges per request | Off by default, hourly cap, shown in UI |
| Notch geometry edge cases (external displays, full-screen, mirrored) | Port the proven rules; manual test matrix in Phase 1 |
