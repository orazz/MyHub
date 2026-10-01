import SwiftUI

/// The dock along the bottom of the panel. Tools on the left, Settings alone
/// on the right. The active tool is a light capsule with its label; the rest
/// are 34pt circles with a tooltip. The capsule slides between tools with a
/// spring — one shape moving, not two fading.
///
/// Resting on an icon selects it (Settings → Switch tabs on hover), after a
/// short dwell: a pointer passing along the dock on its way somewhere clears
/// each icon in tens of milliseconds and switches nothing; one that stops is
/// choosing.
struct DockView: View {
    let model: HubModel
    let session: ScreenSession
    @Namespace private var capsule

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(model.railSections.filter { $0 != .settings }) { item($0) }
            }
            Spacer(minLength: 8)
            if model.showsTabKeys && !session.wantsKeyboard {
                Text("⌥ ← →")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(HubTheme.Palette.onLight)
                    .padding(.horizontal, 6)
                    .frame(minHeight: 15)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(HubTheme.Palette.accentLight))
                    .padding(.trailing, 6)
                    .transition(.opacity)
                    .help(L10n.string("Previous / next tab"))
            }
            item(.settings)
        }
        .frame(height: ScreenMetrics.dockHeight)
        .animation(HubTheme.Motion.dock, value: model.section)
        .animation(HubTheme.Motion.quick, value: model.showsTabKeys)
    }

    private func item(_ section: Section) -> some View {
        DockItem(
            section: section,
            isActive: model.section == section,
            showsKey: model.showsTabKeys && !session.wantsKeyboard,
            switchesOnHover: model.preferences.values.general.switchTabsOnHover,
            namespace: capsule
        ) {
            session.select(section)
        }
    }
}

private struct DockItem: View {
    let section: Section
    let isActive: Bool
    let showsKey: Bool
    let switchesOnHover: Bool
    let namespace: Namespace.ID
    let select: () -> Void
    @State private var hovering = false
    @State private var dwell: Task<Void, Never>?

    private static let dwellTime: Duration = .milliseconds(150)

    var body: some View {
        Button(action: select) {
            HStack(spacing: 6) {
                Image(systemName: section.symbol)
                    .font(.system(size: isActive ? 14 : 15, weight: .regular))
                    .frame(width: 18)
                if isActive {
                    Text(section.title)
                        .font(HubTheme.Font.bodyStrong)
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                }
            }
            .foregroundStyle(isActive ? HubTheme.Palette.onLight : hovering ? HubTheme.Palette.primary : HubTheme.Palette.iconInactive)
            .padding(.horizontal, isActive ? 12 : 8)
            .frame(minWidth: 34, minHeight: 34)
            .background {
                if isActive {
                    Capsule().fill(HubTheme.Palette.primary)
                        .matchedGeometryEffect(id: "active", in: namespace)
                } else if hovering {
                    Circle().fill(HubTheme.Palette.selected)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if showsKey {
                Text(section.switchKey.label)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(HubTheme.Palette.onLight)
                    .frame(minWidth: 15, minHeight: 15)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(HubTheme.Palette.accentLight))
                    .offset(x: 4, y: -4)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(HubTheme.Motion.quick, value: showsKey)
        .help(section.title + "  ⌥" + section.switchKey.label)
        .accessibilityLabel(section.title)
        .onHover { inside in
            hovering = inside
            dwell?.cancel()
            dwell = nil
            guard inside, switchesOnHover, !isActive else { return }
            dwell = Task {
                try? await Task.sleep(for: Self.dwellTime)
                guard !Task.isCancelled else { return }
                select()
            }
        }
        .onDisappear { dwell?.cancel() }
    }
}
