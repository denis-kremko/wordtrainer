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
        var translation: String? = nil
    }

    struct LookupResult {
        // The normalized key the result answers: views compare it to the live
        // input instead of keeping their own copy in sync.
        var key: String
        var isCyrillic: Bool
        var exact: [Entry]
        var formMatches: [String]
        var prefixMatches: [String]
        var substringMatches: [String]
        var translationMatches: [String]
    }

    private let queue = DispatchQueue(label: "DictionaryService", qos: .userInitiated)
    private var db: OpaquePointer?
    private var hasFormsTable: Bool = false
    private var resolveCache: [String: String?] = [:]
    // Guarded by sourceLock, not the queue: view bodies read `isAvailable` on the
    // main thread, and queue.sync would block them behind any in-flight query
    // (the substring search is an unindexed LIKE scan).
    private let sourceLock = NSLock()
    private var _available = false

    var isAvailable: Bool {
        sourceLock.lock()
        defer { sourceLock.unlock() }
        return _available
    }

    private func setAvailable(_ available: Bool) {
        sourceLock.lock()
        _available = available
        sourceLock.unlock()
    }

    private init() { openBest() }

    deinit {
        if let db { sqlite3_close(db) }
    }

    func reload() async {
        await onQueue {
            self.closeLocked()
            self.openBestLocked()
        }
    }

    private func openBest() {
        queue.sync { openBestLocked() }
    }

    private func openBestLocked() {
        // Any installed file first — a stale one (SHA no longer matches
        // Info.plist, e.g. the app updated while offline) still beats the tiny
        // bundled demo; the schema probe in openLocked rejects files that
        // cannot serve the queries.
        let candidates = [DictionaryDownloader.installedURL,
                          Bundle.main.url(forResource: "dictionary", withExtension: "sqlite")]
        for url in candidates.compactMap({ $0 }) where openLocked(at: url) {
            setAvailable(true)
            return
        }
        setAvailable(false)
    }

    private func openLocked(at url: URL) -> Bool {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return false
        }
        db = handle
        // sqlite3_open is lazy: it blesses an HTML page or a truncated file.
        // One real row through the main-query JOIN proves the schema works
        // (word_lc also gates out pre-v13 downloads).
        let probe = "SELECT e.lemma, t.word_lc FROM entries e LEFT JOIN translations t ON t.id = e.id LIMIT 1"
        var stmt: OpaquePointer?
        let ok = sqlite3_prepare_v2(db, probe, -1, &stmt, nil) == SQLITE_OK
            && sqlite3_step(stmt) == SQLITE_ROW
        sqlite3_finalize(stmt)
        guard ok else {
            sqlite3_close(handle)
            db = nil
            return false
        }
        hasFormsTable = tableExistsLocked("forms")
        return true
    }

    private func closeLocked() {
        if let db { sqlite3_close(db) }
        db = nil
        hasFormsTable = false
        resolveCache = [:]
        setAvailable(false)
    }

    private func tableExistsLocked(_ name: String) -> Bool {
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name=? LIMIT 1"
        return !stringColumnLocked(sql, binds: [name]).isEmpty
    }

    // Shared prepare/bind/step scaffold for the single-text-column queries.
    private func stringColumnLocked(_ sql: String, binds: [String]) -> [String] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (i, bind) in binds.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), bind, -1, SQLITE_TRANSIENT)
        }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return out
    }

    func search(_ query: String) async -> LookupResult {
        let key = Self.normalize(query)
        let cyrillic = Self.hasCyrillic(key)
        let empty = LookupResult(key: key, isCyrillic: cyrillic,
                                 exact: [], formMatches: [], prefixMatches: [],
                                 substringMatches: [], translationMatches: [])
        guard !key.isEmpty else { return empty }
        let cancelled = CancelFlag()
        return await withTaskCancellationHandler {
            await onQueue {
                // Lemmas are ASCII and translations are Cyrillic, so each scan
                // runs only for the alphabet that can match it; the flag
                // re-checks free the serial queue for the successor sooner.
                guard !cancelled.isSet else { return empty }
                let exact = self.lookupLocked(key)
                let forms = exact.isEmpty ? self.formBasesLocked(for: key) : []
                var prefixes: [String] = [], subs: [String] = [], translations: [String] = []
                if cyrillic {
                    guard !cancelled.isSet else { return empty }
                    if key.count >= 2 { translations = self.translationMatchesLocked(for: key) }
                } else if key.count >= 3 {
                    guard !cancelled.isSet else { return empty }
                    prefixes = self.prefixMatchesLocked(for: key)
                    guard !cancelled.isSet else { return empty }
                    subs = self.substringMatchesLocked(for: key)
                }
                return LookupResult(key: key, isCyrillic: cyrillic,
                                    exact: exact, formMatches: forms, prefixMatches: prefixes,
                                    substringMatches: subs, translationMatches: translations)
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
        let sql = "SELECT e.id, e.pos, e.definition, e.example, t.word FROM entries e LEFT JOIN translations t ON t.id = e.id WHERE e.lemma = ? ORDER BY e.rank, e.id"
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
            let ru = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            out.append(Entry(id: id, partOfSpeech: pos, definition: def, example: ex,
                             translation: ru))
        }
        return out
    }

    private func formBasesLocked(for form: String) -> [String] {
        guard hasFormsTable else { return [] }
        return stringColumnLocked("SELECT DISTINCT lemma FROM forms WHERE form = ? LIMIT 8",
                                  binds: [form])
    }

    // Range scan instead of LIKE 'q%' so the lemma index is used; '{' is the
    // first character above 'z', past every character lemmas may contain.
    private func prefixMatchesLocked(for query: String) -> [String] {
        let sql = """
            SELECT DISTINCT lemma FROM entries
            WHERE lemma >= ? AND lemma < ? AND lemma != ?
            ORDER BY length(lemma), lemma LIMIT 8
        """
        return stringColumnLocked(sql, binds: [query, query + "{", query])
    }

    private func substringMatchesLocked(for query: String) -> [String] {
        let escaped = Self.likeEscaped(query)
        let sql = """
            SELECT DISTINCT lemma FROM entries
            WHERE lemma LIKE ? ESCAPE '\\' AND lemma LIKE '% %' AND lemma != ?
            ORDER BY length(lemma) LIMIT 12
        """
        return stringColumnLocked(sql, binds: ["%\(escaped)%", query])
    }

    // word_lc is the build-side case fold (SQLite LIKE folds only ASCII);
    // the normalized query is already lowercase, so two patterns cover
    // prefix and later-word matches in every case form.
    private func translationMatchesLocked(for query: String) -> [String] {
        let escaped = Self.likeEscaped(query)
        let sql = """
            SELECT e.lemma FROM translations t
            JOIN entries e ON e.id = t.id
            WHERE t.word_lc LIKE ? ESCAPE '\\' OR t.word_lc LIKE ? ESCAPE '\\'
            GROUP BY e.lemma
            ORDER BY MIN(t.word_lc != ?), MIN(e.rank), length(e.lemma), e.lemma
            LIMIT 12
        """
        return stringColumnLocked(sql, binds: ["\(escaped)%", "% \(escaped)%", query])
    }

    static func hasCyrillic(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }

    // User text can contain LIKE wildcards; escape so "a_e" stays literal.
    private static func likeEscaped(_ query: String) -> String {
        query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // token (lowercased) -> base lemma, for tappable words inside definitions.
    // Resolves direct lemmas first, then inflected forms (ran -> run).
    func resolveTokens(_ tokens: Set<String>) async -> [String: String] {
        await onQueue {
            var out: [String: String] = [:]
            for token in tokens {
                if let cached = self.resolveCache[token] {
                    if let lemma = cached { out[token] = lemma }
                    continue
                }
                let resolved = self.resolveTokenLocked(token)
                self.resolveCache[token] = resolved
                if let resolved { out[token] = resolved }
            }
            return out
        }
    }

    private func resolveTokenLocked(_ token: String) -> String? {
        var candidates = [token]
        if token.hasSuffix("'s") { candidates.append(String(token.dropLast(2))) }
        for candidate in candidates {
            if self.lemmaExistsLocked(candidate) { return candidate }
            if let base = self.formBasesLocked(for: candidate).first(where: { !$0.contains(" ") }) {
                return base
            }
        }
        return nil
    }

    private func lemmaExistsLocked(_ lemma: String) -> Bool {
        !stringColumnLocked("SELECT lemma FROM entries WHERE lemma = ? LIMIT 1", binds: [lemma]).isEmpty
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
        var lowered = s.lowercased().trimmed
        // The DB stores straight apostrophes and precomposed Cyrillic without
        // stress marks; iOS smart punctuation and pasted textbook text carry
        // U+2019 and U+0301, which LIKE compares by code point. All three
        // repairs are no-ops for pure-ASCII input — the dominant case, and
        // this runs per keystroke and per catalog word.
        if s.utf8.contains(where: { $0 >= 0x80 }) {
            lowered = lowered.straightApostrophes
            if lowered.unicodeScalars.contains(where: { $0.value == 0x0301 }) {
                lowered = String(String.UnicodeScalarView(
                    lowered.unicodeScalars.filter { $0.value != 0x0301 }))
            }
            lowered = lowered.precomposedStringWithCanonicalMapping
        }
        // The regex costs an NSRegularExpression per call; almost every input
        // is a single word or already single-spaced.
        guard lowered.contains("  ") || lowered.contains("\t") || lowered.contains("\n") else {
            return lowered
        }
        return lowered.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
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
