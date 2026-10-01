import Foundation

/// `~/Library/Application Support/MyHub` and everything MyHub keeps there.
///
/// The folder is private to the user (0700) and every file written through
/// `writePrivate` is 0600: notes, preferences and (opt-in) clipboard history
/// are nobody else's business, even on a shared Mac.
enum AppPaths {
    static let folderName = "MyHub"

    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent(folderName, isDirectory: true)
        ensurePrivateDirectory(url)
        return url
    }()

    static func file(_ name: String) -> URL {
        support.appendingPathComponent(name, isDirectory: false)
    }

    /// A data file that was saved under an older name is renamed in place the
    /// first time it is asked for, so a rename in the app costs no user data.
    static func file(_ name: String, formerly oldName: String) -> URL {
        let url = file(name), old = file(oldName)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path), fm.fileExists(atPath: old.path) {
            try? fm.moveItem(at: old, to: url)
        }
        return url
    }

    static func directory(_ name: String) -> URL {
        let url = support.appendingPathComponent(name, isDirectory: true)
        ensurePrivateDirectory(url)
        return url
    }

    static func ensurePrivateDirectory(_ url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// Atomic write, then owner-only permissions. The rename happens inside a
    /// 0700 folder, so the moment between the two steps exposes nothing.
    static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
