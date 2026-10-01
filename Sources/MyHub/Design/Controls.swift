import SwiftUI

// Shared building blocks from the handoff: card, ghost pill, segmented
// control, progress bar, toggle, shortcut badge, dashed drop zone.

extension View {
    /// Card: `#121214`, radius 16, padding 14.
    func hubCard(padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: HubTheme.Radius.card, style: .continuous).fill(HubTheme.Palette.card))
    }

    /// Selected row: `#1D1D20`, radius 10.
    func selectedRow(_ selected: Bool) -> some View {
        background(RoundedRectangle(cornerRadius: HubTheme.Radius.row, style: .continuous)
            .fill(selected ? HubTheme.Palette.selected : .clear))
    }
}

/// Ghost pill: padding 5×10, capsule `#1D1D20`, 11pt `#C9CACF`, 15pt icon.
struct GhostPill: View {
    let title: String
    var symbol: String?
    var tint: Color = HubTheme.Palette.soft
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 12, weight: .regular))
                }
                Text(title).font(HubTheme.Font.meta).lineLimit(1).fixedSize()
            }
            .foregroundStyle(tint)
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .background(Capsule().fill(HubTheme.Palette.selected))
            .contentShape(Capsule())
        }
        .buttonStyle(PressFade())
    }
}

/// The only press feedback anything in the panel needs.
struct PressFade: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(HubTheme.Motion.quick, value: configuration.isPressed)
    }
}

/// Segmented control: container `#121214` capsule, 3pt padding, 2pt gap;
/// active segment `#2A2A2E` 11pt semibold; inactive 11pt `#86878C`; 4×11.
/// Drawn by hand: a system segmented control greys out in a non-key window.
struct HubSegmented<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    var container: Color = HubTheme.Palette.card
    var active: Color = HubTheme.Palette.segmentActive
    /// A small count after a segment's title ("Assigned 5").
    var badges: [Value: String] = [:]
    @Namespace private var capsule

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let isOn = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    HStack(spacing: 5) {
                        Text(option.title)
                            .font(isOn ? HubTheme.Font.metaStrong : HubTheme.Font.meta)
                            .foregroundStyle(isOn ? HubTheme.Palette.primary : HubTheme.Palette.iconInactive)
                        if let badge = badges[option.value], !badge.isEmpty {
                            Text(badge)
                                .font(HubTheme.Font.axis)
                                .monospacedDigit()
                                .foregroundStyle(isOn ? HubTheme.Palette.accentLight : HubTheme.Palette.iconInactive)
                        }
                    }
                        .lineLimit(1)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 11)
                        .background {
                            if isOn {
                                Capsule().fill(active).matchedGeometryEffect(id: "segment", in: capsule)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(container))
        .animation(HubTheme.Motion.dock, value: selection)
    }
}

/// Progress bar: 5pt, radius 3, track `#26262A`.
struct ProgressLine: View {
    let value: Double
    var tint: Color = HubTheme.Palette.accent

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(HubTheme.Palette.track)
                RoundedRectangle(cornerRadius: 3).fill(tint)
                    .frame(width: proxy.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: 5)
        .animation(HubTheme.Motion.quick, value: value)
    }
}

/// An indeterminate bar for work whose length is unknown.
struct IndeterminateLine: View {
    var tint: Color = HubTheme.Palette.accent

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            GeometryReader { proxy in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                let width = proxy.size.width * 0.3
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(HubTheme.Palette.track)
                    RoundedRectangle(cornerRadius: 3).fill(tint)
                        .frame(width: width)
                        .offset(x: (proxy.size.width + width) * phase - width)
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
        }
        .frame(height: 5)
    }
}

/// Toggle: 30×18 capsule, 2pt padding, 14pt knob. On = accent + white knob
/// right; off = `#2A2A2E` + `#86878C` knob left. Drawn by hand — `NSSwitch`
/// turns grey in a window that is not key, and the panel almost never is.
struct HubToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                configuration.label
                Spacer(minLength: 4)
                Capsule()
                    .fill(configuration.isOn ? HubTheme.Palette.accent : HubTheme.Palette.segmentActive)
                    .frame(width: 30, height: 18)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(configuration.isOn ? Color.white : HubTheme.Palette.iconInactive)
                            .frame(width: 14, height: 14)
                            .padding(2)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(HubTheme.Motion.quick, value: configuration.isOn)
    }
}

/// Keyboard shortcut badge: 11pt, padding 2×6, radius 5, `#1D1D20`.
struct ShortcutBadge: View {
    let text: String
    var highlighted = false

    var body: some View {
        Text(text)
            .font(HubTheme.Font.meta)
            .foregroundStyle(highlighted ? HubTheme.Palette.onLight : HubTheme.Palette.muted)
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: HubTheme.Radius.badge)
                .fill(highlighted ? HubTheme.Palette.accent : HubTheme.Palette.selected))
    }
}

/// The dashed accent drop zone (stash slot and empty state).
struct DropZoneBackground: View {
    var radius: CGFloat
    var targeted: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(HubTheme.Palette.accent.opacity(targeted ? 0.12 : 0.06))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(HubTheme.Palette.accent.opacity(targeted ? 1 : 0.55), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            )
            .animation(.easeOut(duration: 0.15), value: targeted)
    }
}

/// Centred placeholder for an empty tab.
struct EmptyPaneHint: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 22, weight: .light))
            Text(text).font(HubTheme.Font.body).multilineTextAlignment(.center)
        }
        .foregroundStyle(HubTheme.Palette.tertiary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Older controls, restyled

/// Flat icon button.
struct HubIconButtonStyle: ButtonStyle {
    var size: CGFloat = 24
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(HubTheme.Palette.soft)
            .frame(width: size, height: size)
            .background(Circle().fill(filled ? HubTheme.Palette.selected : .clear))
            .contentShape(Circle())
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}

/// Small text button — a ghost pill without an icon.
struct HubTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HubTheme.Font.meta)
            .foregroundStyle(HubTheme.Palette.soft)
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .background(Capsule().fill(HubTheme.Palette.selected))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Primary capsule button (`#ECECEE` on `#111`), e.g. "Join".
struct LightCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HubTheme.Font.bodyStrong)
            .foregroundStyle(HubTheme.Palette.onLight)
            .padding(.vertical, 7)
            .padding(.horizontal, 14)
            .background(Capsule().fill(HubTheme.Palette.primary))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
