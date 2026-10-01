import SwiftUI

/// Builds, per the handoff: the platform switch (only with "Both") and cache
/// actions on top; the current build — or the last result — in a card on the
/// left, recent builds on the right. "Stats" swaps the body for BuildWatch-
/// style statistics: time spent building by day, week, month, year.
struct BuildsView: View {
    let builds: BuildStore
    let preferences: Preferences

    var body: some View {
        VStack(spacing: 10) {
            header
            if builds.mode == .stats {
                BuildStatsView(builds: builds)
            } else {
                GeometryReader { proxy in
                    let wide = (proxy.size.width - 8) * 1.3 / 2.3
                    HStack(spacing: 8) {
                        CurrentBuildCard(builds: builds).frame(width: wide)
                        RecentBuilds(records: builds.recent, platform: builds.platform)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            HubSegmented(
                options: [(BuildStore.Mode.now, L10n.string("Now")), (.stats, L10n.string("Stats"))],
                selection: Binding(get: { builds.mode }, set: { builds.mode = $0 })
            )
            if builds.mode == .stats {
                Spacer(minLength: 6)
                HubSegmented(
                    options: BuildStats.Range.allCases.map { ($0, $0.title) },
                    selection: Binding(get: { builds.statsRange }, set: { builds.statsRange = $0 })
                )
            } else {
                nowHeader
            }
        }
        .frame(height: 26)
    }

    @ViewBuilder
    private var nowHeader: some View {
            if builds.tool == .both {
                HubSegmented(
                    options: [(BuildStore.Platform.xcode, "Xcode"), (.android, "Android Studio")],
                    selection: Binding(get: { builds.platform }, set: { builds.selectPlatform($0) })
                )
            } else {
                Text(builds.platform == .xcode ? "Xcode" : "Android Studio")
                    .font(HubTheme.Font.bodyStrong)
            }
            Spacer(minLength: 6)
            if builds.confirmingClear {
                Text(L10n.format("Delete %@ of DerivedData?", sizeText))
                    .font(HubTheme.Font.meta)
                    .foregroundStyle(HubTheme.Palette.soft)
                GhostPill(title: L10n.string("Delete"), symbol: "trash", tint: HubTheme.Palette.danger) { builds.clearDerivedData() }
                GhostPill(title: L10n.string("Cancel"), symbol: "xmark") { builds.confirmingClear = false }
            } else if builds.platform == .xcode {
                GhostPill(title: "DerivedData · \(sizeText)", symbol: "folder") { builds.revealCache() }
                GhostPill(title: builds.isClearing ? L10n.string("Clearing…") : L10n.string("Clear"), symbol: "trash") {
                    builds.confirmingClear = true
                }
                .disabled(builds.isClearing)
            } else {
                GhostPill(title: L10n.format("Build cache · %@", sizeText), symbol: "folder") { builds.revealCache() }
                GhostPill(title: builds.daemons > 0 ? L10n.format("Stop daemons (%d)", builds.daemons) : L10n.string("No daemons"),
                          symbol: "stop.circle") { builds.stopDaemons() }
                    .disabled(builds.daemons == 0)
            }
    }

    private var sizeText: String {
        builds.cacheBytes[builds.platform].map(BuildFormat.bytes) ?? "…"
    }
}

private struct CurrentBuildCard: View {
    let builds: BuildStore

    var body: some View {
        Group {
            if let current = builds.current {
                running(current)
            } else if let last = builds.recent.first {
                finished(last)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.string("No builds yet")).font(HubTheme.Font.buildTarget)
                    Text(builds.platform == .xcode
                         ? L10n.string("Build in Xcode and it shows up here, with the time and the result.")
                         : L10n.string("Run a Gradle build and it shows up here."))
                        .font(HubTheme.Font.meta)
                        .foregroundStyle(HubTheme.Palette.tertiary)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .hubCard()
    }

    private func running(_ build: CurrentBuild) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(build.target).font(HubTheme.Font.buildTarget).lineLimit(1)
                    Text(build.detail).font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.secondary)
                }
                Spacer(minLength: 6)
                StatusDot(color: HubTheme.Palette.amber, text: L10n.string("Building"), textColor: HubTheme.Palette.warn)
            }
            Spacer(minLength: 4)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = context.date.timeIntervalSince(build.startedAt)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(BuildFormat.clock(elapsed)).font(HubTheme.Font.buildTimer).tracking(-0.68)
                        if let average = build.averageDuration {
                            Text(L10n.format("avg %@", BuildFormat.clock(average)))
                                .font(HubTheme.Font.body)
                                .foregroundStyle(HubTheme.Palette.tertiary)
                        }
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .leading, spacing: 6) {
                        if let average = build.averageDuration, average > 0 {
                            // Xcode publishes no progress; this is time against the usual length.
                            ProgressLine(value: min(0.95, elapsed / average))
                        } else {
                            IndeterminateLine()
                        }
                        Text(build.step)
                            .font(HubTheme.Font.meta)
                            .foregroundStyle(HubTheme.Palette.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func finished(_ record: BuildRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.name).font(HubTheme.Font.buildTarget).lineLimit(1)
                    Text(L10n.format("Finished %@", record.finished.formatted(.relative(presentation: .named))))
                        .font(HubTheme.Font.meta)
                        .foregroundStyle(HubTheme.Palette.secondary)
                }
                Spacer(minLength: 6)
                StatusDot(color: record.status.color, text: record.status.label, textColor: record.status.color)
            }
            Spacer(minLength: 4)
            Text(BuildFormat.clock(record.duration)).font(HubTheme.Font.buildTimer).tracking(-0.68)
            Spacer(minLength: 4)
            VStack(alignment: .leading, spacing: 6) {
                ProgressLine(value: 1, tint: record.status.color)
                Text(L10n.string("Last build")).font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.tertiary)
            }
        }
    }
}

private struct RecentBuilds: View {
    let records: [BuildRecord]
    let platform: BuildStore.Platform

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.string("Recent"))
                .font(HubTheme.Font.meta)
                .foregroundStyle(HubTheme.Palette.tertiary)
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 6)
            if records.isEmpty {
                Text(L10n.string("Nothing yet"))
                    .font(HubTheme.Font.body)
                    .foregroundStyle(HubTheme.Palette.tertiary)
                    .padding(.horizontal, 8)
            }
            // As many as the panel size leaves room for; the rest scroll.
            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(records) { record in
                        HStack(spacing: 8) {
                            Circle().fill(record.status.color).frame(width: 6, height: 6)
                            Text(record.name).font(HubTheme.Font.body).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(BuildFormat.clock(record.duration))
                                .font(HubTheme.Font.body)
                                .foregroundStyle(HubTheme.Palette.secondary)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, 8)
                        .help(record.finished.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
            if platform == .android, !records.isEmpty {
                Text(L10n.string("Gradle does not record results; times only."))
                    .font(HubTheme.Font.axis)
                    .foregroundStyle(HubTheme.Palette.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
            }
        }
    }
}

private struct StatusDot: View {
    let color: Color
    let text: String
    let textColor: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(HubTheme.Font.meta).foregroundStyle(textColor)
        }
    }
}

extension BuildRecord.Status {
    var color: Color {
        switch self {
        case .success: HubTheme.Palette.success
        case .failure: HubTheme.Palette.danger
        case .cancelled, .unknown: HubTheme.Palette.iconInactive
        }
    }

    var label: String {
        switch self {
        case .success: L10n.string("Succeeded")
        case .failure: L10n.string("Failed")
        case .cancelled: L10n.string("Cancelled")
        case .unknown: L10n.string("Finished")
        }
    }
}
