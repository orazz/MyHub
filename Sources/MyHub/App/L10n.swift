import Foundation

/// Localised text for places that need a plain `String` — menu titles,
/// tooltips, sentences put together in code. The English text doubles as the
/// key, so with no strings table (a bare `swift run`) the English shows.
enum L10n {
    static func string(_ english: String) -> String {
        Bundle.main.localizedString(forKey: english, value: english, table: nil)
    }

    static func format(_ english: String, _ values: CVarArg...) -> String {
        String(format: string(english), locale: .current, arguments: values)
    }
}

extension Bundle {
    /// "0.1.0" in a bundled build, "dev" when run from SwiftPM.
    var appVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
