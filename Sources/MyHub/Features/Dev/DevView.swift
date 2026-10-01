import SwiftUI

/// The Dev tab: Simulators, Git, CI and Cleanup behind a segmented switch.
struct DevView: View {
    let dev: DevHub
    let preferences: Preferences
    let session: ScreenSession
    /// Pages with text fields take the keyboard on a click.
    let onFormActive: (Bool) -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                HubSegmented(options: DevHub.Page.allCases.map { ($0, $0.title) },
                             selection: Binding(get: { dev.page }, set: { dev.page = $0 }))
                Spacer(minLength: 6)
                pageActions
            }
            .frame(height: 26)
            Group {
                switch dev.page {
                case .simulators: SimulatorsPage(store: dev.simulators, preferences: preferences)
                case .git: GitPage(repos: dev.repos)
                case .ci: CIPage(repos: dev.repos, preferences: preferences)
                case .cleanup: CleanupPage(cleanup: dev.cleanup)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            dev.pageShown()
            onFormActive(dev.page == .simulators || dev.page == .git)
        }
        .onChange(of: dev.page) { _, page in onFormActive(page == .simulators || page == .git) }
        .onDisappear { onFormActive(false) }
        .onKeyPress(.escape) {
            session.wantsKeyboard = false
            return .handled
        }
    }

    @ViewBuilder
    private var pageActions: some View {
        switch dev.page {
        case .simulators:
            if let message = dev.simulators.busy ?? dev.simulators.message {
                Text(message).font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.soft).lineLimit(1)
            }
            GhostPill(title: L10n.string("Simulator"), symbol: "iphone") { dev.simulators.openSimulatorApp() }
        case .git, .ci:
            if dev.repos.isRefreshing { ProgressView().controlSize(.mini) }
            GhostPill(title: L10n.string("Add repo"), symbol: "plus") { dev.repos.chooseRepository() }
            GhostPill(title: L10n.string("Refresh"), symbol: "arrow.clockwise") { dev.repos.refresh() }
        case .cleanup:
            if dev.cleanup.reclaimed > 0 {
                Text(L10n.format("Freed %@", BuildFormat.bytes(dev.cleanup.reclaimed)))
                    .font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.success)
            }
            GhostPill(title: L10n.string("Measure"), symbol: "arrow.clockwise") { dev.cleanup.measure() }
        }
    }
}

// MARK: - Shared bits

/// A one-line text field on a card background.
struct PanelField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var onSubmit: () -> Void = {}

    var body: some View {
        Group {
            if secure {
                SecureField("", text: $text, prompt: prompt)
            } else {
                TextField("", text: $text, prompt: prompt)
            }
        }
        .textFieldStyle(.plain)
        .font(HubTheme.Font.body)
        .foregroundStyle(HubTheme.Palette.primary)
        .onSubmit(onSubmit)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: HubTheme.Radius.row, style: .continuous).fill(HubTheme.Palette.selected))
    }

    private var prompt: Text { Text(placeholder).foregroundStyle(HubTheme.Palette.tertiary) }
}

/// A square-ish action tile: icon over a short label.
struct ActionTile: View {
    let title: String
    let symbol: String
    var tint: Color = HubTheme.Palette.soft
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 15))
                Text(title).font(HubTheme.Font.meta).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(active ? HubTheme.Palette.onLight : tint)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(RoundedRectangle(cornerRadius: HubTheme.Radius.row, style: .continuous)
                .fill(active ? HubTheme.Palette.accent : HubTheme.Palette.selected))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressFade())
    }
}

extension CheckState {
    var color: Color {
        switch self {
        case .success: HubTheme.Palette.success
        case .failure: HubTheme.Palette.danger
        case .pending: HubTheme.Palette.amber
        case .neutral: HubTheme.Palette.iconInactive
        }
    }

    var symbol: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        case .pending: "circle.dotted"
        case .neutral: "minus.circle"
        }
    }
}

// MARK: - Simulators

private struct SimulatorsPage: View {
    let store: SimulatorStore
    let preferences: Preferences
    @Environment(FormDrafts.self) private var drafts

