import Foundation
import SwiftData

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isBlank: Bool { trimmed.isEmpty }

    var nilIfEmpty: String? { isEmpty ? nil : self }

    // iOS smart punctuation types curly apostrophes; the app stores and
    // compares straight ones.
    var straightApostrophes: String {
        replacingOccurrences(of: "\u{2019}", with: "'")
    }
}

enum Medal: Int, CaseIterable {
    case bronze
    case silver
    case gold

    var threshold: Int {
        switch self {
        case .bronze: return 70
        case .silver: return 85
        case .gold: return 100
        }
    }

    // Best-attempt percent against the group's CURRENT quizzable word count
    // (Word.isQuizzable), so editing the group re-grades every attempt:
    // deleting a word raises percents (capped at 100), adding one lowers them
    // and always takes gold away, and a paused word can't silently block gold.
    static func percent(points: Int, wordCount: Int) -> Int {
        wordCount > 0 ? min(100, points / wordCount) : 0
    }
}

enum LearnSettings {
    static let pointsToLearnKey = "pointsToLearn"
    static let pointsOptions = [200, 500, 1000, 1500, 2000]
    static let defaultPoints = 1000

    static var pointsToLearn: Int {
        let value = UserDefaults.standard.integer(forKey: pointsToLearnKey)
        return value == 0 ? defaultPoints : value
    }
}

extension SenseStats {
    // Auto-learn: reaching the points threshold marks the sense learned and
    // pulls every copy out of the quiz rotation. Learned exists ONLY through
    // points, so falling below the threshold (points reset, threshold raised)
    // always removes the mark. Knew is never touched.
    func applyAutoLearn(threshold: Int, in context: ModelContext) {
        if let enable = autoLearnTransition(threshold: threshold) {
            Self.setEnabled(enable, lemma: lemma, definition: definition, in: context)
        }
    }

    // The one none<->learned rule; returns the rotation membership the
    // sense's copies must take, nil when nothing changes.
    private func autoLearnTransition(threshold: Int) -> Bool? {
        if learnStatus == .none, points >= threshold {
            learnStatus = .learned
            return false
        }
        if learnStatus == .learned, points < threshold {
            learnStatus = .none
            return true
        }
        return nil
    }

    // Knew-already swipe: the status+enable pairing has one home.
    func markKnew(in context: ModelContext) {
        learnStatus = .knew
        Self.setEnabled(false, lemma: lemma, definition: definition, in: context)
    }

    // Reset points is the one way to un-learn: regardless of the auto-learn
    // toggle the mark goes away and the sense rejoins the rotation.
    func resetPoints(in context: ModelContext) {
        points = 0
        if learnStatus == .learned {
            learnStatus = .none
            Self.setEnabled(true, lemma: lemma, definition: definition, in: context)
        }
    }

    // Clearing a knew mark: the sense goes back into rotation everywhere.
    // Banked points reset too — points can pile up while statused (quizzes
    // with "Include learned words"), and keeping them would auto-learn the
    // sense on the very next save.
    func clearStatusManually(in context: ModelContext) {
        points = 0
        learnStatus = .none
        Self.setEnabled(true, lemma: lemma, definition: definition, in: context)
    }

