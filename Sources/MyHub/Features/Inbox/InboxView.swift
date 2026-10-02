import SwiftUI

/// The Inbox tab: a filter (All / GitHub / Jira) with counts, then the
/// items in three sections — needs your review, reviews on your pull
/// requests, mentions — newest first. Unread items carry a dot on their
/// icon; opening one marks it read.
struct InboxView: View {
    let inbox: InboxStore
    let shield: ContentShield
    let session: ScreenSession
    let goTo: (Section) -> Void

    var body: some View {
        VStack(spacing: 8) {
            header
            Group {
                if !inbox.hasSources {
                    setupCard
                } else if inbox.hasLoaded && inbox.visible.isEmpty {
                    caughtUp
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(InboxItem.Group.allCases, id: \.self) { group in
                                let items = inbox.visible.filter { $0.group == group }
                                if !items.isEmpty {
                                    SectionHeader(group: group, count: items.count)
                                    ForEach(items) { item in
                                        InboxRow(item: item, read: inbox.isRead(item),
                                                 hidden: shield.masks(item.id, in: .inbox),
                                                 figma: item.source == .figma ? inbox.figma : nil, session: session) { inbox.open(item) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            HubSegmented(
                options: inbox.filters.map { ($0, $0.title) },
                selection: Binding(get: { inbox.filter }, set: { inbox.filter = $0 }),
                badges: Dictionary(uniqueKeysWithValues: inbox.filters.map { filter in
                    (filter, inbox.hasLoaded ? "\(count(filter))" : "")
                })
            )
            Spacer(minLength: 6)
            if let problem = inbox.problem {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(HubTheme.Palette.warn).help(problem)
            }
            if let updated = inbox.lastUpdated {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(L10n.format("Updated %@", Self.ago(updated, now: context.date)))
                        .font(HubTheme.Font.meta)
                        .foregroundStyle(HubTheme.Palette.tertiary)
                }
            }
            Button { inbox.refresh() } label: {
                Group {
                    if inbox.isRefreshing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                    }
                }
                .foregroundStyle(HubTheme.Palette.soft)
                .frame(width: 30, height: 30)
                .background(Circle().fill(HubTheme.Palette.selected))
                .contentShape(Circle())
            }
            .buttonStyle(PressFade())
            .help(L10n.string("Refresh"))
            .contextMenu {
                Button(L10n.string("Mark all read")) { inbox.markAllRead() }
            }
        }
        .frame(height: 30)
    }

    private func count(_ filter: InboxStore.Filter) -> Int {
        switch filter {
        case .all: inbox.all.count
        case .github: inbox.all.filter { $0.source == .github }.count
        case .jira: inbox.all.filter { $0.source == .jira }.count
        case .figma: inbox.all.filter { $0.source == .figma }.count
        }
    }

    /// "2m ago", "just now".
    static func ago(_ date: Date, now: Date) -> String {
        now.timeIntervalSince(date) < 60 ? L10n.string("just now")
            : L10n.format("%@ ago", InboxRowTime.short(date, now: now))
    }

    private var setupCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell.badge").font(.system(size: 24)).foregroundStyle(HubTheme.Palette.accentLight)
            Text(L10n.string("Reviews and mentions, in one place")).font(.system(size: 14, weight: .medium))
            Text(L10n.string("Add a GitHub token (Dev → Git) for review requests and comments on your pull requests, connect Jira for mentions, or Figma (Settings) for comments on your files."))
                .font(HubTheme.Font.body).foregroundStyle(Color(hex: 0x7D7E83))
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            HStack(spacing: 8) {
                GhostPill(title: L10n.string("GitHub token"), symbol: "key") { goTo(.dev) }
                GhostPill(title: L10n.string("Connect Jira"), symbol: "rectangle.split.3x1") { goTo(.jira) }
                GhostPill(title: L10n.string("Connect Figma"), symbol: "pencil.and.outline") { goTo(.settings) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: HubTheme.Radius.card, style: .continuous).fill(HubTheme.Palette.card))
    }

    private var caughtUp: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle").font(.system(size: 24)).foregroundStyle(HubTheme.Palette.success)
            Text(L10n.string("You're all caught up")).font(.system(size: 14, weight: .medium))
            Text(L10n.string("Review requests, reviews and mentions from the last 7 days appear here"))
                .font(HubTheme.Font.body).foregroundStyle(Color(hex: 0x7D7E83))
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: HubTheme.Radius.card, style: .continuous).fill(HubTheme.Palette.card))
    }
}

