import AppKit
import SwiftUI

/// Settings, per the handoff: two cards. Left, the switches (the mock's five
/// first, then the rest of MyHub's options, scrolling). Right, the tabs in the
/// dock, the build tool, and what the privacy shield covers.
struct SettingsView: View {
    let model: HubModel
    let session: ScreenSession

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var notificationsRefused = false
    @State private var recordingShortcut = false
    @State private var recordingRuler = false

    private var prefs: Preferences.Values { model.preferences.values }

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    if model.preferences.isFileBroken {
                        Label(L10n.string("preferences.json could not be read — changes are not saved until it is fixed."),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(HubTheme.Font.meta)
                            .foregroundStyle(HubTheme.Palette.danger)
                            .padding(.vertical, 8)
                    }
                    row(L10n.string("Launch at login"), isOn: Binding(get: { launchAtLogin }, set: { launchAtLogin = LoginItem.set($0) }))
                    row(L10n.string("Open on hover"), isOn: Binding(get: { prefs.general.openOnHover }, set: { model.setOpenOnHover($0) }))
                    row(L10n.string("Switch tabs on hover"), isOn: Binding(get: { prefs.general.switchTabsOnHover }, set: { model.setSwitchTabsOnHover($0) }))
                    row(L10n.string("Haptic feedback"), isOn: Binding(get: { prefs.general.haptics }, set: { model.setHaptics($0) }))
                    row(L10n.string("Notify when build finishes"), isOn: Binding(get: { prefs.builds.notifyOnFinish }, set: { model.setNotifyOnBuild($0) }))
                    row(L10n.string("Build time today in menu bar"), isOn: Binding(get: { prefs.builds.menuBarTime }, set: { model.setMenuBarBuildTime($0) }))
                    SettingRow(title: L10n.string("Toggle panel")) {
                        ShortcutRecorder(shortcut: prefs.general.toggleShortcut, recording: $recordingShortcut, session: session, model: model) {
                            model.setToggleShortcut($0)
                        }
                    }
                    SettingRow(title: L10n.string("Measure screen")) {
                        ShortcutRecorder(shortcut: prefs.design.rulerShortcut, recording: $recordingRuler, session: session, model: model) {
                            model.setRulerShortcut($0)
                        }
                    }
                    SettingRow(title: L10n.string("Snippets")) { ShortcutBadge(text: Shortcut.snippets.display) }

                    divider(L10n.string("Stash"))
                    row(L10n.string("Collect new screenshots"), isOn: Binding(
                        get: { prefs.design.collectScreenshots }, set: { model.setCollectScreenshots($0) }))

                    divider(L10n.string("Clipboard"))
                    SettingRow(title: L10n.string("Paste with ⏎")) {
                        if Paster.isAllowed {
                            Text(L10n.string("On")).font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.tertiary)
                        } else {
                            GhostPill(title: L10n.string("Allow"), symbol: "hand.raised") { Paster.requestPermission() }
                                .help(L10n.string("Needs Accessibility permission to press ⌘V in the app underneath. Without it, ⏎ copies."))
                        }
                    }
                    row(L10n.string("Keep history (encrypted)"), isOn: Binding(get: { prefs.clipboard.persistHistory }, set: { model.clipboard.setPersistence($0) }))
                    row(L10n.string("Save copied images to Stash"), isOn: Binding(
                        get: { prefs.clipboard.saveImagesToStash },
                        set: { on in model.preferences.update { $0.clipboard.saveImagesToStash = on } }))

                    divider(L10n.string("AI usage"))
                    row(L10n.string("Usage in the menu bar"), isOn: Binding(get: { prefs.usage.menuBarMeter }, set: { model.setMenuBarMeter($0) }))
                    row(L10n.string("Notify at 80% and 95%"), isOn: Binding(
                        get: { prefs.usage.alerts },
                        set: { on in Task { notificationsRefused = !(await model.setUsageAlerts(on)) } }))
                    if notificationsRefused {
                        SettingRow(title: L10n.string("Notifications are off for MyHub")) {
                            GhostPill(title: L10n.string("Open settings"), symbol: "gear") { UsageNotifier.openSettings() }
                        }
                    }

