import AppKit
import Observation

/// State shared by every screen's island: the chosen section, the stores and
/// the background work behind them. Per-screen state (open, keyboard, drop
/// target) lives in `ScreenSession`.
///
/// Rule for background work: a hidden section costs nothing. Hiding one stops
/// its timers and watchers; showing it again restarts them.
@MainActor
@Observable
final class HubModel {
    let preferences: Preferences
    let stash: StashStore
    let clipboard: PasteboardMonitor
    let agenda: AgendaStore
    let notes: ScratchpadStore
    let usage: UsageStore
    let builds: BuildStore
    let shield: ContentShield
    let dev: DevHub
    let jira: JiraStore
    let figma: FigmaStore
    let inbox: InboxStore
    let agents: AgentStore
    let focus: FocusStore
    let snippets: SnippetStore
    /// The screen ruler (menu bar, ⌃⌥M).
    let ruler = RulerController()
    @ObservationIgnored private let screenshots = ScreenshotWatcher()

    /// Half-filled form fields, kept while the panel is closed.
    let drafts = FormDrafts()

    /// Notes or Snippets, inside the Notes tab.
    var notesMode: NotesMode = .notes

    /// Restored at launch: the tab last used.
    var section: Section {
        didSet {
            guard section != oldValue else { return }
            if oldValue == .notes {
                notes.leave()
                snippets.sweep()
            }
            preferences.update { $0.general.lastSection = section.rawValue }
            updateVisibleWork()
            sectionShown(section)
            onSectionChange?(section)
        }
    }

    /// Whether any screen shows more than the bare notch. Clocks that only
    /// serve eyes (countdowns, progress) follow this.
    private(set) var isPanelActive = false

    /// Whether any screen holds the keyboard. Auto-switching sections (e.g. a
    /// screenshot arriving) must not yank a field out from under the caret.
    @ObservationIgnored var isTyping = false

    /// A form with fields is on screen in a section that does not otherwise
    /// type (e.g. adding an API key); a click into it takes the keyboard.
    @ObservationIgnored var formActive = false

    /// ⌥ is held over an open panel: the dock shows each tab's letter.
    var showsTabKeys = false

    /// Whether a click inside the island should hand it the keyboard.
    var clickTakesKeyboard: Bool { section.needsKeyboard || formActive }

    /// Wired by `IslandCoordinator`, which fans changes out to every screen.
    @ObservationIgnored var onSectionChange: ((Section) -> Void)?
    /// The menu bar item redraws its usage meter through this.
    @ObservationIgnored var onUsageMeterChange: (() -> Void)?
    @ObservationIgnored private let notifier = UsageNotifier()
    @ObservationIgnored var onDisplayLayoutChange: (() -> Void)?
    /// Open the island on a section (a permission request from an agent).
    @ObservationIgnored var onOpenRequest: ((Section) -> Void)?
    /// Collapse every island (after ⏎ in the clipboard).
    @ObservationIgnored var onCollapseRequest: (() -> Void)?
    /// A build ended; the coordinator flashes the closed notch.
    @ObservationIgnored var onBuildFinished: ((BuildRecord?) -> Void)?
    /// Any other news for the closed notch: a CI run, a focus round, a
    /// screenshot.
    @ObservationIgnored var onFlash: ((NotchFlash) -> Void)?
    /// The toggle shortcut changed; the app re-registers it.
    @ObservationIgnored var onShortcutChange: (() -> Void)?
    /// True while Settings records a new shortcut: the old one must not fire.
    @ObservationIgnored var onShortcutRecording: ((Bool) -> Void)?

    @ObservationIgnored private var started = false

