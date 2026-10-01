import AppKit
import UserNotifications

struct UsageAlert: Equatable, Sendable {
    let key: String
    let title: String
    let body: String
}

/// Decides which limit crossings deserve a notification. Pure, so the rules
/// are tested.
///
/// A window alerts once per threshold per period: the key includes the
/// window's reset time, so the same window can alert again after it resets.
/// Only the highest threshold crossed is announced — jumping from 60% to 97%
/// sends one notification, not two.
struct AlertLedger: Sendable, Equatable {
    static let thresholds: [Double] = [0.8, 0.95]

    private(set) var fired: Set<String>

    init(fired: Set<String> = []) {
        self.fired = fired
    }

    mutating func evaluate(_ items: [(account: UsageAccount, snapshot: UsageSnapshot)], now: Date) -> [UsageAlert] {
        var alerts: [UsageAlert] = []
        for (account, snapshot) in items {
            for window in snapshot.windows {
                guard let crossed = Self.thresholds.last(where: { window.used >= $0 }) else { continue }
                // Reset times come back with sub-second jitter between fetches;
                // five-minute buckets keep one period one key.
                let period = window.resetsAt.map { String(Int(($0.timeIntervalSince1970 / 300).rounded())) } ?? "open"
                func key(_ threshold: Double) -> String { "\(account.id)|\(window.id)|\(period)|\(threshold)" }
                guard !fired.contains(key(crossed)) else { continue }
                Self.thresholds.filter { $0 <= crossed }.forEach { fired.insert(key($0)) }

                let percent = Int((window.used * 100).rounded())
                var body = L10n.format("%@ is at %d%%.", window.label, percent)
                if let reset = window.resetsAt, reset > now {
                    body += " " + L10n.format("Resets in %@.", AgendaFormat.duration(reset.timeIntervalSince(now)))
                }
                alerts.append(UsageAlert(key: key(crossed), title: L10n.format("%@ — %d%% used", account.label, percent), body: body))
            }
        }
        return alerts
    }

    /// Keeps the remembered set from growing forever.
    mutating func trim(keeping limit: Int = 200) {
        if fired.count > limit { fired = Set(fired.sorted().suffix(limit)) }
    }
}

/// Posts usage alerts through Notification Center. Permission is asked only
/// when the user turns alerts on in Settings.
@MainActor
final class UsageNotifier {
    /// `UNUserNotificationCenter` needs a real app bundle; `swift run` and
    /// tests have none, and asking would crash.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    func requestPermission() async -> Bool {
        guard Self.isAvailable else { return false }
        return await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    func post(_ alert: UsageAlert) {
        guard Self.isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: alert.key, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Log.usage.error("notification failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.orazz.myhub") {
            NSWorkspace.shared.open(url)
        }
    }
}