extension InboxItem.Group {
    var color: Color {
        switch self {
        case .needsReview: Color(hex: 0xB79CF2)
        case .reviewsOnYours: HubTheme.Palette.amber
        case .mentions: HubTheme.Palette.blue
        case .design: Color(hex: 0xC59CF2)
        }
    }
}

private struct SectionHeader: View {
    let group: InboxItem.Group
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(group.color).frame(width: 6, height: 6)
            Text(group.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(HubTheme.Palette.secondary)
            Text("\(count)").font(.system(size: 12)).foregroundStyle(HubTheme.Palette.tertiary).monospacedDigit()
        }
        .padding(.leading, 10)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }
}

private struct InboxRow: View {
    let item: InboxItem
    let read: Bool
    let hidden: Bool
    /// Set for Figma items: reply, react and copy link act through it.
    var figma: FigmaStore?
    var session: ScreenSession?
    let open: () -> Void
    @State private var hovering = false
    @Environment(FormDrafts.self) private var drafts
    @State private var sending = false
    @State private var done: String?

    private var replyKey: String { "figma.reply.\(item.id)" }
    private var replying: Bool { drafts.flag("\(replyKey).open").wrappedValue }

    private var title: TaggedTitle { TaggedTitle(item.title) }

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    if !hidden, let tag = title.tag { TagChip(tag: tag) }
                    ShieldedText(text: hidden ? item.title : title.text, hidden: hidden,
                                 font: .system(size: 13, weight: read ? .regular : .semibold),
                                 color: read ? HubTheme.Palette.soft : HubTheme.Palette.primary)
                }
                HStack(spacing: 6) {
                    Text(item.shortReference)
                    if let who = actorLine {
                        Text("·").foregroundStyle(HubTheme.Palette.tertiary)
                        Text(who)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(HubTheme.Palette.tertiary)
                .lineLimit(1)
                if !item.snippet.isEmpty, !hidden {
                    Text(item.snippet)
                        .font(.system(size: 12))
                        .foregroundStyle(read ? HubTheme.Palette.tertiary : HubTheme.Palette.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if figma != nil, hovering || replying || done != nil, !hidden {
                figmaActions
            }
            Text(Self.short(item.date))
                .font(.system(size: 12))
                .foregroundStyle(HubTheme.Palette.tertiary)
                .monospacedDigit()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if replying, let figma {
                HStack(spacing: 6) {
                    PanelField(placeholder: L10n.format("Reply to %@", item.actor), text: drafts.binding(replyKey)) { send(figma) }
                    if sending { ProgressView().controlSize(.mini) }
                    GhostPill(title: L10n.string("Send"), symbol: "paperplane") { send(figma) }
                }
                .padding(.leading, 56).padding(.trailing, 10).padding(.bottom, 8)
            }
        }
        .selectedRow(hovering)
        .contentShape(Rectangle())
        .onTapGesture { if !replying { open() } }
        .onHover { hovering = $0 }
        .help(item.source == .figma ? L10n.string("Open in Figma") : L10n.string("Open in the browser"))
    }

    /// 👍, Reply (comments only) and Copy link.
    @ViewBuilder
    private var figmaActions: some View {
        if let done {
            Text(done).font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.success)
        } else if let figma {
            HStack(spacing: 4) {
                if item.figma?.commentID != nil {
                    Button { react(figma) } label: { Text("👍").font(.system(size: 11)) }
                        .buttonStyle(HubIconButtonStyle(size: 22, filled: true))
                        .help(L10n.string("React with 👍"))
                    Button {
                        drafts.flag("\(replyKey).open").wrappedValue = !replying
                        if replying { session?.wantsKeyboard = true }
                    } label: { Image(systemName: "arrowshape.turn.up.left") }
                        .buttonStyle(HubIconButtonStyle(size: 22, filled: true))
                        .help(L10n.string("Reply"))
                }
                Button {
                    figma.copyLink(item)
                    flash(L10n.string("Copied"))
                } label: { Image(systemName: "link") }
                    .buttonStyle(HubIconButtonStyle(size: 22, filled: true))
                    .help(L10n.string("Copy link"))
            }
        }
    }

    private func send(_ figma: FigmaStore) {
        guard !sending else { return }
        sending = true
        Task {
            let ok = await figma.reply(to: item, text: drafts[replyKey])
            sending = false
            if ok {
                drafts.clear(replyKey, "\(replyKey).open")
                flash(L10n.string("Sent"))
            }
        }
    }

    private func react(_ figma: FigmaStore) {
        Task { if await figma.react(to: item) { flash("👍") } }
    }

    private func flash(_ text: String) {
        done = text
        Task {
            try? await Task.sleep(for: .seconds(2))
            done = nil
        }
    }

    /// The round icon, with the unread dot on its shoulder.
    private var icon: some View {
        Circle()
            .fill(HubTheme.Palette.selected)
            .frame(width: 34, height: 34)
            .overlay(Image(systemName: symbol.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(symbol.color))
            .overlay(alignment: .topTrailing) {
                if !read {
                    Circle()
                        .fill(HubTheme.Palette.blue)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Color.black, lineWidth: 2))
                        .offset(x: 1, y: -1)
                }
            }
    }

    private var symbol: (name: String, color: Color) {
        switch item.kind {
        case .reviewRequested: ("arrow.triangle.merge", InboxItem.Group.needsReview.color)
        case .approved: ("checkmark", HubTheme.Palette.success)
        case .changesRequested: ("exclamationmark", HubTheme.Palette.danger)
        case .reviewed, .commented: ("text.bubble", item.source == .figma ? InboxItem.Group.design.color : HubTheme.Palette.amber)
        case .mentioned: item.source == .jira ? ("rectangle.split.3x1", HubTheme.Palette.blue) : ("at", HubTheme.Palette.blue)
        case .replied: ("arrowshape.turn.up.left", InboxItem.Group.design.color)
        case .newVersion: ("clock.arrow.circlepath", InboxItem.Group.design.color)
        }
    }

    /// Who, and for reviews what they did: "ana approved".
    private var actorLine: String? {
        guard !item.actor.isEmpty else { return nil }
        switch item.kind {
        case .approved: return L10n.format("%@ approved", item.actor)
        case .changesRequested: return L10n.format("%@ requested changes", item.actor)
        case .reviewed: return L10n.format("%@ reviewed", item.actor)
        case .commented: return L10n.format("%@ commented", item.actor)
        case .replied: return L10n.format("%@ replied", item.actor)
        case .newVersion: return L10n.format("%@ saved a version", item.actor)
        case .reviewRequested, .mentioned: return item.actor
        }
    }

    static func short(_ date: Date, now: Date = Date()) -> String { InboxRowTime.short(date, now: now) }
}

