import SwiftUI

/// The Jira tab, per the `design_handoff_jira_tab` handoff: a connect card,
/// a spinner while signing in, an expired-session card, and — connected — the
/// Assigned / Mentions / Sprint views under a segmented header.
struct JiraView: View {
    let jira: JiraStore
    let shield: ContentShield
    let session: ScreenSession
    let onFormActive: (Bool) -> Void

    var body: some View {
        Group {
            switch jira.connection {
            case .disconnected:
                if jira.setupVisible { JiraConnectForm(jira: jira, session: session) } else { connectCard }
            case .connecting: connectingCard
            case .expired: expiredCard
            case .connected: connected
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { onFormActive(true) }
        .onDisappear { onFormActive(false) }
        .onKeyPress(.escape) {
            session.wantsKeyboard = false
            return .handled
        }
    }

    // MARK: - State cards

    private var connectCard: some View {
        StateCard(icon: "rectangle.split.3x1", tint: HubTheme.Palette.blue,
                  title: L10n.string("Connect Jira to see your work here"),
                  subtitle: L10n.string("Assigned tickets, mentions in comments and your active sprint")) {
            Button(L10n.string("Connect Jira")) { jira.setupVisible = true }
                .buttonStyle(PrimaryCapsule())
        }
    }

    private var connectingCard: some View {
        StateCard(spinner: true, tint: HubTheme.Palette.blue,
                  title: L10n.string("Checking your Jira sign-in"),
                  subtitle: "\(jira.settings.site) · " + L10n.string("Waiting for Jira")) {
            Button(L10n.string("Cancel")) { jira.cancelConnecting() }
                .buttonStyle(SecondaryCapsule())
        }
    }

    private var expiredCard: some View {
        let synced = jira.lastSynced.map { L10n.format("Last synced %@", $0.formatted(.relative(presentation: .named))) }
        return StateCard(icon: "bolt.horizontal.circle", tint: HubTheme.Palette.danger,
                         title: L10n.string("Your Jira session expired"),
                         subtitle: [synced, jira.settings.site].compactMap { $0 }.joined(separator: " · ")) {
            HStack(spacing: 8) {
                Button(L10n.string("Reconnect")) { jira.reconnect() }.buttonStyle(PrimaryCapsule())
                Button(L10n.string("Disconnect")) { jira.disconnect() }.buttonStyle(SecondaryCapsule())
            }
        }
    }

    // MARK: - Connected

    private var connected: some View {
        VStack(spacing: 10) {
            HStack {
                HubSegmented(
                    options: JiraStore.View.allCases.map { ($0, $0.title) },
                    selection: Binding(get: { jira.view }, set: { jira.view = $0 }),
                    badges: [.assigned: jira.hasLoaded ? "\(jira.assigned.count)" : "",
                             .mentions: jira.hasLoaded ? "\(jira.unreadMentions.count)" : ""]
                )
                Spacer(minLength: 6)
                if jira.isRefreshing { ProgressView().controlSize(.mini) }
                if let problem = jira.problem {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(HubTheme.Palette.warn).help(problem)
                }
                GhostPill(title: L10n.string("Open in Jira"), symbol: "arrow.up.right.square") { jira.openCurrentView() }
            }
            .frame(height: 26)

            Group {
                switch jira.view {
                case .assigned:
                    if jira.hasLoaded && jira.assigned.isEmpty {
                        JiraEmpty(icon: "checkmark.circle", title: L10n.string("Nothing assigned to you"),
                                  subtitle: L10n.string("New tickets show up here as soon as they are assigned"))
                    } else {
                        AssignedList(jira: jira, shield: shield)
                    }
                case .mentions:
                    if jira.hasLoaded && jira.mentions.isEmpty {
                        JiraEmpty(icon: "bubble.left.and.bubble.right", title: L10n.string("No new mentions"),
                                  subtitle: L10n.string("Comments that tag you will appear here"))
                    } else {
                        MentionList(jira: jira, shield: shield, session: session)
                    }
                case .sprint:
                    if let sprint = jira.sprint {
                        SprintBoard(sprint: sprint)
                    } else if jira.hasLoaded {
                        JiraEmpty(icon: "calendar.badge.exclamationmark", title: L10n.string("No active sprint"),
                                  subtitle: L10n.string("Your board has no sprint running right now"))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

// MARK: - Pieces

/// Centered card for the connection states: 200 tall, radius 22.
private struct StateCard<Buttons: View>: View {
    var icon: String?
    var spinner = false
    let tint: Color
    let title: String
    let subtitle: String
    @ViewBuilder let buttons: Buttons

    init(icon: String? = nil, spinner: Bool = false, tint: Color, title: String, subtitle: String, @ViewBuilder buttons: () -> Buttons) {
        self.icon = icon
        self.spinner = spinner
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.buttons = buttons()
    }

    var body: some View {
        VStack(spacing: 12) {
            if spinner {
                Spinner(tint: tint).frame(width: 30, height: 30)
            } else if let icon {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .frame(width: 52, height: 52)
                    .overlay(Image(systemName: icon).font(.system(size: 24)).foregroundStyle(tint))
            }
            Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(HubTheme.Palette.strong)
            Text(subtitle).font(HubTheme.Font.body).foregroundStyle(Color(hex: 0x7D7E83))
                .multilineTextAlignment(.center).frame(maxWidth: 320)
            buttons
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: HubTheme.Radius.dropZone, style: .continuous).fill(HubTheme.Palette.card))
    }
}

/// 2.5pt ring with a coloured top segment, one turn every 0.8 s.
private struct Spinner: View {
    let tint: Color
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle().stroke(HubTheme.Palette.segmentActive, lineWidth: 2.5)
            Circle().trim(from: 0, to: 0.25).stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(turning ? 360 : 0))
                .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: turning)
        }
        .onAppear { turning = true }
    }
}

/// Padding 7×16, `#ECECEE` on `#111`, 12pt semibold.
private struct PrimaryCapsule: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HubTheme.Font.bodyStrong)
            .foregroundStyle(HubTheme.Palette.onLight)
            .padding(.vertical, 7).padding(.horizontal, 16)
            .background(Capsule().fill(HubTheme.Palette.primary))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Padding 7×14, `#1D1D20`, `#C9CACF` 12pt.
private struct SecondaryCapsule: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HubTheme.Font.body)
            .foregroundStyle(HubTheme.Palette.soft)
            .padding(.vertical, 7).padding(.horizontal, 14)
            .background(Capsule().fill(HubTheme.Palette.selected))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct JiraEmpty: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 24)).foregroundStyle(HubTheme.Palette.success)
            Text(title).font(.system(size: 14, weight: .medium))
            Text(subtitle).font(HubTheme.Font.body).foregroundStyle(Color(hex: 0x7D7E83))
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: HubTheme.Radius.card, style: .continuous).fill(HubTheme.Palette.card))
    }
}

