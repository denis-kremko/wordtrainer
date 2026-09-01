import Foundation

enum QuizMode: String {
    case definitionToEn
    case translationToEn

    var title: String {
        self == .definitionToEn ? "Definition → EN" : "Translation → EN"
    }
    var shortTitle: String {
        self == .definitionToEn ? "Def → EN" : "Tr → EN"
    }
    var promptLabel: String {
        self == .definitionToEn ? "Definition" : "Translation"
    }

    // What this mode asks about a sense; nil = the sense can't be asked.
    func prompt(for sense: WordSense) -> String? {
        switch self {
        case .definitionToEn: return sense.definition
        case .translationToEn: return sense.translation.flatMap { $0.nilIfEmpty }
        }
    }
}

struct QuizQuestion: Identifiable {
    let id = UUID()
    let lemma: String
    let sense: WordSense
    let prompt: String
    let hint: String

    var expectedAnswer: String { lemma }
}

struct QuizAnswer {
    let question: QuizQuestion
    let userAnswer: String
    let isCorrect: Bool
    let points: Int
}

// The expected answer flattened into letter slots (typed left-to-right) and
// pass-through separators, pre-arranged into one row per word.
struct AnswerSlots {
    struct Slot {
        let position: Int
        let character: Character
        let letterIndex: Int?   // nil = separator, shown as-is
    }

    let rows: [[Slot]]
    let letters: [Character]
    var letterCount: Int { letters.count }

    init(_ expected: String) {
        var rows: [[Slot]] = []
        var letters: [Character] = []
        var position = 0
        for word in expected.lowercased().split(separator: " ") {
            var row: [Slot] = []
            for character in word {
                if character.isLetter || character == "'" {
                    row.append(Slot(position: position, character: character, letterIndex: letters.count))
                    letters.append(character)
                } else {
                    row.append(Slot(position: position, character: character, letterIndex: nil))
                }
                position += 1
            }
            rows.append(row)
        }
        self.rows = rows
        self.letters = letters
    }

    // Hinted slots are pre-filled from the answer; the user's letters pour
    // into the remaining slots in order.
    func filledCharacters(typed: String, hinted: Set<Int>) -> [Character?] {
        var filled: [Character?] = []
        var typedIterator = typed.makeIterator()
        for index in 0..<letterCount {
            if hinted.contains(index) {
                filled.append(letters[index])
            } else {
                filled.append(typedIterator.next())
            }
        }
        return filled
    }

    func isFilled(typed: String, hinted: Set<Int>) -> Bool {
        typed.count + hinted.count >= letterCount && letterCount > 0
    }

    // Revealing a slot must not shift the letters the user already placed:
    // typed letters pour into non-hinted slots in order, so dropping exactly
    // the letter sitting in the newly revealed slot keeps every other letter
    // in its box.
    func typedAfterHint(_ typed: String, revealing slot: Int, hinted: Set<Int>) -> String {
        let nonHinted = (0..<letterCount).filter { !hinted.contains($0) }
        guard let occupied = nonHinted.firstIndex(of: slot), occupied < typed.count else { return typed }
        var characters = Array(typed)
        characters.remove(at: occupied)
        return String(characters)
    }

    func composite(typed: String, hinted: Set<Int>) -> String {
        let filled = filledCharacters(typed: typed, hinted: hinted)
        var out = ""
        var letterIndex = 0
        for (rowIndex, row) in rows.enumerated() {
            if rowIndex > 0 { out.append(" ") }
            for slot in row {
                if slot.letterIndex != nil {
                    if let char = filled[letterIndex] { out.append(char) }
                    letterIndex += 1
                } else {
                    out.append(slot.character)
                }
            }
        }
        return out
    }
}

enum QuizBuilder {

    // statusedKeys: SenseStats.key(lemma, definition) of senses with a
    // learned/knew status — the ones includeLearned pulls back into rotation
    // (manually excluded senses stay out either way).
    static func build(from words: [Word], sampleSize: Int?,
                      mode: QuizMode = .definitionToEn,
                      includeLearned: Bool = false,
                      statusedKeys: Set<String> = []) -> [QuizQuestion] {
        var questions: [QuizQuestion] = []

        for word in words.shuffled() {
            if let n = sampleSize, n > 0, questions.count >= n { break }

            let candidates = word.quizCandidates(mode: mode,
                                                 includeLearned: includeLearned,
                                                 statused: statusedKeys)
            guard let sense = candidates.randomElement(),
                  let prompt = mode.prompt(for: sense) else { continue }

            questions.append(QuizQuestion(
                lemma: word.lemma,
                sense: sense,
                prompt: prompt,
                // Custom senses carry an internal sentinel, not a real POS.
                hint: sense.isCustom ? "" : PartOfSpeech.displayName(sense.partOfSpeech,
                                                                     lemma: word.lemma)
            ))
        }

        return questions
    }

    // Scoring: plain-text recall earns maxPoints; switching to letter boxes
    // costs boxesCost; each hinted letter eats its share of the rest, so
    // revealing every letter is worth exactly nothing.
    static let maxPoints = 100
    static let boxesCost = 30

    static func points(isCorrect: Bool, usedBoxes: Bool,
                       hintedLetters: Int, totalLetters: Int) -> Int {
        guard isCorrect else { return 0 }
        guard usedBoxes else { return maxPoints }
        guard totalLetters > 0 else { return 0 }
        let share = 1 - Double(hintedLetters) / Double(totalLetters)
        return Int((Double(maxPoints - boxesCost) * share).rounded())
    }

    static func isCorrect(userAnswer: String, expected: String) -> Bool {
        func normalize(_ s: String) -> String {
            // iOS smart punctuation types curly apostrophes; the dictionary
            // stores straight ones.
            s.lowercased()
                .straightApostrophes
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmed
                .trimmingCharacters(in: .punctuationCharacters)
        }
        return normalize(userAnswer) == normalize(expected) && !expected.isEmpty
    }
}
