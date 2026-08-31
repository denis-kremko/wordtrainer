import Foundation
import SwiftData

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

extension ModelContext {
    // Shared fetch-or-insert core: the first row matching the predicate, if any.
    func first<T: PersistentModel>(matching predicate: Predicate<T>) -> T? {
        var descriptor = FetchDescriptor<T>(predicate: predicate)
        descriptor.fetchLimit = 1
        return (try? fetch(descriptor))?.first
    }
}

@Model
final class WordGroup {
    // Stable identity for quiz-session linkage: names are neither unique nor
    // rename-proof. Not @Attribute(.unique) — migration backfills one shared
    // UUID into old rows; launch repair de-duplicates instead.
    var id: UUID = UUID()
    var name: String
    var groupDescription: String
    var createdAt: Date
    var sourceReadyGroupID: String? = nil

    @Relationship(deleteRule: .cascade, inverse: \Word.group)
    var words: [Word] = []

    init(name: String, groupDescription: String = "") {
        self.id = UUID()
        self.name = name
        self.groupDescription = groupDescription
        self.createdAt = Date()
    }
}

@Model
final class Word {
    @Attribute(.unique) var id: UUID
    var lemma: String
    var createdAt: Date

    var group: WordGroup?

    @Relationship(deleteRule: .cascade, inverse: \WordSense.word)
    var senses: [WordSense] = []

    init(lemma: String) {
        self.id = UUID()
        self.lemma = lemma
        self.createdAt = Date()
    }
}

@Model
final class CustomSense {
    // Selection key: persistentModelID changes on autosave, and .unique here
    // crashes migration (old rows are backfilled with one shared UUID).
    var id: UUID = UUID()
    var lemma: String = ""          // lowercased, trimmed
    var definition: String = ""
    var example: String = ""
    var createdAt: Date = Date()

    init(lemma: String, definition: String, example: String = "") {
        self.id = UUID()
        self.lemma = lemma
        self.definition = definition
        self.example = example
        self.createdAt = Date()
    }
}

extension CustomSense {
    /// Single home for the dedup rule (one row per lemma+definition), shared by
    /// WordLookupView and WordDetailView. A non-empty new example updates the
    /// stored one instead of being silently discarded.
    @discardableResult
    static func findOrInsert(lemma rawLemma: String, definition: String, example: String,
                             in context: ModelContext) -> CustomSense {
        let lemma = DictionaryService.normalize(rawLemma)
        let match = #Predicate<CustomSense> { $0.lemma == lemma && $0.definition == definition }
        if let existing = context.first(matching: match) {
            if !example.isEmpty && existing.example != example {
                existing.example = example
            }
            return existing
        }
        let sense = CustomSense(lemma: lemma, definition: definition, example: example)
        context.insert(sense)
        return sense
    }
}

enum PartOfSpeech {
    // Only tags the capitalize-first-letter fallback cannot derive.
    private static let names: [String: String] = [
        "adj": "Adjective", "adv": "Adverb", "prep_phrase": "Prepositional phrase",
        "intj": "Interjection", "prep": "Preposition", "pron": "Pronoun",
        "conj": "Conjunction", "det": "Determiner", "postp": "Postposition",
    ]

    static func displayName(_ raw: String, lemma: String = "") -> String {
        let key = raw.lowercased()
        if key == "verb", lemma.contains(" ") { return "Phrasal verb" }
        if let name = names[key] { return name }
        guard let first = raw.first else { return raw }
        return first.uppercased() + raw.dropFirst()
    }
}

@Model
final class WordSense {
    var partOfSpeech: String = "custom"
    var definition: String = ""
    var example: String = ""
    var translation: String = ""
    var isEnabled: Bool = true
    var isCustom: Bool = false
    var order: Int = 0

    var word: Word?

    static let customPartOfSpeech = "custom"

    init(partOfSpeech: String, definition: String, example: String = "", translation: String = "", isEnabled: Bool = true, isCustom: Bool = false, order: Int = 0) {
        self.partOfSpeech = partOfSpeech
        self.definition = definition
        self.example = example
        self.translation = translation
        self.isEnabled = isEnabled
        self.isCustom = isCustom
        self.order = order
    }
}