/// Site, email and API token. The token goes to the Keychain only after Jira
/// has accepted it.
private struct JiraConnectForm: View {
    let jira: JiraStore
    let session: ScreenSession
    @Environment(FormDrafts.self) private var drafts

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.string("Connect Jira Cloud")).font(HubTheme.Font.title)
                Spacer()
                GhostPill(title: L10n.string("Create API token"), symbol: "key") { jira.openTokenPage() }
            }
            PanelField(placeholder: L10n.string("Site, e.g. acme.atlassian.net"), text: drafts.binding("jira.site"))
            PanelField(placeholder: L10n.string("Email you sign in with"), text: drafts.binding("jira.email"))
            PanelField(placeholder: L10n.string("API token"), text: drafts.binding("jira.token"), secure: true) { connect() }
            HStack(spacing: 8) {
                if let problem = jira.problem {
                    Text(problem).font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.danger).lineLimit(2)
                } else {
                    Text(L10n.string("The token is stored in your Keychain and sent only to your Jira site."))
                        .font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.tertiary).lineLimit(2)
                }
                Spacer(minLength: 6)
                Button(L10n.string("Cancel")) {
                    drafts.clear("jira.token")
                    jira.setupVisible = false
                }.buttonStyle(SecondaryCapsule())
                Button(L10n.string("Connect")) { connect() }.buttonStyle(PrimaryCapsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .hubCard()
        .onAppear {
            drafts.seed("jira.site", jira.settings.site)
            drafts.seed("jira.email", jira.settings.email)
        }
    }

    private func connect() {
        jira.connect(site: drafts["jira.site"], email: drafts["jira.email"], token: drafts["jira.token"])
        // The token leaves the drafts at once; site and email stay so a typo
        // is a quick fix.
        drafts.clear("jira.token")
        session.wantsKeyboard = false
    }
}

// MARK: - Assigned

