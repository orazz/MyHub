import SwiftUI

/// The closed notch, briefly widened: a status on the left of the hole, the
/// detail on the right — "✓ Orbit · Debug      1:08".
struct NotchFlashView: View {
    let flash: NotchFlash
    /// Room left clear in the middle for the hole (none on a side edge).
    var gap: CGFloat = 150

    private var tint: Color {
        switch flash.success {
        case true?: HubTheme.Palette.success
        case false?: HubTheme.Palette.danger
        case nil: HubTheme.Palette.soft
        }
    }

    private var symbol: String {
        switch flash.success {
        case true?: "checkmark.circle.fill"
        case false?: "xmark.octagon.fill"
        case nil: flash.symbol ?? "hammer.fill"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            // A small hop when it appears — a finished agent or build is good news.
            Image(systemName: symbol).foregroundStyle(tint)
                .symbolEffect(.bounce, value: flash)
            Text(flash.title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: gap)
            Text(flash.detail).monospacedDigit().foregroundStyle(tint)
        }
        .font(HubTheme.Font.metaStrong)
        .foregroundStyle(HubTheme.Palette.primary)
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
    }
}
