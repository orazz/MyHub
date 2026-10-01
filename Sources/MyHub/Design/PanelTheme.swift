import Observation
import SwiftUI

/// The open panel's look: its background and accent colour.
///
/// Every theme starts black at the docked edge, so the panel still grows out
/// of the camera housing, and fades into its colour away from it. The closed
/// notch stays black whatever the theme. On gradient themes the cards turn
/// translucent so the colour shows through, keeping the same contrast steps
/// as Classic.
enum PanelTheme: String, CaseIterable, Codable, Identifiable, Sendable {
    case classic, midnight, aurora, sunset, grape, graphite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: L10n.string("Classic")
        case .midnight: L10n.string("Midnight")
        case .aurora: L10n.string("Aurora")
        case .sunset: L10n.string("Sunset")
        case .grape: L10n.string("Grape")
        case .graphite: L10n.string("Graphite")
        }
    }

    /// Colour at the far end of the gradient (Classic has none).
    var glow: Color? {
        switch self {
        case .classic: nil
        case .midnight: Color(hex: 0x10275A)
        case .aurora: Color(hex: 0x0A3F3A)
        case .sunset: Color(hex: 0x4A1A2E)
        case .grape: Color(hex: 0x30184F)
        case .graphite: Color(hex: 0x2C2D33)
        }
    }

    var accent: Color {
        switch self {
        case .classic: Color(hex: 0xE8A94A)
        case .midnight: Color(hex: 0x7EB6F2)
        case .aurora: Color(hex: 0x5FD8B4)
        case .sunset: Color(hex: 0xF28B6B)
        case .grape: Color(hex: 0xC59CF2)
        case .graphite: Color(hex: 0xD6D7DC)
        }
    }

    var accentLight: Color {
        switch self {
        case .classic: Color(hex: 0xF2B95C)
        case .midnight: Color(hex: 0x9CC8F7)
        case .aurora: Color(hex: 0x86E6C8)
        case .sunset: Color(hex: 0xF7A68C)
        case .grape: Color(hex: 0xD6B7F7)
        case .graphite: Color(hex: 0xECECEE)
        }
    }

    var isGradient: Bool { glow != nil }

    /// The panel fill: black at `edge` (the docked side), the theme's colour
    /// at the opposite side.
    func background(from edge: UnitPoint) -> AnyShapeStyle {
        guard let glow else { return AnyShapeStyle(Color.black) }
        let far = UnitPoint(x: 1 - edge.x, y: 1 - edge.y)
        return AnyShapeStyle(LinearGradient(
            stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.18), .init(color: glow, location: 1)],
            startPoint: edge, endPoint: far
        ))
    }
}

/// The theme in use, readable from anywhere the palette is.
///
/// `@Observable`, so a view that draws with a themed colour redraws when the
/// theme changes. Only ever written on the main thread (from `HubModel`);
/// reads go through Observation's thread-safe registrar.
@Observable
final class ThemeState: @unchecked Sendable {
    static let shared = ThemeState()
    var theme: PanelTheme = .classic
}
