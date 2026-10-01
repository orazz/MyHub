import SwiftUI

extension Color {
    /// `Color(hex: 0x121214)` — design tokens are specified in sRGB hex.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// Design tokens from the "Notch panel, direction 1b" handoff. The panel is
/// black on every Mac, so the whole palette is built for a dark ground.
enum HubTheme {
    enum Palette {
        // Surfaces
        static let panel = Color.black
        // On gradient themes these become white at the opacity that gives
        // the same step over black, so the theme's colour shows through.
        private static var translucent: Bool { ThemeState.shared.theme.isGradient }
        static var card: Color { translucent ? .white.opacity(0.07) : Color(hex: 0x121214) }
        static var tile: Color { translucent ? .white.opacity(0.11) : Color(hex: 0x1F1F23) }
        /// Selected row and ghost pill.
        static var selected: Color { translucent ? .white.opacity(0.10) : Color(hex: 0x1D1D20) }
        static var segmentActive: Color { translucent ? .white.opacity(0.16) : Color(hex: 0x2A2A2E) }
        static var track: Color { translucent ? .white.opacity(0.14) : Color(hex: 0x26262A) }
        static var dashed: Color { translucent ? .white.opacity(0.20) : Color(hex: 0x34343A) }
        static let checkboxBorder = Color(hex: 0x4A4A50)

        // Text
        static let primary = Color(hex: 0xECECEE)
        static let strong = Color(hex: 0xE6E6E8)
        static let soft = Color(hex: 0xC9CACF)
        static let muted = Color(hex: 0xA4A5AA)
        static let secondary = Color(hex: 0x8A8B90)
        static let tertiary = Color(hex: 0x77787D)
        static let iconInactive = Color(hex: 0x86878C)
        static let onLight = Color(hex: 0x111111)

        // Accent (follows the theme) and status (fixed: green is always
        // success, red always failure).
        static var accent: Color { ThemeState.shared.theme.accent }
        static var accentLight: Color { ThemeState.shared.theme.accentLight }
        static let success = Color(hex: 0x6FCF8E)
        static let danger = Color(hex: 0xE7706A)
        static let blue = Color(hex: 0x7EB6F2)

        // Older names, mapped onto the new palette.
        static var surface: Color { card }
        static var surfaceHover: Color { selected }
        static var surfaceSelected: Color { segmentActive }
        static var hairline: Color { track }
        static let good = success
        /// Warnings and "in progress" stay amber on every theme: a status
        /// colour must mean the same thing whatever the accent is.
        static let warn = Color(hex: 0xF2B95C)
        static let amber = Color(hex: 0xE8A94A)
        static let bad = danger
    }

    enum Radius {
        static let panelBottom: CGFloat = 34
        static let dropZone: CGFloat = 22
        static let card: CGFloat = 16
        static let eventCard: CGFloat = 14
        static let row: CGFloat = 10
        static let badge: CGFloat = 5
        static let checkbox: CGFloat = 4

        // The notch shape.
        static let collapsedTop: CGFloat = 6
        static let collapsedBottom: CGFloat = 10
        static let openTop: CGFloat = 10
        static let openBottom: CGFloat = panelBottom
    }

    enum Motion {
        /// Opening: a soft spring with a gentle settle.
        static let open = Animation.spring(response: 0.42, dampingFraction: 0.8)
        /// Closing: quicker and critically damped — no bounce on the way back.
        static let close = Animation.spring(response: 0.3, dampingFraction: 1)
        /// Content fades in just after the shape starts to grow…
        static let contentIn = Animation.easeOut(duration: 0.22).delay(0.06)
        /// …and leaves before the shape shrinks over it.
        static let contentOut = Animation.easeIn(duration: 0.1)
        /// The shadow arrives once the open spring has mostly settled.
        static let shadowIn = Animation.easeOut(duration: 0.25).delay(0.3)
        /// How long the close takes to settle — the window is left alone
        /// (key status, click area) until then.
        static let closeSettle: Duration = .milliseconds(380)
        /// How long to hold background work after opening.
        static let openSettle: Duration = .milliseconds(380)

        static let island = open
        /// The dock capsule: "spring, about 0.3s, damping about 0.85".
        static let dock = Animation.spring(response: 0.3, dampingFraction: 0.85)
        /// Content cross-fade between tabs.
        static let content = Animation.easeInOut(duration: 0.15)
        static let quick = Animation.easeOut(duration: 0.15)

        // Older names.
        static let paneIn = content
        static let paneOut = content
    }

    enum Font {
        static let buildTimer = SwiftUI.Font.system(size: 34, weight: .semibold).monospacedDigit()
        static let usagePercent = SwiftUI.Font.system(size: 32, weight: .semibold)
        static let calendarDate = SwiftUI.Font.system(size: 26, weight: .semibold)
        static let title = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let eventTitle = SwiftUI.Font.system(size: 14, weight: .semibold)
        static let buildTarget = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 12)
        static let bodyMedium = SwiftUI.Font.system(size: 12, weight: .medium)
        static let bodyStrong = SwiftUI.Font.system(size: 12, weight: .semibold)
        static let meta = SwiftUI.Font.system(size: 11)
        static let metaStrong = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let axis = SwiftUI.Font.system(size: 10)
        static let mono = SwiftUI.Font.system(size: 12, design: .monospaced)

        // Older names.
        static let header = SwiftUI.Font.system(size: 9, weight: .semibold)
        static let caption = meta
    }
}