extension WordSense {
    convenience init(entry: DictionaryService.Entry, isEnabled: Bool = true, order: Int) {
        self.init(partOfSpeech: entry.partOfSpeech, definition: entry.definition,
                  example: entry.example, isEnabled: isEnabled, order: order)
    }

    convenience init(custom: CustomSense, order: Int) {
        self.init(partOfSpeech: WordSense.customPartOfSpeech, definition: custom.definition,
                  example: custom.example, isCustom: true, order: order)
    }
}

extension Word {
    // Single home for turning dictionary entries and custom senses into
    // WordSense rows, owning the running order counter. One WordSense per
    // definition text — the identity quizzes and SenseStats key on — so
    // anything the word already has, or this batch already added (e.g. a
    // dictionary entry plus its unedited "Save to custom" copy), is skipped.
    func appendSenses(entries: [(entry: DictionaryService.Entry, isEnabled: Bool)],
                      customs: [CustomSense],
                      in context: ModelContext) {
        var seen = Set(senses.map { $0.definition })
        var order = (senses.map { $0.order }.max() ?? -1) + 1
        for (entry, isEnabled) in entries {
            guard seen.insert(entry.definition).inserted else { continue }
            let sense = WordSense(entry: entry, isEnabled: isEnabled, order: order)
            context.insert(sense)
            sense.word = self
            order += 1
        }
        for custom in customs {
            guard seen.insert(custom.definition).inserted else { continue }
            let sense = WordSense(custom: custom, order: order)
            context.insert(sense)
            sense.word = self
            order += 1
        }
    }
}

// Global per-definition quiz counters, shared across groups: the identity is
// (lemma, definition text), the same for dictionary and custom senses.
@Model
final class SenseStats {
    var lemma: String = ""
    var definition: String = ""
    var timesSeen: Int = 0
    var timesCorrect: Int = 0

    init(lemma: String, definition: String) {
        self.lemma = lemma
        self.definition = definition
    }
}

extension SenseStats {
    @discardableResult
    static func findOrInsert(lemma rawLemma: String, definition: String,
                             in context: ModelContext) -> SenseStats {
        let lemma = DictionaryService.normalize(rawLemma)
        let match = #Predicate<SenseStats> { $0.lemma == lemma && $0.definition == definition }
        if let existing = context.first(matching: match) {
            return existing
        }
        let stats = SenseStats(lemma: lemma, definition: definition)
        context.insert(stats)
        return stats
    }

    // One row per definition of a lemma, from an already-fetched (e.g. @Query)
    // list — so views stay live when a quiz inserts new rows.
    static func byDefinition(_ all: [SenseStats], lemma rawLemma: String) -> [String: SenseStats] {
        let lemma = DictionaryService.normalize(rawLemma)
        return Dictionary(all.filter { $0.lemma == lemma }.map { ($0.definition, $0) },
                          uniquingKeysWith: { a, _ in a })
    }
}

// A completed quiz run the user chose to keep. Results snapshot their content
// so history survives deletion of words, senses, and groups.
@Model
final class QuizSession {
    var date: Date = Date()
    var mode: String = ""
    var groupName: String = ""
    var groupID: String = ""      // WordGroup.id.uuidString; "" on legacy rows
    var totalCount: Int = 0
    var correctCount: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \QuizResult.session)
    var results: [QuizResult] = []

    init(mode: String, groupName: String, groupID: String, totalCount: Int, correctCount: Int) {
        self.date = Date()
        self.mode = mode
        self.groupName = groupName
        self.groupID = groupID
        self.totalCount = totalCount
        self.correctCount = correctCount
    }
}

@Model
final class QuizResult {
    var order: Int = 0
    var lemma: String = ""
    var senseDefinition: String = ""
    var prompt: String = ""
    var expected: String = ""
    var userAnswer: String = ""
    var isCorrect: Bool = false

    var session: QuizSession?

    init(order: Int, lemma: String, senseDefinition: String, prompt: String, expected: String,
         userAnswer: String, isCorrect: Bool) {
        self.order = order
        self.lemma = lemma
        self.senseDefinition = senseDefinition
        self.prompt = prompt
        self.expected = expected
        self.userAnswer = userAnswer
        self.isCorrect = isCorrect
    }
}