    var body: some View {
        if store.toolsMissing {
            EmptyPaneHint(symbol: "hammer", text: L10n.string("Install Xcode to use simulators."))
        } else if store.booted.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string("No simulator is running. Boot one:"))
                    .font(HubTheme.Font.body).foregroundStyle(HubTheme.Palette.secondary)
                WrapLayout(spacing: 6) {
                    ForEach(store.bootable) { device in
                        GhostPill(title: device.name, symbol: "power") { store.boot(device) }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .hubCard()
        } else {
            HStack(alignment: .top, spacing: 8) {
                deviceList.frame(width: 170)
                actions
            }
            .onAppear {
                drafts.seed("sim.link", preferences.values.dev.deepLink)
                drafts.seed("sim.bundle", preferences.values.dev.pushBundleID)
            }
        }
    }

    private var deviceList: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 2) {
                ForEach(store.booted) { device in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name).font(HubTheme.Font.bodyMedium).lineLimit(1)
                        Text(device.runtime).font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.tertiary)
                    }
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .selectedRow(store.selected?.udid == device.udid)
                    .contentShape(Rectangle())
                    .onTapGesture { store.selectedID = device.udid }
                }
            }
        }
    }

    private var actions: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    ActionTile(title: L10n.string("Screenshot"), symbol: "camera") { store.screenshot() }
                    ActionTile(title: store.isRecording ? L10n.string("Stop") : L10n.string("Record"),
                               symbol: store.isRecording ? "stop.fill" : "record.circle", active: store.isRecording) { store.toggleRecording() }
                    ActionTile(title: L10n.string("Light"), symbol: "sun.max") { store.setAppearance(dark: false) }
                    ActionTile(title: L10n.string("Dark"), symbol: "moon") { store.setAppearance(dark: true) }
                    ActionTile(title: "9:41", symbol: "battery.100") { store.cleanStatusBar() }
                    ActionTile(title: L10n.string("Reset bar"), symbol: "arrow.uturn.backward") { store.resetStatusBar() }
                }
                HStack(spacing: 6) {
                    PanelField(placeholder: L10n.string("Deep link, e.g. myapp://settings"), text: drafts.binding("sim.link")) { openLink() }
                    GhostPill(title: L10n.string("Open"), symbol: "link") { openLink() }
                }
                HStack(spacing: 6) {
                    PanelField(placeholder: L10n.string("Bundle ID"), text: drafts.binding("sim.bundle")).frame(width: 150)
                    PanelField(placeholder: L10n.string("Push message"), text: drafts.binding("sim.push")) { push() }
                    GhostPill(title: L10n.string("Push"), symbol: "bell.badge") { push() }
                }
                HStack(spacing: 6) {
                    Spacer()
                    if store.confirmingErase {
                        Text(L10n.string("Erase all content and settings?")).font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.soft)
                        GhostPill(title: L10n.string("Erase"), symbol: "trash", tint: HubTheme.Palette.danger) { store.erase() }
                        GhostPill(title: L10n.string("Cancel"), symbol: "xmark") { store.confirmingErase = false }
                    } else {
                        GhostPill(title: L10n.string("Erase device…"), symbol: "trash") { store.confirmingErase = true }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func openLink() {
        let link = drafts["sim.link"]
        if store.openURL(link) { preferences.update { $0.dev.deepLink = link } }
    }

    private func push() {
        let bundleID = drafts["sim.bundle"]
        preferences.update { $0.dev.pushBundleID = bundleID }
        store.sendPush(bundleID: bundleID, message: drafts["sim.push"])
    }
}

// MARK: - Git

private struct GitPage: View {
    let repos: RepoStore
    @Environment(FormDrafts.self) private var drafts
    private var editingToken: Bool { drafts["github.editing"] == "1" }

