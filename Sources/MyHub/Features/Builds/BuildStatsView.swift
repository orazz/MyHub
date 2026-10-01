import SwiftUI

/// BuildWatch-style statistics: total time, number of builds and average for
/// the chosen range on the left (click one to chart it), and the chart on the
/// right — split by scheme when charting total time.
struct BuildStatsView: View {
    let builds: BuildStore

    static let schemeColors: [Color] = [
        HubTheme.Palette.amber, HubTheme.Palette.blue, HubTheme.Palette.success,
        Color(hex: 0xC08CF2), HubTheme.Palette.danger,
    ]

    var body: some View {
        let summary = builds.summary()
        GeometryReader { proxy in
            HStack(spacing: 8) {
                VStack(spacing: 6) {
                    MetricTile(title: L10n.string("Building"), value: BuildStats.duration(summary.total), metric: .total, builds: builds)
                    MetricTile(title: L10n.string("Builds"),
                               value: summary.failures > 0 ? "\(summary.builds) · \(summary.failures) failed" : "\(summary.builds)",
                               metric: .count, builds: builds)
                    MetricTile(title: L10n.string("Average"), value: BuildStats.duration(summary.average), metric: .average, builds: builds)
                }
                .frame(width: min(170, proxy.size.width * 0.3))
                BuildChart(summary: summary, allSchemes: builds.schemesInRange(), metric: builds.statsMetric,
                           split: builds.splitBySchemes && builds.statsMetric == .total, builds: builds)
            }
        }
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let metric: BuildStats.Metric
    let builds: BuildStore

    private var selected: Bool { builds.statsMetric == metric }

    var body: some View {
        Button { builds.statsMetric = metric } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(HubTheme.Font.meta)
                    .foregroundStyle(selected ? HubTheme.Palette.accentLight : HubTheme.Palette.secondary)
                Text(value)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(HubTheme.Palette.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: HubTheme.Radius.row + 2, style: .continuous)
                .fill(selected ? HubTheme.Palette.selected : HubTheme.Palette.card))
            .overlay(RoundedRectangle(cornerRadius: HubTheme.Radius.row + 2, style: .continuous)
                .strokeBorder(selected ? HubTheme.Palette.accent.opacity(0.5) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressFade())
        .help(L10n.string("Chart this"))
    }
}

private struct BuildChart: View {
    let summary: BuildStats.Summary
    /// Every scheme in the range, hidden ones included.
    let allSchemes: [(name: String, seconds: TimeInterval)]
    let metric: BuildStats.Metric
    let split: Bool
    let builds: BuildStore
    /// The bar under the pointer; its figures replace the title and legend.
    @State private var hovered: Date?

    private var hoveredBucket: BuildStats.Bucket? {
        #if DEBUG
        if let index = builds.previewHoverIndex, summary.buckets.indices.contains(index) { return summary.buckets[index] }
        #endif
        return hovered.flatMap { start in summary.buckets.first { $0.start == start } }
    }

    /// The five biggest schemes get colours; the rest share grey. Ranked over
    /// all schemes, so hiding one never repaints the others.
    private var named: [String] { Array(allSchemes.prefix(BuildStatsView.schemeColors.count).map(\.name)) }