                    divider(L10n.string("Agents"))
                    AgentSettings(agents: model.agents)

                    divider(L10n.string("Inbox"))
                    row(L10n.string("Unread count on the notch"), isOn: Binding(
                        get: { prefs.inbox.badge }, set: { model.inbox.setBadge($0) }))

                    if Features.microsoftCalendar {
                        divider(L10n.string("Calendar · Microsoft 365"))
                        MicrosoftSettings(microsoft: model.agenda.microsoft)
                    }

                    divider("Jira")
                    if model.jira.connection == .connected || model.jira.connection == .expired {
                        SettingRow(title: model.jira.settings.site) {
                            Text(model.jira.account?.name ?? model.jira.settings.email)
                                .font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.tertiary).lineLimit(1)
                        }
                        row(L10n.string("Notify on mentions"), isOn: Binding(
                            get: { prefs.jira.notifyMentions }, set: { model.jira.setNotifyMentions($0) }))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.string("Sprint board")).font(HubTheme.Font.body).foregroundStyle(HubTheme.Palette.primary)
                            WrapLayout(spacing: 6) {
                                Chip(title: L10n.string("Automatic"), isOn: prefs.jira.boardID == nil) { model.jira.setBoard(nil) }
                                ForEach(model.jira.boards, id: \.id) { board in
                                    Chip(title: model.jira.myBoardIDs.contains(board.id) ? "★ \(board.name)" : board.name,
                                         isOn: prefs.jira.boardID == board.id) { model.jira.setBoard(board.id) }
                                }
                            }
                        }
                        .padding(.vertical, 6)
                        .onAppear { model.jira.loadBoards() }
                        SettingRow(title: L10n.string("Connection")) {
                            GhostPill(title: L10n.string("Disconnect"), symbol: "xmark", tint: HubTheme.Palette.danger) { model.jira.disconnect() }
                        }
                    } else {
                        SettingRow(title: L10n.string("Not connected")) {
                            GhostPill(title: L10n.string("Connect"), symbol: "link") {
                                model.jira.setupVisible = true
                                session.select(.jira)
                            }
                        }
                    }

                    divider("Figma")
                    FigmaSettings(figma: model.figma, session: session)

                    divider(L10n.string("Displays"))
                    row(L10n.string("Show on every display"), isOn: Binding(get: { prefs.showOnAllDisplays }, set: { model.setShowOnAllDisplays($0) }))
                    row(L10n.string("Full-height notch without a notch"), isOn: Binding(get: { prefs.fullHeightDrawnNotch }, set: { model.setFullHeightDrawnNotch($0) }))
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 14)
            }
            .background(RoundedRectangle(cornerRadius: HubTheme.Radius.card, style: .continuous).fill(HubTheme.Palette.card))
            .frame(maxWidth: .infinity)

            rightCard.frame(maxWidth: .infinity)
        }
        .toggleStyle(HubToggleStyle())
        .onAppear { launchAtLogin = LoginItem.isEnabled }
    }

    private var rightCard: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                label(L10n.string("Position"))
                HubSegmented(
                    options: PanelPosition.allCases.map { ($0, $0.title) },
                    selection: Binding(get: { prefs.general.panelPosition }, set: { model.setPanelPosition($0) }),
                    container: HubTheme.Palette.selected,
                    active: HubTheme.Palette.dashed
                )
                label(L10n.string("Theme")).padding(.top, 4)
                WrapLayout(spacing: 6) {
                    ForEach(PanelTheme.allCases) { theme in
                        ThemeSwatch(theme: theme, isOn: prefs.general.theme == theme) { model.setTheme(theme) }
                    }
                }
                label(L10n.string("Panel size")).padding(.top, 4)
                HubSegmented(
                    options: PanelSize.allCases.map { ($0, $0.title) },
                    selection: Binding(get: { prefs.general.panelSize }, set: { model.setPanelSize($0) }),
                    container: HubTheme.Palette.selected,
                    active: HubTheme.Palette.dashed
                )
                label(L10n.string("Tabs in dock")).padding(.top, 4)
                WrapLayout(spacing: 6) {
                    ForEach(Section.tools) { section in
                        Chip(title: section.title, isOn: model.isVisible(section)) {
                            model.setVisible(section, !model.isVisible(section))
                        }
                    }
                }
                label(L10n.string("Build tool")).padding(.top, 4)
                HubSegmented(
                    options: [(Preferences.Builds.Tool.xcode, "Xcode"), (.android, "Android Studio"), (.both, L10n.string("Both"))],
                    selection: Binding(get: { prefs.builds.tool }, set: { model.setBuildTool($0) }),
                    container: HubTheme.Palette.selected,
                    active: HubTheme.Palette.dashed
                )
                label(L10n.string("Privacy shield")).padding(.top, 4)
                WrapLayout(spacing: 6) {
                    ForEach(ContentShield.eligible) { section in
                        Chip(title: section.title, isOn: model.shield.isShielded(section)) {
                            model.shield.setShielded(!model.shield.isShielded(section), for: section)
                        }
                    }
                }
                HStack(spacing: 6) {
                    GhostPill(title: L10n.string("Preferences file"), symbol: "doc.text") { model.preferences.revealInFinder() }
                    GhostPill(title: L10n.string("Quit"), symbol: "power") { NSApp.terminate(nil) }
                }
                .padding(.top, 4)
                Text("MyHub \(Bundle.main.appVersion)")
                    .font(HubTheme.Font.axis)
                    .foregroundStyle(HubTheme.Palette.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .background(RoundedRectangle(cornerRadius: HubTheme.Radius.card, style: .continuous).fill(HubTheme.Palette.card))
    }

    private func row(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title).font(HubTheme.Font.body).foregroundStyle(HubTheme.Palette.primary)
        }
        .frame(height: 37)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(HubTheme.Font.body).foregroundStyle(HubTheme.Palette.secondary)
    }

    private func divider(_ title: String) -> some View {
        Text(title)
            .textCase(.uppercase)
            .font(HubTheme.Font.header)
            .kerning(0.6)
            .foregroundStyle(HubTheme.Palette.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }
}

