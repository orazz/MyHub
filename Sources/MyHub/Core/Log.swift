import os

/// Unified-logging channels. Interpolated values are private by default in
/// `Logger`, which is what we want: paths, hosts and ids stay out of shared
/// logs unless explicitly marked `.public`. Secrets never go in at all — see
/// `Redacted`.
enum Log {
    private static let subsystem = "com.orazz.myhub"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let island = Logger(subsystem: subsystem, category: "island")
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let usage = Logger(subsystem: subsystem, category: "usage")
}
