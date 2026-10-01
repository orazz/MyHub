import SwiftUI

/// A single line of text, or — when covered — a fixed hatch that fills the
/// available width. The hatch never depends on the text, so neither its
/// content nor its length can be read off the screen or a recording.
struct ShieldedText: View {
    let text: String
    let hidden: Bool
    var font: Font = HubTheme.Font.body
    var color: Color = HubTheme.Palette.primary

    var body: some View {
        if hidden {
            ShieldHatch()
                .frame(height: 9)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(L10n.string("Hidden"))
        } else {
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ShieldHatch: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 5
            var x: CGFloat = -size.height
            var path = Path()
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += step
            }
            context.clip(to: Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2))
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(HubTheme.Palette.surface))
            context.stroke(path, with: .color(HubTheme.Palette.tertiary), lineWidth: 1.2)
        }
    }
}

/// The eye on a covered row.
struct RevealButton: View {
    let hidden: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: hidden ? "eye" : "eye.slash")
        }
        .buttonStyle(HubIconButtonStyle(size: 18))
        .accessibilityLabel(hidden ? L10n.string("Show") : L10n.string("Hide"))
    }
}

/// Footer switch that covers one section.
struct ShieldSwitch: View {
    let shield: ContentShield
    let section: Section

    var body: some View {
        let on = shield.isShielded(section)
        Button {
            shield.setShielded(!on, for: section)
        } label: {
            Image(systemName: on ? "eye.slash.fill" : "eye")
        }
        .buttonStyle(HubIconButtonStyle(size: 20, filled: on))
        .help(on ? L10n.string("Show contents") : L10n.string("Hide contents"))
    }
}
