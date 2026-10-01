import Foundation

/// Incrementally reads append-only JSONL logs and keeps the parsed records.
///
/// Each file's byte offset is remembered, so a refresh reads only what was
/// appended since the last one — not gigabytes of history every time. A line
/// still being written (no trailing newline yet) is left for next time. A file
/// that shrank was rotated or rewritten and is read again from the start.
///
/// Records are keyed: a later line with the same key is `merge`d into the
/// earlier one (Claude Code logs one message across several lines as the
/// reply streams). Records older than the retention window are dropped, so
/// memory stays bounded however long the app runs.
///
/// An actor: all of this runs off the main thread, and the state is safe to
/// touch from whichever task refreshes.
actor LogLedger<Record: Sendable> {
    typealias Parser = @Sendable (_ line: Data, _ context: inout [String: String], _ file: String) -> (key: String, record: Record)?

    private struct Cursor {
        var offset: UInt64 = 0
        /// Per-file state a parser can carry between lines (e.g. the model
        /// named by an earlier line).
        var context: [String: String] = [:]
    }

    private let parse: Parser
    private let merge: @Sendable (Record, Record) -> Record
    private let timestamp: @Sendable (Record) -> Date
    private var cursors: [String: Cursor] = [:]
    private var records: [String: Record] = [:]

    static var chunkSize: Int { 4 * 1024 * 1024 }

    init(
        parse: @escaping Parser,
        merge: @escaping @Sendable (Record, Record) -> Record,
        timestamp: @escaping @Sendable (Record) -> Date
    ) {
        self.parse = parse
        self.merge = merge
        self.timestamp = timestamp
    }

    /// Reads new lines from every `.jsonl` under `roots` touched since
    /// `since`, and returns the records at or after `since`.
    func scan(roots: [URL], since: Date) -> [Record] {
        for file in Self.logFiles(under: roots, modifiedSince: since) {
            ingest(file)
        }
        let keepFrom = since.addingTimeInterval(-24 * 3600)
        records = records.filter { timestamp($0.value) >= keepFrom }
        return records.values.filter { timestamp($0) >= since }
    }

    private static func logFiles(under roots: [URL], modifiedSince: Date) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        var found: [URL] = []
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      (values.contentModificationDate ?? .distantPast) >= modifiedSince else { continue }
                found.append(url)
            }
        }
        return found
    }

    private func ingest(_ url: URL) {
        let path = url.path
        var cursor = cursors[path] ?? Cursor()
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(UInt64.init) else { return }
        if size < cursor.offset { cursor = Cursor() }
        guard size > cursor.offset, let handle = try? FileHandle(forReadingFrom: url) else {
            cursors[path] = cursor
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: cursor.offset)
            var carry = Data()
            while let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
                carry.append(chunk)
                guard let lastNewline = carry.lastIndex(of: 0x0A) else { continue }
                let complete = carry[carry.startIndex...lastNewline]
                for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
                    guard let (key, record) = parse(Data(line), &cursor.context, path) else { continue }
                    records[key] = records[key].map { merge($0, record) } ?? record
                }
                cursor.offset += UInt64(complete.count)
                carry = Data(carry[carry.index(after: lastNewline)...])
            }
        } catch {
            Log.usage.error("cannot read a log file: \(error.localizedDescription, privacy: .public)")
        }
        cursors[path] = cursor
    }
}