    private func color(_ scheme: String) -> Color {
        named.firstIndex(of: scheme).map { BuildStatsView.schemeColors[$0] } ?? HubTheme.Palette.iconInactive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let bucket = hoveredBucket {
                    readout(bucket)
                } else {
                    Text(title).font(HubTheme.Font.body).foregroundStyle(HubTheme.Palette.secondary)
                }
                Spacer(minLength: 4)
                if metric == .total, hoveredBucket == nil {
                    Button { builds.splitBySchemes.toggle() } label: {
                        Text(builds.splitBySchemes ? L10n.string("By scheme") : L10n.string("Combined"))
                            .font(HubTheme.Font.meta)
                            .foregroundStyle(HubTheme.Palette.soft)
                            .padding(.vertical, 3).padding(.horizontal, 8)
                            .background(Capsule().fill(HubTheme.Palette.selected))
                    }
                    .buttonStyle(PressFade())
                    .help(L10n.string("Split or combine schemes"))
                }
            }
            if summary.builds == 0 {
                Text(allSchemes.isEmpty ? L10n.string("No builds in this range") : L10n.string("Every project is hidden — turn one on below"))
                    .font(HubTheme.Font.meta)
                    .foregroundStyle(HubTheme.Palette.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                bars
                axis
            }
            if let bucket = hoveredBucket, bucket.builds > 0 {
                breakdown(bucket)
            } else if allSchemes.count > 1 {
                legend
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .hubCard(padding: 12)
        .animation(HubTheme.Motion.quick, value: hovered)
    }

    private var title: String {
        switch metric {
        case .total: L10n.string("Time spent building")
        case .count: L10n.string("Builds")
        case .average: L10n.string("Average build time")
        }
    }

    private var bars: some View {
        let buckets = summary.buckets
        let peak = max(0.0001, buckets.map { $0.value(metric) }.max() ?? 1)
        let gap: CGFloat = buckets.count > 20 ? 2 : 4
        return GeometryReader { proxy in
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(buckets) { bucket in
                    let height = max(bucket.builds > 0 ? 3 : 1, proxy.size.height * bucket.value(metric) / peak)
                    Group {
                        if split, bucket.builds > 0 {
                            VStack(spacing: 0) {
                                ForEach(segments(bucket), id: \.name) { segment in
                                    Rectangle().fill(color(segment.name))
                                        .frame(height: height * segment.seconds / max(bucket.total, 0.0001))
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        } else {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(bucket.builds > 0 ? HubTheme.Palette.accent : HubTheme.Palette.segmentActive)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .opacity(hoveredBucket == nil || hoveredBucket?.start == bucket.start ? 1 : 0.4)
                    // The whole column reacts, not just the bar — short bars
                    // would otherwise be hard to hit.
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hovered = bucket.start } else if hovered == bucket.start { hovered = nil }
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
        }
        .frame(minHeight: 50, maxHeight: .infinity)
    }

    /// Largest on the bottom, so bars read like a stacked area.
    private func segments(_ bucket: BuildStats.Bucket) -> [(name: String, seconds: TimeInterval)] {
        var named: [(name: String, seconds: TimeInterval)] = []
        var other: TimeInterval = 0
        for (scheme, seconds) in bucket.seconds {
            if self.named.contains(scheme) { named.append((scheme, seconds)) } else { other += seconds }
        }
        named.sort { (self.named.firstIndex(of: $0.name) ?? 0) > (self.named.firstIndex(of: $1.name) ?? 0) }
        return (other > 0 ? [("Other", other)] : []) + named
    }

    /// "Fri 26 Sep · 1h 6m · 9 builds · 1 failed" for the bar under the pointer.
    private func readout(_ bucket: BuildStats.Bucket) -> some View {
        HStack(spacing: 6) {
            Text(bucket.title).foregroundStyle(HubTheme.Palette.primary).fontWeight(.semibold)
            if bucket.builds == 0 {
                Text(L10n.string("no builds")).foregroundStyle(HubTheme.Palette.tertiary)
            } else {
                Text(BuildStats.duration(bucket.total)).foregroundStyle(HubTheme.Palette.accentLight).monospacedDigit()
                Text(bucket.builds == 1 ? L10n.string("1 build") : L10n.format("%d builds", bucket.builds))
                    .foregroundStyle(HubTheme.Palette.secondary)
                if bucket.failures > 0 {
                    Text(L10n.format("%d failed", bucket.failures)).foregroundStyle(HubTheme.Palette.danger)
                }
                Text(L10n.format("avg %@", BuildStats.duration(bucket.average)))
                    .foregroundStyle(HubTheme.Palette.tertiary).monospacedDigit()
            }
        }
        .font(HubTheme.Font.body)
        .lineLimit(1)
    }

    /// The hovered bar's time per scheme, largest first.
    private func breakdown(_ bucket: BuildStats.Bucket) -> some View {
        let schemes = bucket.seconds.sorted { $0.value > $1.value }
        return HStack(spacing: 10) {
            ForEach(Array(schemes.prefix(4)), id: \.key) { scheme, seconds in
                HStack(spacing: 4) {
                    Circle().fill(color(scheme)).frame(width: 6, height: 6)
                    Text(scheme).lineLimit(1)
                    Text(BuildStats.duration(seconds)).foregroundStyle(HubTheme.Palette.tertiary).monospacedDigit()
                }
            }
            if schemes.count > 4 {
                Text(L10n.format("+%d more", schemes.count - 4)).foregroundStyle(HubTheme.Palette.tertiary)
            }
        }
        .font(HubTheme.Font.axis)
        .foregroundStyle(HubTheme.Palette.soft)
        .lineLimit(1)
    }

    private var axis: some View {
        HStack {
            Text(summary.buckets.first?.label ?? "")
            Spacer()
            if summary.buckets.count > 4 { Text(summary.buckets[summary.buckets.count / 2].label) }
            Spacer()
            Text(summary.buckets.last?.label ?? "")
        }
        .font(HubTheme.Font.axis)
        .foregroundStyle(HubTheme.Palette.tertiary)
    }

    /// One chip per scheme: click to leave it out of the chart and the
    /// totals, click again to bring it back.
    private var legend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(allSchemes, id: \.name) { scheme in
                    let hidden = builds.isSchemeHidden(scheme.name)
                    Button { builds.toggleScheme(scheme.name) } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(hidden ? Color.clear : color(scheme.name))
                                .overlay(Circle().strokeBorder(color(scheme.name), lineWidth: hidden ? 1 : 0))
                                .frame(width: 7, height: 7)
                            Text(scheme.name)
                                .foregroundStyle(hidden ? HubTheme.Palette.tertiary : HubTheme.Palette.soft)
                                .strikethrough(hidden, color: HubTheme.Palette.tertiary)
                            Text(BuildStats.duration(scheme.seconds))
                                .foregroundStyle(HubTheme.Palette.tertiary)
                                .monospacedDigit()
                        }
                        .lineLimit(1)
                        .padding(.vertical, 3).padding(.horizontal, 7)
                        .background(Capsule().fill(hidden ? Color.clear : HubTheme.Palette.selected))
                        .overlay(Capsule().strokeBorder(hidden ? HubTheme.Palette.segmentActive : .clear, lineWidth: 1))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(PressFade())
                    .help(hidden ? L10n.format("Show %@", scheme.name) : L10n.format("Hide %@", scheme.name))
                }
                if allSchemes.contains(where: { builds.isSchemeHidden($0.name) }) {
                    Button(L10n.string("Show all")) { builds.showAllSchemes() }
                        .buttonStyle(.plain)
                        .foregroundStyle(HubTheme.Palette.accentLight)
                }
            }
        }
        .font(HubTheme.Font.axis)
    }
}