enum InboxRowTime {
    /// "57m", "14h", "3d".
    static func short(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return L10n.string("now")
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86400))d"
        }
    }
}

/// "feat · stash" in the change type's colour, or a ticket key in
/// blue monospace.
private struct TagChip: View {
    let tag: TaggedTitle.Tag

    var body: some View {
        switch tag {
        case .change(let type, let scope):
            let color = Self.color(type)
            Text(scope.map { "\(type) · \($0)" } ?? type)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color)
                .lineLimit(1)
                .padding(.vertical, 2).padding(.horizontal, 7)
                .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.14)))
                .fixedSize()
        case .ticket(let key):
            Text(key)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(hex: 0x86BCF5))
                .padding(.vertical, 2).padding(.horizontal, 7)
                .background(RoundedRectangle(cornerRadius: 6).fill(HubTheme.Palette.blue.opacity(0.16)))
                .fixedSize()
        }
    }

    static func color(_ type: String) -> Color {
        switch type {
        case "feat": HubTheme.Palette.success
        case "fix", "revert": HubTheme.Palette.danger
        case "perf", "refactor": Color(hex: 0xB79CF2)
        case "docs": HubTheme.Palette.blue
        default: HubTheme.Palette.muted
        }
    }
}

/// The closed notch with unread items: a small, light-grey count beside the
/// camera. No colour, no motion — present, not pressing.
struct InboxBadgeView: View {
    let count: Int
    let side: Bool

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            if side {
                Circle().fill(Color.white.opacity(0.55)).frame(width: 5, height: 5)
                Spacer(minLength: 0)
            } else {
                Text(count > 99 ? "99+" : "\(count)")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.7))
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .padding(.trailing, 10)
            }
        }
        .frame(maxHeight: .infinity)
    }
}
