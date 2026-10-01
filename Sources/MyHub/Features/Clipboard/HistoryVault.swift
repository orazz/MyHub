import CryptoKit
import Foundation

/// Opt-in persistence for clipboard history, encrypted at rest.
///
/// Copied text is where passwords, tokens and addresses pass through, so it
/// never lands on disk in the clear. The file is AES-GCM sealed with a 256-bit
/// key that lives only in the Keychain (this device only). Deleting the key
/// makes the file unreadable noise; turning persistence off deletes both.
///
/// Everything here is nonisolated and works on `Sendable` values, so it can
/// run on a background task.
enum HistoryVault {
    static let keyAccount = "clipboard-history-key"
    static var file: URL { AppPaths.file("clipboard.sealed") }

    enum Failure: Error { case badKey }

    static func seal(_ history: ClipHistory, with key: SymmetricKey) throws -> Data {
        let plain = try JSONEncoder().encode(history)
        guard let combined = try AES.GCM.seal(plain, using: key).combined else { throw Failure.badKey }
        return combined
    }

    static func open(_ data: Data, with key: SymmetricKey) throws -> ClipHistory {
        let box = try AES.GCM.SealedBox(combined: data)
        return try JSONDecoder().decode(ClipHistory.self, from: AES.GCM.open(box, using: key))
    }

    /// The key, created on first use.
    static func key(creating: Bool) throws -> SymmetricKey? {
        if let stored = try Keychain.secret(account: keyAccount),
           let raw = Data(base64Encoded: stored.exposed), raw.count == 32 {
            return SymmetricKey(data: raw)
        }
        guard creating else { return nil }
        let key = SymmetricKey(size: .bits256)
        let encoded = key.withUnsafeBytes { Data($0).base64EncodedString() }
        try Keychain.store(Redacted(encoded), account: keyAccount)
        return key
    }

    static func write(_ history: ClipHistory) {
        do {
            guard let key = try key(creating: true) else { return }
            try AppPaths.writePrivate(try seal(history, with: key), to: file)
        } catch {
            Log.storage.error("cannot save clipboard history: \(String(describing: error), privacy: .public)")
        }
    }

    static func read() -> ClipHistory? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        do {
            guard let key = try key(creating: false) else { return nil }
            return try open(data, with: key)
        } catch {
            Log.storage.error("cannot open clipboard history: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    static func erase() {
        try? FileManager.default.removeItem(at: file)
        try? Keychain.remove(account: keyAccount)
    }
}