    var body: some View {
        if repos.toolsMissing {
            EmptyPaneHint(symbol: "hammer", text: L10n.string("Git needs Xcode or the Command Line Tools (xcode-select --install)."))
        } else if repos.repos.isEmpty {
            VStack(spacing: 10) {
                EmptyPaneHint(symbol: "arrow.triangle.branch", text: L10n.string("Add a Git working copy to see its branch, changes, pull request and checks."))
                GhostPill(title: L10n.string("Add repo"), symbol: "plus") { repos.chooseRepository() }
            }
        } else {
            VStack(spacing: 6) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(repos.repos) { RepoCard(repo: $0, store: repos) }
                    }
                }
                tokenRow
            }
        }
    }

    private var tokenRow: some View {
        HStack(spacing: 6) {
            if let problem = repos.githubProblem {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(HubTheme.Palette.warn)
                Text(problem).lineLimit(1)
            } else {
                Text(repos.hasToken ? L10n.string("GitHub token in Keychain") : L10n.string("No GitHub token — public repos only, 60 requests/hour"))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if editingToken {
                PanelField(placeholder: L10n.string("Fine-grained token (read-only)"), text: drafts.binding("github.token"), secure: true) { save() }
                    .frame(width: 200)
                GhostPill(title: L10n.string("Save"), symbol: "checkmark") { save() }
                GhostPill(title: L10n.string("Cancel"), symbol: "xmark") { drafts.clear("github.token", "github.editing") }
            } else if repos.hasToken {
                GhostPill(title: L10n.string("Remove token"), symbol: "key") { repos.removeToken() }
            } else {
                GhostPill(title: L10n.string("Add token"), symbol: "key") { drafts["github.editing"] = "1" }
            }
        }
        .font(HubTheme.Font.meta)
        .foregroundStyle(HubTheme.Palette.tertiary)
        .frame(height: 28)
    }

    private func save() {
        repos.saveToken(drafts["github.token"])
        drafts.clear("github.token", "github.editing")
    }
}

private struct RepoCard: View {
    let repo: RepoStore.Repo
    let store: RepoStore
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(repo.name).font(HubTheme.Font.buildTarget).lineLimit(1)
                if let status = repo.status {
                    Label(status.branch ?? L10n.string("detached"), systemImage: "arrow.triangle.branch")
                        .font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.soft).lineLimit(1)
                    if status.ahead > 0 { badge("↑\(status.ahead)", HubTheme.Palette.blue) }
                    if status.behind > 0 { badge("↓\(status.behind)", HubTheme.Palette.warn) }
                    if status.conflicted > 0 { badge(L10n.format("%d conflicts", status.conflicted), HubTheme.Palette.danger) }
                    if status.isClean {
                        badge(L10n.string("clean"), HubTheme.Palette.success)
                    } else if status.changed + status.untracked > 0 {
                        badge(L10n.format("%d changed", status.changed + status.untracked), HubTheme.Palette.accentLight)
                    }
                }
                Spacer(minLength: 4)
                if hovering {
                    Button { store.reveal(repo) } label: { Image(systemName: "folder") }
                        .buttonStyle(HubIconButtonStyle(size: 22)).help(L10n.string("Show in Finder"))
                    Button { store.openInTerminal(repo) } label: { Image(systemName: "terminal") }
                        .buttonStyle(HubIconButtonStyle(size: 22)).help(L10n.string("Open in Terminal"))
                    Button { store.remove(repo.path) } label: { Image(systemName: "xmark") }
                        .buttonStyle(HubIconButtonStyle(size: 22)).help(L10n.string("Remove from MyHub"))
                }
            }
            if let problem = repo.problem {
                Text(problem).font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.danger).lineLimit(1)
            } else if let commit = repo.lastCommit {
                Text(commit).font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.tertiary).lineLimit(1)
            }
            if let pull = repo.pull {
                Button { store.openOnGitHub(pull.url) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.pull").foregroundStyle(HubTheme.Palette.blue)
                        Text("#\(pull.number) \(pull.title)").lineLimit(1)
                        if pull.draft { badge(L10n.string("draft"), HubTheme.Palette.iconInactive) }
                        Spacer(minLength: 4)
                        if let checks = pull.checks {
                            Image(systemName: checks.symbol).foregroundStyle(checks.color)
                        }
                    }
                    .font(HubTheme.Font.meta)
                    .foregroundStyle(HubTheme.Palette.soft)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressFade())
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: HubTheme.Radius.eventCard, style: .continuous).fill(HubTheme.Palette.card))
        .onHover { hovering = $0 }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(HubTheme.Font.axis)
            .foregroundStyle(color)
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

