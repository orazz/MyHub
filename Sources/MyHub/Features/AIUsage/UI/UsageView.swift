import AppKit
import SwiftUI

/// AI usage, per the handoff: provider segments and "plan · updated" on top;
/// three cards below — current session, weekly limit, and tokens over seven
/// days. Sources without limit windows (API keys) show today's and this
/// month's spend in the first two cards instead.
struct UsageView: View {
    let usage: UsageStore
    let shield: ContentShield
    let session: ScreenSession
    /// Tells the island a form with fields is showing, so a click into it
    /// takes the keyboard.
    let onFormActive: (Bool) -> Void

    var body: some View {
        // The source list and the form replace the cards inside the panel —
        // pop-up menus from a panel that never becomes active are unreliable.
        if usage.draft != nil {
            SourceSetupForm(usage: usage, session: session, onFormActive: onFormActive)
        } else if usage.accounts.isEmpty || usage.isPicking {
            SourcePicker(usage: usage, onDone: usage.accounts.isEmpty ? nil : { usage.isPicking = false })
        } else if let group = usage.selectedGroup {
            let summary = usage.summary(for: group)
            VStack(spacing: 10) {
                header(group: group, summary: summary)
                // The handoff's 1 / 1 / 1.2 grid with an 8pt gap.
                GeometryReader { proxy in
                    let unit = (proxy.size.width - 16) / 3.2
                    HStack(spacing: 8) {
                        StatCard(stat: summary.session, fallbackTitle: L10n.string("Current session"), accent: true, hidden: hidden(group))
                            .frame(width: unit)
                        StatCard(stat: summary.weekly, fallbackTitle: L10n.string("Weekly limit"), accent: false, hidden: hidden(group))
                            .frame(width: unit)
                        TokensCard(daily: summary.daily, today: summary.todayTokens)
                            .frame(width: unit * 1.2)
                    }
                }
            }
        }
    }

    private func hidden(_ group: UsageGroup) -> Bool {
        shield.masks(group.id, in: .usage)
    }

    private func header(group: UsageGroup, summary: UsageSummary) -> some View {
        HStack(spacing: 8) {
            if usage.groups.count > 1 {
                HubSegmented(
                    options: usage.groups.map { ($0.id, $0.title) },
                    selection: Binding(get: { group.id }, set: { usage.selectedGroupID = $0 })
                )
            } else {
                Text(group.title).font(HubTheme.Font.bodyStrong)
            }
            Button { usage.isPicking = true } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(HubIconButtonStyle(size: 24, filled: true))
            .help(L10n.string("Add or remove sources"))
            Spacer(minLength: 6)
            if let problem = summary.problems.first {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(HubTheme.Font.meta)
                    .foregroundStyle(summary.fetchedAt == nil ? HubTheme.Palette.danger : HubTheme.Palette.tertiary)
                    .lineLimit(1)
                    .help(summary.problems.joined(separator: "\n"))
            } else {
                Text(statusLine(summary))
                    .font(HubTheme.Font.meta)
                    .foregroundStyle(HubTheme.Palette.tertiary)
                    .lineLimit(1)
            }
            if shield.isShielded(.usage) {
                RevealButton(hidden: hidden(group)) { shield.togglePeek(group.id) }
            }
            Button { usage.refresh(force: true) } label: {
                Image(systemName: "arrow.clockwise").opacity(usage.isRefreshing ? 0.35 : 1)
            }
            .buttonStyle(HubIconButtonStyle(size: 22))
            .disabled(usage.isRefreshing)
            .help(L10n.string("Refresh"))
        }
        .frame(height: 26)
    }

    private func statusLine(_ summary: UsageSummary) -> String {
        let updated: String
        if let fetched = summary.fetchedAt {
            updated = Date().timeIntervalSince(fetched) < 60
                ? L10n.string("updated just now")
                : L10n.format("updated %@", fetched.formatted(.relative(presentation: .named)))
        } else {
            updated = usage.isRefreshing ? L10n.string("loading…") : L10n.string("not loaded yet")
        }
        return [summary.plan, updated].compactMap { $0 }.joined(separator: " · ")
    }
}

/// "Current session 62% ▬▬▬ Resets in 1h 48m" (and the weekly twin).
private struct StatCard: View {
    let stat: UsageSummary.Stat?
    let fallbackTitle: String
    /// Accent bar (session) or light bar (weekly).
    let accent: Bool
    let hidden: Bool