private struct AssignedList: View {
    let jira: JiraStore
    let shield: ContentShield
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(Array(jira.assigned.enumerated()), id: \.element.id) { index, issue in
                        IssueRow(issue: issue, selected: index == jira.selectedIssue,
                                 hidden: shield.masks(issue.key, in: .jira))
                            .id(issue.id)
                            .onTapGesture {
                                jira.selectedIssue = index
                                jira.open(issue)
                            }
                    }
                }
            }
            .onChange(of: jira.selectedIssue) { _, index in
                guard jira.assigned.indices.contains(index) else { return }
                withAnimation(HubTheme.Motion.quick) { proxy.scrollTo(jira.assigned[index].id) }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.return) {
            guard let issue = current else { return .ignored }
            jira.open(issue)
            return .handled
        }
        .onKeyPress(phases: .down) { press in
            guard press.modifiers.contains(.command), press.characters.lowercased() == "c", let issue = current else { return .ignored }
            jira.copyKey(issue)
            return .handled
        }
    }

    private var current: JiraIssue? {
        jira.assigned.indices.contains(jira.selectedIssue) ? jira.assigned[jira.selectedIssue] : nil
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !jira.assigned.isEmpty else { return .ignored }
        jira.selectedIssue = min(max(0, jira.selectedIssue + delta), jira.assigned.count - 1)
        return .handled
    }
}

private struct IssueRow: View {
    let issue: JiraIssue
    let selected: Bool
    let hidden: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: issue.priority.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(issue.priority.color)
                .frame(width: 16)
            Text(issue.key)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(HubTheme.Palette.secondary)
                .frame(width: 62, alignment: .leading)
                .lineLimit(1)
            ShieldedText(text: issue.summary, hidden: hidden)
            StatusChip(status: issue.status)
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .selectedRow(selected || hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(L10n.string("⏎ opens in Jira · ⌘C copies the key"))
    }
}

private struct StatusChip: View {
    let status: JiraStatus

    var body: some View {
        Text(status.title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(status.foreground)
            .padding(.vertical, 3).padding(.horizontal, 8)
            .background(Capsule().fill(status.background))
            .fixedSize()
    }
}

extension JiraPriority {
    var symbol: String {
        switch self {
        case .high: "chevron.up.2"
        case .medium: "equal"
        case .low: "chevron.down"
        }
    }

    var color: Color {
        switch self {
        case .high: HubTheme.Palette.danger
        case .medium: HubTheme.Palette.amber
        case .low: HubTheme.Palette.blue
        }
    }
}

extension JiraStatus {
    var dot: Color {
        switch self {
        case .todo: HubTheme.Palette.iconInactive
        case .inProgress: HubTheme.Palette.amber
        case .inReview: HubTheme.Palette.blue
        case .done: HubTheme.Palette.success
        }
    }

    var background: Color {
        self == .todo ? HubTheme.Palette.segmentActive : dot.opacity(0.16)
    }

    var foreground: Color {
        switch self {
        case .todo: HubTheme.Palette.soft
        case .inProgress: HubTheme.Palette.warn
        case .inReview: Color(hex: 0x86BCF5)
        case .done: Color(hex: 0x77D495)
        }
    }
}

// MARK: - Mentions

private struct MentionList: View {
    let jira: JiraStore
    let shield: ContentShield
    let session: ScreenSession

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 6) {
                ForEach(jira.mentions) { mention in
                    MentionCard(mention: mention, unread: !jira.isRead(mention), hidden: shield.masks(mention.id, in: .jira),
                                jira: jira, session: session)
                }
            }
        }
    }
}