private struct SettingRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack {
            Text(title).font(HubTheme.Font.body).foregroundStyle(HubTheme.Palette.primary)
            Spacer(minLength: 6)
            control
        }
        .frame(height: 37)
    }
}

/// Microsoft 365 / Teams calendar: the app registration's ID, then sign in
/// or out. The ID is kept in the drafts until saved, like other form fields.
private struct MicrosoftSettings: View {
    let microsoft: MicrosoftCalendarStore
    @Environment(FormDrafts.self) private var drafts

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if microsoft.state == .notConfigured || drafts["ms.editing"] == "1" {
                Text(L10n.string("Paste the Application (client) ID of your app registration (Microsoft Entra → App registrations). See the README for the two-minute setup."))
                    .font(HubTheme.Font.meta)
                    .foregroundStyle(HubTheme.Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    PanelField(placeholder: "00000000-0000-0000-0000-000000000000", text: drafts.binding("ms.clientID")) { save() }
                    GhostPill(title: L10n.string("Save"), symbol: "checkmark") { save() }
                }
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status).font(HubTheme.Font.body).foregroundStyle(HubTheme.Palette.primary).lineLimit(1)
                        Text(L10n.format("App ID %@…", String(microsoft.clientID.prefix(8))))
                            .font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.tertiary)
                    }
                    Spacer(minLength: 6)
                    switch microsoft.state {
                    case .connected:
                        GhostPill(title: L10n.string("Disconnect"), symbol: "xmark", tint: HubTheme.Palette.danger) { microsoft.disconnect() }
                    case .signingIn:
                        GhostPill(title: L10n.string("Cancel"), symbol: "xmark") { microsoft.cancelSignIn() }
                    default:
                        GhostPill(title: L10n.string("Sign in"), symbol: "person.badge.key") { microsoft.connect() }
                    }
                }
                Button(L10n.string("Change App ID")) {
                    drafts.seed("ms.clientID", microsoft.clientID)
                    drafts["ms.editing"] = "1"
                }
                .buttonStyle(.plain)
                .font(HubTheme.Font.meta)
                .foregroundStyle(HubTheme.Palette.secondary)
            }
            if let problem = microsoft.problem {
                Text(problem).font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.danger).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }

    private var status: String {
        switch microsoft.state {
        case .connected: microsoft.account.isEmpty ? L10n.string("Connected") : microsoft.account
        case .signingIn: L10n.string("Finish signing in in your browser…")
        case .expired: L10n.string("Sign-in expired")
        case .disconnected, .notConfigured: L10n.string("Not signed in")
        }
    }

    private func save() {
        microsoft.setClientID(drafts["ms.clientID"])
        if microsoft.problem == nil { drafts.clear("ms.clientID", "ms.editing") }
    }
}

