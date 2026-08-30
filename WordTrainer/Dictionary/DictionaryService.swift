import Foundation
import SQLite3

// Forces SQLite to copy bound strings; needed because Swift strings are transient.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// Schema:
//   entries(id INTEGER PK, lemma TEXT, pos TEXT, definition TEXT, example TEXT)
//   forms(form TEXT, lemma TEXT)   -- optional
final class DictionaryService {
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
    private(set) var source: Source = .none

    var isAvailable: Bool { source != .none }

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
            source = .downloaded
            return
        }
        if let bundled = Bundle.main.url(forResource: "dictionary", withExtension: "sqlite"),
           openLocked(at: bundled) {
            source = .bundle
            return
        }
        source = .none
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
        source = .none
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

    func search(_ query: String) -> LookupResult {
        let key = normalize(query)
        guard !key.isEmpty else { return LookupResult(exact: [], formMatches: [], substringMatches: []) }
        return queue.sync {
            let exact = lookupLocked(key)
            let forms = exact.isEmpty ? formBasesLocked(for: key) : []
            let subs = key.count >= 3 ? substringMatchesLocked(for: key, excluding: key) : []
            return LookupResult(exact: exact, formMatches: forms, substringMatches: subs)
        }
    }

    func lookup(_ lemma: String) -> [Entry] {
        let key = normalize(lemma)
        guard !key.isEmpty else { return [] }
        return queue.sync { lookupLocked(key) }
    }

    private func lookupLocked(_ key: String) -> [Entry] {
        guard isAvailable, let db else { return [] }
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
        guard hasFormsTable, isAvailable, let db else { return [] }
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
        guard isAvailable, let db else { return [] }
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

    private func normalize(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