private struct MentionCard: View {
    let mention: JiraMention
    let unread: Bool
    let hidden: Bool
    let jira: JiraStore
    let session: ScreenSession
    @Environment(FormDrafts.self) private var drafts
    private var replyKey: String { "jira.reply.\(mention.id)" }
    private var replying: Bool { drafts["\(replyKey).open"] == "1" }
    @State private var sending = false
    @State private var sent = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Self.color(for: mention.authorID))
                .frame(width: 26, height: 26)
                .overlay(Text(mention.initials).font(.system(size: 11, weight: .bold)).foregroundStyle(HubTheme.Palette.onLight))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    (Text(mention.author).fontWeight(.semibold).foregroundColor(HubTheme.Palette.primary)
                        + Text(" " + L10n.string("on") + " ")
                        + Text(mention.issueKey).font(.system(size: 11, design: .monospaced))
                        + Text(" · \(mention.issueSummary)"))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(mention.created.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
                        .fixedSize()
                }
                .font(HubTheme.Font.meta)
                .foregroundStyle(HubTheme.Palette.secondary)
                if hidden {
                    ShieldHatch().frame(height: 9).padding(.vertical, 3)
                } else {
                    Text(mention.body).font(HubTheme.Font.body).foregroundStyle(HubTheme.Palette.soft).lineLimit(2)
                }
                if replying {
                    HStack(spacing: 6) {
                        PanelField(placeholder: L10n.format("Reply to %@", mention.author), text: drafts.binding(replyKey)) { send() }
                        if sending { ProgressView().controlSize(.mini) }
                        GhostPill(title: L10n.string("Send"), symbol: "paperplane") { send() }
                    }
                    .padding(.top, 4)
                }
            }
            Button(sent ? L10n.string("Sent") : L10n.string("Reply")) {
                drafts.flag("\(replyKey).open").wrappedValue = !replying
                if replying { session.wantsKeyboard = true }
            }
            .buttonStyle(.plain)
            .font(HubTheme.Font.meta)
            .foregroundStyle(sent ? HubTheme.Palette.success : HubTheme.Palette.soft)
            .padding(.vertical, 4).padding(.horizontal, 9)
            .background(Capsule().fill(HubTheme.Palette.selected))
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: HubTheme.Radius.eventCard, style: .continuous)
            .fill(unread ? HubTheme.Palette.selected : HubTheme.Palette.card))
        .contentShape(Rectangle())
        .onTapGesture { if !replying { jira.open(mention) } }
    }

    private func send() {
        guard !sending else { return }
        sending = true
        Task {
            let ok = await jira.reply(to: mention, text: drafts[replyKey])
            sending = false
            if ok {
                drafts.clear(replyKey, "\(replyKey).open")
                sent = true
            }
        }
    }

    /// A stable colour per person, from the design's palette.
    static func color(for id: String) -> Color {
        let palette = [HubTheme.Palette.accent, HubTheme.Palette.blue, HubTheme.Palette.success, HubTheme.Palette.danger, Color(hex: 0xC59CF2)]
        let sum = id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[abs(sum) % palette.count]
    }
}

// MARK: - Sprint

private struct SprintBoard: View {
    let sprint: JiraSprint

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sprint.name).font(HubTheme.Font.buildTarget).lineLimit(1)
                    Text(dates).font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.secondary).lineLimit(1)
                }
                VStack(alignment: .trailing, spacing: 5) {
                    GeometryReader { proxy in
                        HStack(spacing: 0) {
                            ForEach([JiraStatus.done, .inReview, .inProgress], id: \.self) { status in
                                Rectangle().fill(status.dot)
                                    .frame(width: proxy.size.width * share(status))
                            }
                            Spacer(minLength: 0)
                        }
                        .background(HubTheme.Palette.track)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .frame(height: 5)
                    Text(L10n.format("%d of %d done", sprint.counts[.done] ?? 0, sprint.total))
                        .font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.tertiary)
                }
            }
            .padding(.vertical, 10).padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: HubTheme.Radius.eventCard, style: .continuous).fill(HubTheme.Palette.card))

            HStack(alignment: .top, spacing: 6) {
                ForEach(JiraStatus.allCases, id: \.self) { status in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Circle().fill(status.dot).frame(width: 6, height: 6)
                            Text(status.title).lineLimit(1)
                            Spacer(minLength: 2)
                            Text("\(sprint.counts[status] ?? 0)")
                        }
                        .font(HubTheme.Font.meta)
                        .foregroundStyle(HubTheme.Palette.secondary)
                        ForEach(sprint.mine[status] ?? [], id: \.self) { key in
                            Text(key)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(HubTheme.Palette.soft)
                                .padding(.vertical, 5).padding(.horizontal, 7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 8).fill(HubTheme.Palette.selected))
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: HubTheme.Radius.eventCard, style: .continuous).fill(HubTheme.Palette.card))
                }
            }
        }
    }

    private func share(_ status: JiraStatus) -> CGFloat {
        sprint.total > 0 ? CGFloat(sprint.counts[status] ?? 0) / CGFloat(sprint.total) : 0
    }

    private var dates: String {
        var parts: [String] = []
        if let start = sprint.start, let end = sprint.end {
            parts.append("\(start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day()))")
        }
        if let left = sprint.daysLeft(now: Date()) {
            parts.append(left == 1 ? L10n.string("1 day left") : L10n.format("%d days left", left))
        }
        return parts.joined(separator: " · ")
    }
}