// MARK: - CI

private struct CIPage: View {
    let repos: RepoStore
    let preferences: Preferences

    var body: some View {
        VStack(spacing: 6) {
            if repos.runs.isEmpty {
                EmptyPaneHint(symbol: "checklist",
                              text: repos.repos.contains { $0.github != nil }
                                ? L10n.string("No GitHub Actions runs found.")
                                : L10n.string("Add a repository hosted on GitHub (Git page) to see its Actions runs."))
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(repos.runs) { RunRow(run: $0) { repos.openOnGitHub($0.url) } }
                    }
                }
            }
            HStack {
                Toggle(isOn: Binding(get: { preferences.values.dev.watchCI }, set: { repos.setWatchCI($0) })) {
                    Text(L10n.string("Flash the notch when a running workflow finishes"))
                        .font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.secondary)
                }
                .toggleStyle(HubToggleStyle())
                Spacer()
                if repos.runningCount > 0 {
                    Text(L10n.format("%d running", repos.runningCount)).font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.accentLight)
                }
            }
            .frame(height: 26)
        }
    }
}

private struct RunRow: View {
    let run: WorkflowRun
    let open: (WorkflowRun) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: run.state.symbol)
                .foregroundStyle(run.state.color)
                .symbolEffect(.pulse, isActive: run.isRunning)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.title.isEmpty ? run.workflow : run.title).font(HubTheme.Font.bodyMedium).lineLimit(1)
                Text("\(run.repo.name) · \(run.workflow) · \(run.branch)")
                    .font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.tertiary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Group {
                if run.isRunning {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(BuildFormat.clock(context.date.timeIntervalSince(run.started)))
                    }
                } else {
                    Text(BuildFormat.clock(run.updated.timeIntervalSince(run.started)))
                }
            }
            .font(HubTheme.Font.body).monospacedDigit().foregroundStyle(HubTheme.Palette.secondary)
            Text(run.started.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                .font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.tertiary).lineLimit(1).frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .selectedRow(hovering)
        .contentShape(Rectangle())
        .onTapGesture { open(run) }
        .onHover { hovering = $0 }
        .help(L10n.string("Open on GitHub"))
    }
}

// MARK: - Cleanup

private struct CleanupPage: View {
    let cleanup: CleanupStore

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 2) {
                ForEach(cleanup.targets) { target in
                    row(target)
                }
            }
        }
    }

    private func row(_ target: CleanupTarget) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(target.title).font(HubTheme.Font.bodyMedium)
                Text(target.detail).font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.tertiary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Group {
                if cleanup.measuring.contains(target.id) || cleanup.cleaning == target.id {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(BuildFormat.bytes(cleanup.sizes[target.id] ?? 0))
                }
            }
            .font(HubTheme.Font.body).monospacedDigit().foregroundStyle(HubTheme.Palette.secondary)
            .frame(width: 70, alignment: .trailing)
            if cleanup.confirming == target.id {
                GhostPill(title: confirmTitle(target), symbol: "trash", tint: HubTheme.Palette.danger) { cleanup.clean(target) }
                Button { cleanup.confirming = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(HubIconButtonStyle(size: 22))
            } else {
                Button { cleanup.reveal(target) } label: { Image(systemName: "folder") }
                    .buttonStyle(HubIconButtonStyle(size: 22)).help(L10n.string("Show in Finder"))
                GhostPill(title: L10n.string("Clean"), symbol: "trash") { cleanup.confirming = target.id }
                    .disabled((cleanup.sizes[target.id] ?? 0) == 0 || cleanup.cleaning != nil)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
    }

    private func confirmTitle(_ target: CleanupTarget) -> String {
        switch target.action {
        case .trashContents: L10n.string("Move to Trash")
        case .deleteContents: L10n.string("Delete")
        case .deleteUnavailableSimulators: L10n.string("Delete unavailable")
        }
    }
}