/// Coding agents: the Claude Code hook, the notch pill, the finish flash,
/// and the loopback port the hooks post to.
private struct AgentSettings: View {
    let agents: AgentStore
    @Environment(FormDrafts.self) private var drafts

    var body: some View {
        VStack(spacing: 0) {
            ForEach(AgentHookInstaller.Target.all) { target in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.name).font(HubTheme.Font.body).foregroundStyle(HubTheme.Palette.primary)
                        Text(agents.isConnected(target) ? L10n.format("Hook in ~/%@", target.settingsPath)
                             : (target.looksInstalled ? L10n.string("Not connected") : L10n.string("Not found on this Mac")))
                            .font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.tertiary)
                    }
                    Spacer(minLength: 6)
                    if agents.isConnected(target) {
                        GhostPill(title: L10n.string("Disconnect"), symbol: "xmark", tint: HubTheme.Palette.danger) { agents.disconnect(target) }
                    } else {
                        GhostPill(title: L10n.string("Connect"), symbol: "link") { agents.connect(target) }
                    }
                }
                .frame(height: 44)
            }
            Toggle(isOn: Binding(get: { agents.settings.approvals }, set: { agents.setApprovals($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("Approve Claude Code requests from the notch")).font(HubTheme.Font.body).foregroundStyle(HubTheme.Palette.primary)
                    Text(L10n.string("Allow or Deny without the terminal. Unanswered requests go back to Claude Code's own prompt."))
                        .font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 6)
            if agents.settings.approvals {
                Toggle(isOn: Binding(get: { agents.settings.openForApprovals }, set: { agents.setOpenForApprovals($0) })) {
                    Text(L10n.string("Open the panel when an agent asks")).font(HubTheme.Font.body).foregroundStyle(HubTheme.Palette.primary)
                }
                .frame(height: 37)
            }
            Toggle(isOn: Binding(get: { agents.settings.showInNotch }, set: { agents.setShowInNotch($0) })) {
                Text(L10n.string("Show working agents on the notch")).font(HubTheme.Font.body).foregroundStyle(HubTheme.Palette.primary)
            }
            .frame(height: 37)
            Toggle(isOn: Binding(get: { agents.settings.flashOnFinish }, set: { agents.setFlashOnFinish($0) })) {
                Text(L10n.string("Flash when an agent finishes")).font(HubTheme.Font.body).foregroundStyle(HubTheme.Palette.primary)
            }
            .frame(height: 37)
            HStack(spacing: 6) {
                Text(L10n.string("Port")).font(HubTheme.Font.body).foregroundStyle(HubTheme.Palette.primary)
                Spacer(minLength: 6)
                PanelField(placeholder: String(agents.settings.port), text: drafts.binding("agents.port")) { savePort() }
                    .frame(width: 80)
                if !drafts["agents.port"].isEmpty {
                    GhostPill(title: L10n.string("Save"), symbol: "checkmark") { savePort() }
                }
            }
            .frame(height: 37)
            if let problem = agents.problem {
                Text(problem).font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func savePort() {
        if let port = UInt16(drafts["agents.port"].trimmingCharacters(in: .whitespaces)) { agents.setPort(port) }
        drafts.clear("agents.port")
    }
}

/// A theme: a small circle of its gradient with its accent, and the name.
private struct ThemeSwatch: View {
    let theme: PanelTheme
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(theme.background(from: .topLeading))
                    .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
                    .overlay(alignment: .bottomTrailing) {
                        Circle().fill(theme.accent).frame(width: 7, height: 7)
                    }
                    .frame(width: 18, height: 18)
                Text(theme.title).font(HubTheme.Font.meta)
            }
            .foregroundStyle(isOn ? HubTheme.Palette.primary : HubTheme.Palette.iconInactive)
            .padding(.vertical, 4)
            .padding(.leading, 5)
            .padding(.trailing, 10)
            .background(Capsule().fill(isOn ? HubTheme.Palette.segmentActive : .clear))
            .overlay(Capsule().strokeBorder(isOn ? theme.accent.opacity(0.6) : HubTheme.Palette.segmentActive, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PressFade())
        .animation(HubTheme.Motion.quick, value: isOn)
    }
}

/// Dock-tab and cover chips: `#2A2A2E` with an accent check when on; a 1pt
/// outline and grey text when off.
private struct Chip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isOn {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(HubTheme.Palette.accentLight)
                }
                Text(title).font(HubTheme.Font.meta)
            }
            .foregroundStyle(isOn ? HubTheme.Palette.primary : HubTheme.Palette.iconInactive)
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .background(Capsule().fill(isOn ? HubTheme.Palette.segmentActive : .clear))
            .overlay(Capsule().strokeBorder(isOn ? .clear : HubTheme.Palette.segmentActive, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PressFade())
        .animation(HubTheme.Motion.quick, value: isOn)
    }
}