    init(preferences: Preferences, stash: StashStore, notesFile: URL = AppPaths.file("notes.json"),
         buildHistoryFile: URL = AppPaths.file("build-history.json")) {
        // Snippets and the focus cycle live next to the notes (a temporary
        // folder in tests).
        let folder = notesFile.deletingLastPathComponent()
        self.dev = DevHub(preferences: preferences)
        self.jira = JiraStore(preferences: preferences)
        self.figma = FigmaStore(preferences: preferences)
        self.inbox = InboxStore(preferences: preferences, jira: jira, figma: figma)
        self.agents = AgentStore(preferences: preferences)
        self.focus = FocusStore(preferences: preferences, file: folder.appendingPathComponent("focus.json"))
        self.snippets = SnippetStore(file: folder.appendingPathComponent("snippets.json"))
        self.preferences = preferences
        self.stash = stash
        self.clipboard = PasteboardMonitor(preferences: preferences)
        self.agenda = AgendaStore(preferences: preferences)
        self.notes = ScratchpadStore(file: notesFile)
        self.usage = UsageStore(preferences: preferences, refreshesOnAdd: notesFile == AppPaths.file("notes.json"))
        self.builds = BuildStore(preferences: preferences, historyFile: buildHistoryFile)
        self.shield = ContentShield(preferences: preferences)
        self.section = Section(rawValue: preferences.values.general.lastSection) ?? .stash
        ThemeState.shared.theme = preferences.values.general.theme
        builds.onHistoryChange = { [weak self] in self?.onUsageMeterChange?() }
        builds.onFinished = { [weak self] record in
            guard let self, preferences.values.builds.notifyOnFinish else { return }
            onBuildFinished?(record)
        }
        clipboard.onImage = { [weak self] png in self?.receiveCapture(png) }
        dev.simulators.onCapture = { [weak self] url in self?.stashCapture(url) }
        dev.repos.onRunFinished = { [weak self] run in
            self?.onFlash?(NotchFlash(
                success: run.state == .success ? true : run.state == .failure ? false : nil,
                title: "\(run.repo.name) · \(run.workflow)",
                detail: BuildFormat.clock(run.updated.timeIntervalSince(run.started)),
                symbol: "checklist"
            ))
        }
        figma.onNew = { [weak self] item in
            let title = switch item.kind {
            case .mentioned: L10n.format("%@ mentioned you", item.actor)
            case .replied: L10n.format("%@ replied", item.actor)
            default: L10n.format("New version: %@", item.title)
            }
            self?.onFlash?(NotchFlash(success: nil, title: title, detail: item.kind == .newVersion ? item.reference : item.title, symbol: "pencil.and.outline"))
        }
        jira.onNewMention = { [weak self] mention in
            self?.onFlash?(NotchFlash(success: nil, title: L10n.format("%@ mentioned you", mention.author),
                                      detail: mention.issueKey, symbol: "bubble.left.fill"))
        }
        agents.onFinished = { [weak self] session in
            guard let self, preferences.values.agents.flashOnFinish else { return }
            onFlash?(NotchFlash(success: true, title: "\(session.agentName) · \(session.project ?? L10n.string("finished"))",
                                detail: BuildFormat.clock(Date().timeIntervalSince(session.turnStarted))))
        }
        agents.onApprovalRequest = { [weak self] approval in
            guard let self, isVisible(.agents) else { return }
            if preferences.values.agents.openForApprovals {
                onOpenRequest?(.agents)
            } else {
                onFlash?(NotchFlash(success: nil, title: L10n.format("Approve: %@", approval.step.summary), detail: "",
                                    symbol: "hand.raised.fill"))
            }
        }
        agents.onNeedsAttention = { [weak self] session, message in
            self?.onFlash?(NotchFlash(success: nil, title: "\(session.agentName) · \(message)", detail: "", symbol: "hand.raised.fill"))
        }
        focus.onPhaseEnded = { [weak self] ended, next in
            self?.onFlash?(NotchFlash(
                success: nil,
                title: ended == .work ? L10n.string("Focus round done") : L10n.string("Break over"),
                detail: next.isBreak ? next.title : L10n.string("Ready"),
                symbol: ended == .work ? "cup.and.saucer.fill" : "timer"
            ))
        }
        screenshots.onScreenshot = { [weak self] url in
            guard let self, isVisible(.stash) else { return }
            stash.add([url])
            onFlash?(NotchFlash(success: nil, title: L10n.string("Screenshot stashed"), detail: "", symbol: "camera.viewfinder"))
        }
        usage.onRefreshed = { [weak self] alerts in
            guard let self else { return }
            alerts.forEach(notifier.post)
            onUsageMeterChange?()
        }
    }

    // MARK: - Rail

    var hiddenSections: Set<Section> {
        Set(preferences.values.hiddenSections.compactMap(Section.init(rawValue:))).filter(\.canHide)
    }

    func isVisible(_ section: Section) -> Bool { !hiddenSections.contains(section) }

    var railSections: [Section] { Section.allCases.filter(isVisible) }

    func setVisible(_ target: Section, _ visible: Bool) {
        if !target.canHide || isVisible(target) == visible { return }
        preferences.update { values in
            var hidden = Set(values.hiddenSections)
            if visible { hidden.remove(target.rawValue) } else { hidden.insert(target.rawValue) }
            values.hiddenSections = hidden.sorted()
        }
        if visible {
            if started { startWork(for: target) }
        } else {
            stopWork(for: target)
            if section == target { section = railSections.first ?? .settings }
        }
    }

    // MARK: - Display layout