    private var danger: Bool { accent && (stat?.progress ?? 0) > 0.9 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(stat?.title ?? fallbackTitle)
                .font(HubTheme.Font.body)
                .foregroundStyle(HubTheme.Palette.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Group {
                if hidden {
                    ShieldHatch().frame(width: 70, height: 16)
                } else {
                    Text(stat?.value ?? "—")
                        .font(HubTheme.Font.usagePercent)
                        .tracking(-0.64)
                        .foregroundStyle(danger ? HubTheme.Palette.danger : HubTheme.Palette.primary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .leading, spacing: 6) {
                if let progress = stat?.progress {
                    ProgressLine(value: progress, tint: danger ? HubTheme.Palette.danger : accent ? HubTheme.Palette.amber : HubTheme.Palette.primary)
                }
                footnote
                    .font(HubTheme.Font.meta)
                    .foregroundStyle(HubTheme.Palette.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .hubCard()
    }

    @ViewBuilder
    private var footnote: some View {
        if let reset = stat?.resetsAt {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(Self.resetText(reset, now: context.date))
            }
        } else if let note = stat?.footnote {
            Text(note)
        } else {
            Text(stat == nil ? L10n.string("No data from these sources") : " ")
        }
    }

    /// "Resets in 1h 48m" within a day; "Resets Mon 09:00" after that.
    static func resetText(_ reset: Date, now: Date) -> String {
        let interval = reset.timeIntervalSince(now)
        if interval <= 0 { return L10n.string("Resetting now") }
        if interval < 86400 {
            return L10n.format("Resets in %@", AgendaFormat.shortDuration(interval))
        }
        return L10n.format("Resets %@", reset.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
    }
}

/// "Tokens, 7 days · 1.2M today" and seven bars, today in the accent.
private struct TokensCard: View {
    let daily: [DayTokens]
    let today: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.string("Tokens, 7 days")).foregroundStyle(HubTheme.Palette.secondary)
                Spacer(minLength: 4)
                if let today {
                    Text(L10n.format("%@ today", UsageFormat.tokens(today))).foregroundStyle(HubTheme.Palette.primary)
                }
            }
            .font(HubTheme.Font.body)
            .lineLimit(1)
            if daily.isEmpty {
                Text(L10n.string("Add local logs or an API key to see daily tokens"))
                    .font(HubTheme.Font.meta)
                    .foregroundStyle(HubTheme.Palette.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let peak = max(1, daily.map(\.tokens).max() ?? 1)
                // 80pt at the default panel size; taller panels get a taller chart.
                GeometryReader { proxy in
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(Array(daily.enumerated()), id: \.element.id) { index, day in
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(index == daily.count - 1 ? HubTheme.Palette.accent : HubTheme.Palette.segmentActive)
                                .frame(maxWidth: .infinity)
                                .frame(height: max(3, proxy.size.height * CGFloat(day.tokens) / CGFloat(peak)))
                                .help("\(day.day.formatted(.dateTime.weekday(.abbreviated).day())): \(UsageFormat.tokens(day.tokens))")
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
                }
                .frame(minHeight: 80, maxHeight: .infinity)
                .padding(.top, 6)
                Spacer(minLength: 6)
                HStack {
                    Text(daily.first?.day.formatted(.dateTime.weekday(.abbreviated)) ?? "")
                    Spacer()
                    Text(L10n.string("Today"))
                }
                .font(HubTheme.Font.axis)
                .foregroundStyle(HubTheme.Palette.tertiary)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .hubCard()
    }
}

/// Connected sources (removable) and the ones that can be added.
private struct SourcePicker: View {
    let usage: UsageStore
    /// nil on the first-run screen, where there are no cards to go back to.
    let onDone: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(onDone == nil
                     ? L10n.string("See how much of your AI plans and API budgets you have used")
                     : L10n.string("Sources"))
                    .font(HubTheme.Font.bodyStrong)
                    .foregroundStyle(HubTheme.Palette.primary)
                Spacer()
                if let onDone {
                    GhostPill(title: L10n.string("Done"), symbol: "checkmark", action: onDone)
                }
            }
            .frame(height: 26)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    if !usage.accounts.isEmpty {
                        ForEach(usage.accounts) { account in
                            ConnectedRow(account: account, error: usage.errors[account.id]) { usage.remove(account.id) }
                        }
                        Text(L10n.string("Add a source"))
                            .font(HubTheme.Font.meta)
                            .foregroundStyle(HubTheme.Palette.tertiary)
                            .padding(.top, 6)
                    }
                    ForEach(usage.sourceChoices.filter { !$0.added }) { choice in
                        SourceRow(choice: choice) { usage.choose(choice.kind) }
                    }
                }
            }
        }
        .onAppear { usage.refreshDetected() }
    }
}

private struct ConnectedRow: View {
    let account: UsageAccount
    let error: UsageError?
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: account.kind.symbol).font(.system(size: 13)).frame(width: 18).foregroundStyle(HubTheme.Palette.accentLight)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.label).font(HubTheme.Font.bodyMedium)
                Text(error?.message ?? account.kind.title)
                    .font(HubTheme.Font.meta)
                    .foregroundStyle(error == nil ? HubTheme.Palette.tertiary : HubTheme.Palette.danger)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            GhostPill(title: L10n.string("Remove"), symbol: "trash", action: remove)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .selectedRow(true)
    }
}

private struct SourceRow: View {
    let choice: UsageStore.SourceChoice
    let add: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: choice.kind.symbol).font(.system(size: 13)).frame(width: 18).foregroundStyle(HubTheme.Palette.muted)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(choice.kind.title).font(HubTheme.Font.bodyMedium)
                    if choice.detected {
                        Text(L10n.string("Found on this Mac"))
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1.5)
                            .background(Capsule().fill(HubTheme.Palette.accent.opacity(0.14)))
                            .foregroundStyle(HubTheme.Palette.accentLight)
                    }
                }
                Text(choice.kind.explanation)
                    .font(HubTheme.Font.meta)
                    .foregroundStyle(HubTheme.Palette.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            GhostPill(title: choice.kind.needsSetup ? L10n.string("Set up") : L10n.string("Add"),
                      symbol: choice.kind.needsSetup ? "key" : "plus", action: add)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: HubTheme.Radius.row, style: .continuous).fill(HubTheme.Palette.card))
    }
}

enum UsageFormat {
    static func tokens(_ count: Int) -> String {
        switch count {
        case ..<1_000: "\(count)"
        case ..<1_000_000: String(format: "%.1fK", Double(count) / 1_000)
        case ..<1_000_000_000: String(format: "%.1fM", Double(count) / 1_000_000)
        default: String(format: "%.2fB", Double(count) / 1_000_000_000)
        }
    }

    /// "claude-opus-5-5" → "opus 5.5"; other ids pass through.
    static func model(_ id: String) -> String {
        guard id.hasPrefix("claude-") else { return id }
        let parts = id.dropFirst("claude-".count).split(separator: "-")
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().prefix { $0.count <= 2 }.joined(separator: ".")
        return version.isEmpty ? String(family) : "\(family) \(version)"
    }
}