/// The ⌥ Space badge; click, then type a new combination (Esc cancels).
private struct ShortcutRecorder: View {
    let shortcut: Shortcut
    @Binding var recording: Bool
    let session: ScreenSession
    let model: HubModel
    let apply: (Shortcut) -> Void

    var body: some View {
        Button {
            recording.toggle()
            model.formActive = recording
            model.onShortcutRecording?(recording)
            if recording { session.wantsKeyboard = true }
        } label: {
            ShortcutBadge(text: recording ? L10n.string("Type shortcut…") : shortcut.display, highlighted: recording)
        }
        .buttonStyle(.plain)
        .background {
            if recording {
                KeyCapture { event in
                    if event.keyCode == 53 { finish(nil); return }  // Esc
                    if let new = Shortcut(event: event) { finish(new) }
                }
            }
        }
        .onChange(of: session.wantsKeyboard) { _, wants in if !wants, recording { finish(nil) } }
    }

    private func finish(_ new: Shortcut?) {
        recording = false
        model.formActive = false
        if let new { apply(new) }
        model.onShortcutRecording?(false)
    }
}

/// A view that takes first responder and reports key presses — including
/// ones with ⌘, which arrive as key equivalents.
private struct KeyCapture: NSViewRepresentable {
    let onKey: (NSEvent) -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onKey = onKey
        Task { @MainActor in view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: CaptureView, context: Context) {
        view.onKey = onKey
    }