    func setShowOnAllDisplays(_ on: Bool) {
        preferences.update { $0.showOnAllDisplays = on }
        onDisplayLayoutChange?()
    }

    // MARK: - Usage meter and alerts

    func setMenuBarMeter(_ on: Bool) {
        preferences.update { $0.usage.menuBarMeter = on }
        updateUsageBackground()
        if on { usage.refresh(force: false) }
        onUsageMeterChange?()
    }

    /// Turning alerts on asks for notification permission, from this switch
    /// and nowhere else. Returns false when permission was refused.
    func setUsageAlerts(_ on: Bool) async -> Bool {
        if on {
            guard await notifier.requestPermission() else { return false }
        }
        preferences.update { $0.usage.alerts = on }
        updateUsageBackground()
        if on { usage.refresh(force: false) }
        return true
    }

    private func updateUsageBackground() {
        let wanted = started && isVisible(.usage)
            && (preferences.values.usage.menuBarMeter || preferences.values.usage.alerts)
        usage.setBackground(wanted)
    }

    // MARK: - General settings

    func setOpenOnHover(_ on: Bool) { preferences.update { $0.general.openOnHover = on } }

    func setHaptics(_ on: Bool) { preferences.update { $0.general.haptics = on } }

    func setSwitchTabsOnHover(_ on: Bool) { preferences.update { $0.general.switchTabsOnHover = on } }

    func setPanelPosition(_ position: PanelPosition) {
        preferences.update { $0.general.panelPosition = position }
        onDisplayLayoutChange?()
    }

    func setTheme(_ theme: PanelTheme) {
        preferences.update { $0.general.theme = theme }
        ThemeState.shared.theme = theme
    }

    func setPanelSize(_ size: PanelSize) {
        preferences.update { $0.general.panelSize = size }
        onDisplayLayoutChange?()
    }

    func setToggleShortcut(_ shortcut: Shortcut) {
        preferences.update { $0.general.toggleShortcut = shortcut }
        onShortcutChange?()
    }

    func setRulerShortcut(_ shortcut: Shortcut) {
        preferences.update { $0.design.rulerShortcut = shortcut }
        onShortcutChange?()
    }

    func setNotifyOnBuild(_ on: Bool) {
        preferences.update { $0.builds.notifyOnFinish = on }
        updateBuildsBackground()
    }

    func setBuildTool(_ tool: Preferences.Builds.Tool) {
        preferences.update { $0.builds.tool = tool }
        if tool == .android { builds.selectPlatform(.android) }
        if tool == .xcode { builds.selectPlatform(.xcode) }
    }

    /// A slow background poll, only while something outside the panel needs
    /// it: the finish flash, or today's build time in the menu bar.
    private func updateBuildsBackground() {
        let wanted = preferences.values.builds.notifyOnFinish || preferences.values.builds.menuBarTime
        builds.setBackground(started && isVisible(.builds) && wanted)
    }

    func setMenuBarBuildTime(_ on: Bool) {
        preferences.update { $0.builds.menuBarTime = on }
        updateBuildsBackground()
        if on { Task { await builds.poll() } }
        onUsageMeterChange?()
    }

    /// ⏎ in the clipboard: the entry is already on the pasteboard; fold the
    /// island so the app underneath is in front again, then paste into it —
    /// when the user has allowed MyHub to (Accessibility). Otherwise it
    /// simply stays on the clipboard for ⌘V.
    func pasteAndClose() {
        onCollapseRequest?()
        Paster.pasteIntoFrontApp(after: .milliseconds(180))
    }

    /// Expands a snippet onto the clipboard; with `paste`, folds the island
    /// and pastes it into the app underneath (as ⏎ does in the clipboard).
    func useSnippet(_ snippet: Snippet, paste: Bool) {
        let current = NSPasteboard.general.string(forType: .string)
        clipboard.copyText(SnippetExpander.expand(snippet.body, clipboard: current), record: false)
        if paste { pasteAndClose() }
    }

    /// Turning screenshot collection on is the moment macOS may ask for
    /// access to the screenshot folder — never earlier.
    func setCollectScreenshots(_ on: Bool) {
        preferences.update { $0.design.collectScreenshots = on }
        updateScreenshotWatcher()
    }

    private func updateScreenshotWatcher() {
        if started, isVisible(.stash), preferences.values.design.collectScreenshots {
            screenshots.start()
        } else {
            screenshots.stop()
        }
    }

    /// A simulator screenshot or recording.
    private func stashCapture(_ url: URL) {
        guard isVisible(.stash) else { return }
        stash.add([url])
    }

    func setFullHeightDrawnNotch(_ on: Bool) {
        preferences.update { $0.fullHeightDrawnNotch = on }
        onDisplayLayoutChange?()
    }

