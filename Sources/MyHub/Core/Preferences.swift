import AppKit
import Observation

/// Everything the user configures, in `preferences.json`.
///
/// **Never secrets.** API keys and tokens live in the Keychain; this file only
/// ever names them.
///
/// **Forward compatible.** A file written by an older version lacks the keys
/// added since. Instead of a hand-written `init(from:)` per key, the stored
/// JSON is deep-merged over the defaults before decoding, so a missing key
/// simply takes its default and a new setting never breaks an old file.
///
/// **Hand edits are respected.** A file that exists but does not parse is
/// never overwritten: we run on defaults and stop writing until it is fixed.
@MainActor
@Observable
final class Preferences {
    struct Clipboard: Codable, Equatable, Sendable {
        var saveImagesToStash = false
        var persistHistory = false
        var historyLimit = 50
        /// Copies made while one of these apps is frontmost are not recorded.
        var excludedBundleIDs: [String] = [
            "com.1password.1password",
            "com.agilebits.onepassword7",
            "com.bitwarden.desktop",
            "com.apple.keychainaccess",
            "com.apple.Passwords",
        ]
    }

    struct Calendar: Codable, Equatable, Sendable {
        /// Calendars unticked in the Calendar section's picker. Independent of
        /// Calendar.app's own checkboxes: a shared calendar may be worth seeing
        /// there and noise in a glance at the notch.
        var hiddenCalendarIDs: [String] = []
    }

    struct Usage: Codable, Equatable, Sendable {
        /// Configured sources. Secrets are in the Keychain under each id.
        var accounts: [UsageAccount] = []
        /// Show the fullest limit as a percentage next to the menu bar icon.
        var menuBarMeter = false
        /// Notify when a limit crosses 80% and 95%.
        var alerts = false
    }

    struct General: Codable, Equatable, Sendable {
        /// Off: the island opens only on a click or the shortcut.
        var openOnHover = true
        /// A light haptic tick on the trackpad when the island opens.
        var haptics = false
        /// Toggle-panel shortcut, as a virtual key code plus Carbon modifiers.
        var toggleShortcut = Shortcut.optionSpace
        /// Restored at launch.
        var lastSection = Section.stash.rawValue
        /// How much room the open panel takes (see `PanelSize`).
        var panelSize = PanelSize.standard
        /// Under the notch, or near the left or right corner.
        var panelPosition = PanelPosition.center
        /// Resting on a dock icon for a moment selects it.
        var switchTabsOnHover = true
        /// Background and accent of the open panel.
        var theme = PanelTheme.classic
    }

    struct Builds: Codable, Equatable, Sendable {
        enum Tool: String, Codable, Sendable { case xcode, android, both }
        var tool: Tool = .xcode
        /// Briefly expand the closed notch when a build finishes.
        var notifyOnFinish = true
        /// Today's build time next to the menu bar icon (as BuildWatch does).
        var menuBarTime = false
        /// Schemes / projects left out of the statistics (toggled from the
        /// chart's legend).
        var hiddenSchemes: [String] = []
    }

    struct Dev: Codable, Equatable, Sendable {
        /// Git working copies shown on the Git page, as absolute paths.
        var repos: [String] = []
        /// Keep checking a GitHub Actions run that is in progress and flash
        /// the notch when it finishes.
        var watchCI = true
        /// Last values typed on the Simulators page.
        var deepLink = ""
        var pushBundleID = ""
    }

    struct Focus: Codable, Equatable, Sendable {
        var workMinutes = 25
        var shortBreakMinutes = 5
        var longBreakMinutes = 15
        /// Work rounds before a long break.
        var rounds = 4
        /// Names of Shortcuts (Shortcuts.app) run when a focus round starts
        /// and ends — the documented way to switch a Focus mode on and off.
        var startShortcut = ""
        var endShortcut = ""
        var chime = true
        /// The countdown on the closed notch while a round runs.
        var showInNotch = true
        /// Run the start and end Shortcuts around each focus round.
        var doNotDisturb = false
    }

    struct Design: Codable, Equatable, Sendable {
        /// New screenshots go to the Stash. Off by default: watching the
        /// screenshot folder (usually the Desktop) needs folder access.
        var collectScreenshots = false
        var rulerShortcut = Shortcut.ruler
    }

    struct Jira: Codable, Equatable, Sendable {
        /// `acme.atlassian.net`; empty when not connected. The API token is in
        /// the Keychain.
        var site = ""
        var email = ""
        /// assigned / mentions / sprint — the last view used.
        var view = "assigned"
        /// The board whose active sprint is shown; nil picks one.
        var boardID: Int?
        /// Check every 15 minutes in the background and flash the notch for
        /// a new mention.
        var notifyMentions = false
        /// Mentions already seen (comment ids), newest last.
        var readMentions: [String] = []
    }