    final class CaptureView: NSView {
        var onKey: (NSEvent) -> Void = { _ in }
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { onKey(event) }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return false }
            onKey(event)
            return true
        }
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(widest, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + spacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// Figma: a personal access token, then the files to watch (pasted links)
/// and what to be told about.
private struct FigmaSettings: View {
    let figma: FigmaStore
    let session: ScreenSession
    @Environment(FormDrafts.self) private var drafts
    @State private var addProblem: String?
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if figma.connection == .disconnected {
                connectForm
            } else {
                connected
            }
            if let problem = figma.problem ?? addProblem {
                Text(problem).font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.warn)
            }
        }
        .padding(.vertical, 6)
    }

    private var connectForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.format("Create a personal access token in Figma (Settings → Security) with the scopes %@, and %@ to reply from the notch.",
                             FigmaClient.readScopes.joined(separator: ", "), FigmaClient.writeScope))
                .font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                PanelField(placeholder: L10n.string("Personal access token"), text: drafts.binding("figma.token"), secure: true) { connect() }
                    .simultaneousGesture(TapGesture().onEnded { session.wantsKeyboard = true })
                if figma.isConnecting { ProgressView().controlSize(.mini) }
                GhostPill(title: L10n.string("Connect"), symbol: "link") { connect() }
            }
        }
    }

    private var connected: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(figma.me?.handle ?? L10n.string("Connected"))
                    .font(HubTheme.Font.body).foregroundStyle(HubTheme.Palette.primary)
                if figma.connection == .expired {
                    Text(L10n.string("Token expired")).font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.warn)
                }
                Spacer(minLength: 6)
                GhostPill(title: L10n.string("Disconnect"), symbol: "xmark", tint: HubTheme.Palette.danger) { figma.disconnect() }
            }
            .frame(height: 37)
            ForEach(figma.files, id: \.key) { file in
                HStack(spacing: 8) {
                    Image(systemName: "doc.richtext").foregroundStyle(HubTheme.Palette.tertiary)
                    Text(file.name).font(HubTheme.Font.body).foregroundStyle(HubTheme.Palette.primary).lineLimit(1)
                    Spacer(minLength: 6)
                    Button { figma.removeFile(file.key) } label: { Image(systemName: "xmark") }
                        .buttonStyle(HubIconButtonStyle(size: 20))
                        .help(L10n.string("Stop watching"))
                }
                .frame(height: 28)
            }
            if figma.files.count < FigmaStore.maxFiles {
                HStack(spacing: 6) {
                    PanelField(placeholder: L10n.string("Paste a Figma file link to watch"), text: drafts.binding("figma.link")) { add() }
                        .simultaneousGesture(TapGesture().onEnded { session.wantsKeyboard = true })
                    if adding { ProgressView().controlSize(.mini) }
                    GhostPill(title: L10n.string("Watch"), symbol: "plus") { add() }
                }
            }
            Toggle(isOn: Binding(get: { figma.settings.notifyComments }, set: { figma.setNotifyComments($0) })) {
                Text(L10n.string("Flash for mentions and replies")).font(HubTheme.Font.body).foregroundStyle(HubTheme.Palette.primary)
            }
            .frame(height: 37)
            Toggle(isOn: Binding(get: { figma.settings.notifyVersions }, set: { figma.setNotifyVersions($0) })) {
                Text(L10n.string("New named versions")).font(HubTheme.Font.body).foregroundStyle(HubTheme.Palette.primary)
            }
            .frame(height: 37)
        }
    }

    private func connect() {
        Task {
            if await figma.connect(token: drafts["figma.token"]) { drafts.clear("figma.token") }
        }
    }

    private func add() {
        guard !adding else { return }
        adding = true
        Task {
            addProblem = await figma.addFile(drafts["figma.link"])
            adding = false
            if addProblem == nil { drafts.clear("figma.link") }
        }
    }
}
