import Darwin
import Foundation

/// A read-only look at this user's processes, through libproc — no shelling
/// out to `ps`, no permissions. Processes of other users are simply not
/// readable and are skipped.
enum ProcessScanner {
    struct Info: Sendable, Equatable {
        let pid: pid_t
        let parent: pid_t
        let name: String
        let path: String
    }

    /// Every readable process: one `proc_pidinfo` call each, which carries
    /// both the name and the parent. The executable path costs a second call
    /// and a 4 KB buffer per process, so it is left out here — this runs every
    /// few seconds over hundreds of processes.
    static func all() -> [Info] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard filled > 0 else { return [] }
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return pids.prefix(Int(filled)).compactMap { pid in
            guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return nil }
            return Info(pid: pid, parent: pid_t(bsd.pbi_ppid), name: name(of: bsd), path: "")
        }
    }

    /// One process, with its executable path.
    static func info(_ pid: pid_t) -> Info? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let parent = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size ? pid_t(bsd.pbi_ppid) : 0
        return Info(pid: pid, parent: parent, name: (path as NSString).lastPathComponent, path: path)
    }

    /// The process name from `proc_bsdinfo`: the 32-byte `pbi_name` when set,
    /// else the 16-byte `pbi_comm`. Long enough for every build tool MyHub
    /// looks for ("XCBBuildService", "swift-frontend").
    private static func name(of bsd: proc_bsdinfo) -> String {
        func string<T>(_ tuple: T) -> String {
            withUnsafeBytes(of: tuple) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
        let long = string(bsd.pbi_name)
        return long.isEmpty ? string(bsd.pbi_comm) : long
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    /// Names of `pid`'s ancestors, nearest first, up to `depth`.
    static func ancestors(of pid: pid_t, in table: [pid_t: Info], depth: Int = 6) -> [String] {
        var names: [String] = []
        var current = table[pid]?.parent ?? 0
        while current > 1, names.count < depth, let info = table[current] {
            names.append(info.name)
            current = info.parent
        }
        return names
    }
}