    // MARK: - Lifecycle

    func start() {
        started = true
        for target in railSections { startWork(for: target) }
        updateUsageBackground()
        updateBuildsBackground()
        // Catch up on builds finished while MyHub was not running, before
        // Xcode prunes their logs.
        if isVisible(.builds) { Task { [builds] in await builds.poll() } }
        if !isVisible(section) { section = railSections.first ?? .settings }
    }

    func stop() {
        started = false
        for target in Section.allCases { stopWork(for: target) }
        // Whatever was typed reaches the disk even when quitting mid-thought.
        notes.flush()
        snippets.flush()
        builds.flush()
    }

    /// Opening starts the work behind the visible tab — a calendar reload,
    /// a usage refresh, a builds poll — but only once the open animation has
    /// settled: results landing mid-spring re-render the panel and cost it
    /// frames. Closing stops everything at once.
    func setPanelActive(_ active: Bool) {
        if active == isPanelActive { return }
        isPanelActive = active
        settleTask?.cancel()
        settleTask = active ? Task { [weak self] in
            // Let the opening animation run on an idle main thread first.
            try? await Task.sleep(for: HubTheme.Motion.openSettle)
            if Task.isCancelled { return }
            self?.panelSettledOpen()
        } : nil
        if !active {
            if isVisible(.calendar) { agenda.setActive(false) }
            updateVisibleWork()
        }
    }

    private func panelSettledOpen() {
        guard isPanelActive else { return }
        if isVisible(.calendar) { agenda.setActive(true) }
        updateVisibleWork()
        sectionShown(section)
    }

    @ObservationIgnored private var settleTask: Task<Void, Never>?

    /// AI usage and Builds poll only while someone is looking at them.
    private func updateVisibleWork() {
        usage.setVisible(isPanelActive && section == .usage && isVisible(.usage))
        builds.setVisible(isPanelActive && section == .builds && isVisible(.builds))
        jira.setVisible(isPanelActive && section == .jira && isVisible(.jira))
        inbox.setVisible(isPanelActive && section == .inbox && isVisible(.inbox))
    }

    /// A section came into view: the moment to touch the disk, ask for fresh
    /// data, or re-read a file edited elsewhere — never earlier.
    private func sectionShown(_ shown: Section) {
        switch shown {
        case .stash: stash.refreshIfStale()
        case .calendar: agenda.refreshAccess()
        case .dev: dev.pageShown()
        case .agents: agents.refreshInstalled()
        case .clipboard, .notes, .usage, .builds, .settings, .focus, .jira, .inbox: break
        }
    }

    /// Files dropped on the island by hand. Refused while there is no stash to
    /// show them on — a drop that lands nowhere visible is worse than a bounce.
    func accept(urls: [URL]) -> Bool {
        guard isVisible(.stash) else { return false }
        stash.add(urls)
        section = .stash
        return true
    }

    /// A picture copied here or on an iPhone (Continuity): saved as a file,
    /// put in the stash, listed in the history. The island switches to the
    /// stash only if no text field there has the keyboard: a switch would
    /// take focus away and the next keystrokes would land in another app.
    private func receiveCapture(_ png: Data) {
        Task { [weak self] in
            guard let url = await CaptureFolder.save(png), let self else { return }
            stash.add([url])
            clipboard.recordCapture(url)
            if isPanelActive, !isTyping, isVisible(.stash) { section = .stash }
        }
    }

    private func startWork(for target: Section) {
        switch target {
        case .clipboard: clipboard.start()
        case .calendar:
            // Picks up where it left off only if access was already granted;
            // never prompts on its own.
            agenda.start()
            if isPanelActive { agenda.setActive(true) }
        case .usage: updateUsageBackground()
        case .builds: updateBuildsBackground()
        case .focus: focus.start()
        case .dev: dev.start()
        case .jira: jira.start()
        case .inbox: inbox.start()
        case .agents: agents.start()
        case .stash: updateScreenshotWatcher()
        case .notes, .settings: break
        }
    }

    private func stopWork(for target: Section) {
        switch target {
        case .clipboard: clipboard.stop()
        case .calendar: agenda.stop()
        case .usage:
            usage.setVisible(false)
            usage.setBackground(false)
        case .builds:
            builds.setVisible(false)
            builds.setBackground(false)
        case .focus: focus.stop()
        case .dev: dev.stop()
        case .jira: jira.stop()
        case .inbox: inbox.stop()
        case .agents: agents.stop()
        case .stash: screenshots.stop()
        case .notes, .settings: break
        }
    }
}