    struct Agents: Codable, Equatable, Sendable {
        /// Loopback port the hooks post to. Fixed, because it is written into
        /// the agents' settings files.
        var port: UInt16 = 47391
        /// Shared secret the hooks send along; not a credential, it only
        /// keeps web pages from posting fake events.
        var token = ""
        /// A pill on the closed notch while an agent works.
        var showInNotch = true
        /// Flash the notch when an agent finishes its turn.
        var flashOnFinish = true
        /// Answer Claude Code's permission requests from the notch (adds a
        /// second, synchronous hook). Off until the user turns it on.
        var approvals = false
        /// Open the panel on the Agents tab when a request arrives.
        var openForApprovals = true
    }

    struct Microsoft: Codable, Equatable, Sendable {
        /// The app registration's Application (client) ID — not a secret.
        var clientID = ""
        /// "Name · address" of the signed-in account, for Settings.
        var account = ""
    }

    struct Inbox: Codable, Equatable, Sendable {
        /// A quiet unread count on the closed notch.
        var badge = true
        /// GitHub items already opened (ids), newest last.
        var read: [String] = []
    }

    struct Figma: Codable, Equatable, Sendable {
        struct File: Codable, Equatable, Sendable {
            var key: String
            var name: String
        }
        /// Files whose comments and versions feed the Inbox. The token is in
        /// the Keychain.
        var files: [File] = []
        /// Flash the notch for a new mention or reply.
        var notifyComments = true
        /// Flash for a named version, and list versions in the Inbox.
        var notifyVersions = true
        /// Items already opened (ids), newest last.
        var read: [String] = []
    }

    struct Values: Codable, Equatable, Sendable {
        var showOnAllDisplays = true
        var fullHeightDrawnNotch = false
        /// Stored as what is hidden, so sections added later show up for everyone.
        var hiddenSections: [String] = []
        var shieldedSections: [String] = []
        var clipboard = Clipboard()
        var calendar = Calendar()
        var usage = Usage()
        var general = General()
        var builds = Builds()
        var dev = Dev()
        var focus = Focus()
        var design = Design()
        var jira = Jira()
        var inbox = Inbox()
        var microsoft = Microsoft()
        var agents = Agents()
        var figma = Figma()
    }

    enum LoadError: Error { case notAnObject }

    static let shared = Preferences(file: AppPaths.file("preferences.json"))

    let file: URL
    private(set) var values: Values
    /// True when the file exists but cannot be read; writes are suspended.
    private(set) var isFileBroken = false

    init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file) {
            do {
                values = try Self.decode(data)
            } catch {
                values = Values()
                isFileBroken = true
                Log.storage.error("preferences.json is unreadable, running on defaults: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            values = Values()
            save()
        }
    }

    /// The one way to change a setting: mutate a copy, write only if it moved.
    func update(_ change: (inout Values) -> Void) {
        var next = values
        change(&next)
        guard next != values else { return }
        values = next
        save()
    }

    func revealInFinder() {
        if !FileManager.default.fileExists(atPath: file.path) { save() }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    // MARK: - Encoding

    static func decode(_ data: Data) throws -> Values {
        let defaultsData = try JSONEncoder().encode(Values())
        guard let defaults = try JSONSerialization.jsonObject(with: defaultsData) as? [String: Any],
              var stored = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoadError.notAnObject
        }
        upgradeRenamed(&stored)
        let merged = try JSONSerialization.data(withJSONObject: deepMerge(defaults, over: stored))
        return try JSONDecoder().decode(Values.self, from: merged)
    }

    /// Keys and values written by builds from before the Shelf tab became the
    /// Stash. Rewritten on read; the next save stores the new names.
    static func upgradeRenamed(_ stored: inout [String: Any]) {
        let renamed = { (raw: String) in raw == "shelf" ? Section.stash.rawValue : raw }
        if var general = stored["general"] as? [String: Any] {
            if let last = general["lastSection"] as? String { general["lastSection"] = renamed(last) }
            stored["general"] = general
        }
        for key in ["hiddenSections", "shieldedSections"] {
            if let list = stored[key] as? [String] { stored[key] = list.map(renamed) }
        }
        // Before the Do Not Disturb switch existed, naming a Shortcut was
        // enough to run it; keep that working for whoever set one up.
        if var focus = stored["focus"] as? [String: Any], focus["doNotDisturb"] == nil {
            let named = [focus["startShortcut"], focus["endShortcut"]].contains { ($0 as? String)?.isEmpty == false }
            if named { focus["doNotDisturb"] = true; stored["focus"] = focus }
        }
        if var clipboard = stored["clipboard"] as? [String: Any],
           let old = clipboard.removeValue(forKey: "saveImagesToShelf") {
            if clipboard["saveImagesToStash"] == nil { clipboard["saveImagesToStash"] = old }
            stored["clipboard"] = clipboard
        }
    }

    static func deepMerge(_ base: [String: Any], over overlay: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in overlay {
            if let inner = base[key] as? [String: Any], let innerOverlay = value as? [String: Any] {
                result[key] = deepMerge(inner, over: innerOverlay)
            } else {
                result[key] = value
            }
        }
        return result
    }

    private func save() {
        guard !isFileBroken else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try AppPaths.writePrivate(try encoder.encode(values), to: file)
        } catch {
            Log.storage.error("cannot write preferences.json: \(error.localizedDescription, privacy: .public)")
        }
    }
}