    static func recomputeAutoLearned(threshold: Int, in context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<SenseStats>())) ?? []
        guard !all.isEmpty else { return }
        // One pass over every sense; a fetch per transitioning row would be a
        // full unindexed scan each, synchronously on the main thread.
        let senses = (try? context.fetch(FetchDescriptor<WordSense>())) ?? []
        var copies: [String: [WordSense]] = [:]
        for sense in senses {
            guard let lemma = sense.word?.lemma else { continue }
            copies[key(lemma, sense.definition), default: []].append(sense)
        }
        for stats in all {
            if let enable = stats.autoLearnTransition(threshold: threshold) {
                for sense in copies[key(stats.lemma, stats.definition)] ?? [] {
                    sense.isEnabled = enable
                }
            }
        }
    }

    // The status is global per (lemma, definition): every copy of the sense
    // across groups leaves or rejoins the quiz rotation together.
    static func setEnabled(_ enabled: Bool, lemma: String, definition: String,
                           in context: ModelContext) {
        let matches = (try? context.fetch(FetchDescriptor<WordSense>(
            predicate: #Predicate { $0.definition == definition }))) ?? []
        for sense in matches where sense.word?.lemma == lemma {
            sense.isEnabled = enabled
        }
    }

    // The one definition of "has progress", shared by every @Query.
    static let statusedPredicate = #Predicate<SenseStats> { $0.status != "" }

    // Set-membership key carrying the full stats identity.
    static func key(_ lemma: String, _ definition: String) -> String {
        lemma + "\u{1}" + definition
    }

    static func statusKeys(_ stats: [SenseStats]) -> Set<String> {
        Set(stats.map { key($0.lemma, $0.definition) })
    }
}

extension WordGroup {
    // Sessions link by a groupID snapshot (deliberately no SwiftData
    // relationship), so the history cascade is spelled out here, where that
    // convention lives.
    func deleteWithHistory(in context: ModelContext) {
        let id = id.uuidString
        let sessions = (try? context.fetch(FetchDescriptor<QuizSession>(
            predicate: #Predicate { $0.groupID == id }))) ?? []
        for session in sessions {
            context.delete(session)
        }
        context.delete(self)
    }

    // The one smart-add rule: the same lemma always merges into the existing
    // word instead of creating a duplicate row.
    func findOrCreateWord(lemma rawLemma: String, in context: ModelContext) -> Word {
        let lemma = DictionaryService.normalize(rawLemma)
        if let existing = words.first(where: { $0.lemma == lemma }) {
            return existing
        }
        let word = Word(lemma: lemma)
        context.insert(word)
        word.group = self
        return word
    }
}

extension Word {
    // Take over a duplicate word's senses (move): reparent the ones this word
    // lacks, let the donor's cascade delete swallow the identical rest.
    func absorb(_ donor: Word, in context: ModelContext) {
        var seen = Set(senses.map { $0.definition })
        var order = (senses.map { $0.order }.max() ?? -1) + 1
        for sense in donor.senses.sorted(by: { $0.order < $1.order })
        where seen.insert(sense.definition).inserted {
            sense.order = order
            sense.word = self
            order += 1
        }
        context.delete(donor)
    }

    // Copy another word's senses (the source word stays where it is),
    // skipping definitions this word already has.
    func cloneSenses(from source: Word, in context: ModelContext) {
        var seen = Set(senses.map { $0.definition })
        var order = (senses.map { $0.order }.max() ?? -1) + 1
        for sense in source.senses.sorted(by: { $0.order < $1.order })
        where seen.insert(sense.definition).inserted {
            let clone = WordSense(partOfSpeech: sense.partOfSpeech,
                                  definition: sense.definition,
                                  example: sense.example,
                                  translation: sense.translation,
                                  isEnabled: sense.isEnabled,
                                  isCustom: sense.isCustom,
                                  order: order)
            context.insert(clone)
            clone.word = self
            order += 1
        }
    }

    func isLearned(byStatused done: Set<String>) -> Bool {
        !senses.isEmpty && senses.allSatisfy { done.contains(SenseStats.key(lemma, $0.definition)) }
    }

    // The one rotation rule: a sense can be quizzed iff it is enabled (or
    // statused and explicitly invited back via "Include learned words") and
    // it can produce a prompt for the chosen mode.
    func quizCandidates(mode: QuizMode = .definitionToEn,
                        includeLearned: Bool, statused done: Set<String>) -> [WordSense] {
        senses.filter { sense in
            guard sense.isEnabled
                    || (includeLearned && done.contains(SenseStats.key(lemma, sense.definition)))
            else { return false }
            return mode.prompt(for: sense) != nil
        }
    }

    // A word can produce a quiz question iff some sense is enabled or statused
    // (statused senses rejoin via "Include learned words"). Zero-sense and
    // fully manually-disabled words can't score, so medals grade against the rest.
    func isQuizzable(byStatused done: Set<String>) -> Bool {
        !quizCandidates(includeLearned: true, statused: done).isEmpty
    }
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
    // UUID into old rows.
    var id: UUID = UUID()
    var name: String
    var groupDescription: String
    var createdAt: Date

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

    var group: WordGroup?

    @Relationship(deleteRule: .cascade, inverse: \WordSense.word)
    var senses: [WordSense] = []

    init(lemma: String) {
        self.id = UUID()
        // Enforced here so every status/enable comparison downstream can use
        // raw equality; callers must not be trusted to pre-normalize.
        self.lemma = DictionaryService.normalize(lemma)
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
    var translation: String = ""
    var createdAt: Date = Date()

    init(lemma: String, definition: String, example: String = "", translation: String = "") {
        self.id = UUID()
        self.lemma = lemma
        self.definition = definition
        self.example = example
        self.translation = translation
        self.createdAt = Date()
    }
}

extension CustomSense {
    /// Single home for the dedup rule (one row per lemma+definition), shared by
    /// WordLookupView and WordDetailView. A non-empty new example updates the
    /// stored one instead of being silently discarded.
    @discardableResult
    static func findOrInsert(lemma rawLemma: String, definition: String, example: String,
                             translation: String = "", in context: ModelContext) -> CustomSense {
        let lemma = DictionaryService.normalize(rawLemma)
        let match = #Predicate<CustomSense> { $0.lemma == lemma && $0.definition == definition }
        if let existing = context.first(matching: match) {
            // Callers pass the full intended state, so clearing a field must
            // stick too — not just non-empty updates.
            if existing.example != example {
                existing.example = example
            }
            if existing.translation != translation {
                existing.translation = translation
            }
            return existing
        }
        let sense = CustomSense(lemma: lemma, definition: definition, example: example,
                                translation: translation)
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
    var translation: String? = nil
    var isEnabled: Bool = true
    var isCustom: Bool = false
    var order: Int = 0

    var word: Word?

    static let customPartOfSpeech = "custom"

    init(partOfSpeech: String, definition: String, example: String = "",
         translation: String? = nil, isEnabled: Bool = true, isCustom: Bool = false,
         order: Int = 0) {
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
                  example: entry.example, translation: entry.translation,
                  isEnabled: isEnabled, order: order)
    }

    convenience init(custom: CustomSense, order: Int) {
        self.init(partOfSpeech: WordSense.customPartOfSpeech, definition: custom.definition,
                  example: custom.example, translation: custom.translation.nilIfEmpty,
                  isCustom: true, order: order)
    }
}

extension Word {
    // Single home for turning dictionary entries and custom senses into
    // WordSense rows, owning the running order counter. One WordSense per
    // definition text — the identity quizzes and SenseStats key on — so
    // anything the word already has, or this batch already added (e.g. a
    // dictionary entry plus its unedited "Save to custom" copy), is skipped.
    func appendSenses(entries: [DictionaryService.Entry],
                      customs: [CustomSense],
                      in context: ModelContext,
                      statusedKeys: Set<String>? = nil) {
        var seen = Set(senses.map { $0.definition })
        var order = (senses.map { $0.order }.max() ?? -1) + 1
        // Batch imports pass the statused keys once instead of paying a
        // SenseStats fetch per word.
        let isStatused: (String) -> Bool
        if let statusedKeys {
            let lemma = self.lemma
            isStatused = { statusedKeys.contains(SenseStats.key(lemma, $0)) }
        } else {
            let fetched = statusedDefinitions(in: context)
            isStatused = { fetched.contains($0) }
        }
        for entry in entries {
            guard seen.insert(entry.definition).inserted else { continue }
            let sense = WordSense(entry: entry,
                                  isEnabled: !isStatused(entry.definition),
                                  order: order)
            context.insert(sense)
            sense.word = self
            order += 1
        }
        for custom in customs {
            guard seen.insert(custom.definition).inserted else {
                // An edited "Save to custom" copy of a checked dictionary
                // sense keeps the dictionary row (real POS) but its fresher
                // translation/example must not be silently dropped.
                refreshExisting(definition: custom.definition,
                                translation: custom.translation.nilIfEmpty,
                                example: custom.example)
                continue
            }
            let sense = WordSense(custom: custom, order: order)
            sense.isEnabled = !isStatused(custom.definition)
            context.insert(sense)
            sense.word = self
            order += 1
        }
    }

    // A re-added duplicate can still carry fresher details.
    private func refreshExisting(definition: String, translation: String?, example: String) {
        guard let sense = senses.first(where: { $0.definition == definition }) else { return }
        if let translation, sense.translation != translation {
            sense.translation = translation
        }
        if !example.isEmpty, sense.example != example {
            sense.example = example
        }
    }

    // Definitions of this lemma that already carry a learned/knew status:
    // their fresh copies must not rejoin the quiz rotation.
    private func statusedDefinitions(in context: ModelContext) -> Set<String> {
        let lemma = self.lemma
        let rows = (try? context.fetch(FetchDescriptor<SenseStats>(
            predicate: #Predicate { $0.lemma == lemma && $0.status != "" }))) ?? []
        return Set(rows.map { $0.definition })
    }
}

// Global per-definition quiz counters, shared across groups: the identity is
// (lemma, definition text), the same for dictionary and custom senses.
enum LearnStatus: String {
    case none = ""
    case learned
    case knew
}

@Model
final class SenseStats {
    var lemma: String = ""
    var definition: String = ""
    var points: Int = 0
    var status: String = ""

    var learnStatus: LearnStatus {
        get { LearnStatus(rawValue: status) ?? .none }
        set { status = newValue.rawValue }
    }

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
    var groupID: String = ""      // WordGroup.id.uuidString
    var totalCount: Int = 0
    var correctCount: Int = 0
    var points: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \QuizResult.session)
    var results: [QuizResult] = []

    // Score = earned points against the plain-text maximum per question.
    var scorePercent: Int {
        totalCount > 0 ? 100 * points / (totalCount * QuizBuilder.maxPoints) : 0
    }

    init(mode: String, groupName: String, groupID: String,
         totalCount: Int, correctCount: Int, points: Int) {
        self.date = Date()
        self.mode = mode
        self.groupName = groupName
        self.groupID = groupID
        self.totalCount = totalCount
        self.correctCount = correctCount
        self.points = points
    }
}

@Model
final class QuizResult {
    var order: Int = 0
    var lemma: String = ""
    var senseDefinition: String = ""
    var userAnswer: String = ""
    var isCorrect: Bool = false

    var session: QuizSession?

    init(order: Int, lemma: String, senseDefinition: String,
         userAnswer: String, isCorrect: Bool) {
        self.order = order
        self.lemma = lemma
        self.senseDefinition = senseDefinition
        self.userAnswer = userAnswer
        self.isCorrect = isCorrect
    }
}
