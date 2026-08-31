import Foundation
import SQLite3

// Forces SQLite to copy bound strings; needed because Swift strings are transient.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class DictionaryService: @unchecked Sendable {
    static let shared = DictionaryService()

    struct Entry: Identifiable {
        let id: Int64
        let partOfSpeech: String
        let definition: String
        let example: String
    }

    struct LookupResult {
        var exact: [Entry]
        var formMatches: [String]
        var substringMatches: [String]

        var isEmpty: Bool { exact.isEmpty && formMatches.isEmpty && substringMatches.isEmpty }
    }

    enum Source { case none, bundle, downloaded }

    private let queue = DispatchQueue(label: "DictionaryService", qos: .userInitiated)
    private var db: OpaquePointer?
    private var hasFormsTable: Bool = false
    // Guarded by sourceLock, not the queue: view bodies read `isAvailable` on the
    // main thread, and queue.sync would block them behind any in-flight query
    // (the substring search is an unindexed LIKE scan).
    private let sourceLock = NSLock()
    private var _source: Source = .none

    var source: Source {
        sourceLock.lock()
        defer { sourceLock.unlock() }
        return _source
    }
    var isAvailable: Bool { source != .none }

    private func setSource(_ s: Source) {
        sourceLock.lock()
        _source = s
        sourceLock.unlock()
    }

    private init() { openBest() }

    deinit {
        if let db { sqlite3_close(db) }
    }

    func reload() {
        queue.sync {
            closeLocked()
            openBestLocked()
        }
    }

    private func openBest() {
        queue.sync { openBestLocked() }
    }

    private func openBestLocked() {
        if let downloaded = DictionaryDownloader.installedURL,
           FileManager.default.fileExists(atPath: downloaded.path),
           openLocked(at: downloaded) {
            setSource(.downloaded)
            return
        }
        if let bundled = Bundle.main.url(forResource: "dictionary", withExtension: "sqlite"),
           openLocked(at: bundled) {
            setSource(.bundle)
            return
        }
        setSource(.none)
    }

    private func openLocked(at url: URL) -> Bool {
        var handle: OpaquePointer?
        if sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK {
            db = handle
            hasFormsTable = tableExistsLocked("forms")
            return true
        } else {
            sqlite3_close(handle)
            return false
        }
    }

    private func closeLocked() {
        if let db { sqlite3_close(db) }
        db = nil
        hasFormsTable = false
        setSource(.none)
    }

    private func tableExistsLocked(_ name: String) -> Bool {
        guard let db else { return false }
        var stmt: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    func search(_ query: String) async -> LookupResult {
        let key = Self.normalize(query)
        let empty = LookupResult(exact: [], formMatches: [], substringMatches: [])
        guard !key.isEmpty else { return empty }
        let cancelled = CancelFlag()
        return await withTaskCancellationHandler {
            await onQueue {
                guard !cancelled.isSet else { return empty }
                let exact = self.lookupLocked(key)
                let forms = exact.isEmpty ? self.formBasesLocked(for: key) : []
                let subs = key.count >= 3 ? self.substringMatchesLocked(for: key, excluding: key) : []
                return LookupResult(exact: exact, formMatches: forms, substringMatches: subs)
            }
        } onCancel: {
            cancelled.set()
        }
    }

    private func onQueue<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    // Locked methods must not touch the queue-synced accessors:
    // queue.sync inside the queue deadlocks.
    private func lookupLocked(_ key: String) -> [Entry] {
        guard let db else { return [] }
        let sql = "SELECT id, pos, definition, example FROM entries WHERE lemma = ? ORDER BY id"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        var out: [Entry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let pos = String(cString: sqlite3_column_text(stmt, 1))
            let def = String(cString: sqlite3_column_text(stmt, 2))
            let ex = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            out.append(Entry(id: id, partOfSpeech: pos, definition: def, example: ex))
        }
        return out
    }

    private func formBasesLocked(for form: String) -> [String] {
        guard hasFormsTable, let db else { return [] }
        let sql = "SELECT DISTINCT lemma FROM forms WHERE form = ? LIMIT 8"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, form, -1, SQLITE_TRANSIENT)
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return out
    }

    private func substringMatchesLocked(for query: String, excluding exclude: String) -> [String] {
        guard let db else { return [] }
        let sql = """
            SELECT DISTINCT lemma FROM entries
            WHERE lemma LIKE ? AND lemma LIKE '% %' AND lemma != ?
            ORDER BY length(lemma) LIMIT 12
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, "%\(query)%", -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, exclude, -1, SQLITE_TRANSIENT)
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return out
    }

    func entriesByLemma(_ lemmas: [String]) async -> [String: [Entry]] {
        await onQueue {
            var out: [String: [Entry]] = [:]
            for lemma in lemmas {
                out[lemma] = self.lookupLocked(Self.normalize(lemma))
            }
            return out
        }
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
