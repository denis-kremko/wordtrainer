import Foundation

enum QuizMode: String, CaseIterable, Identifiable {
    case enToTranslation
    case translationToEn
    case definitionToEn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .enToTranslation: return "EN → translation (self-check)"
        case .translationToEn: return "Translation → EN"
        case .definitionToEn:  return "Definition → EN"
        }
    }

    var shortTitle: String {
        switch self {
        case .enToTranslation: return "EN → translation"
        case .translationToEn: return "Translation → EN"
        case .definitionToEn:  return "Def → EN"
        }
    }

    var promptLabel: String {
        switch self {
        case .enToTranslation: return "Word"
        case .translationToEn: return "Translation"
        case .definitionToEn:  return "Definition"
        }
    }
}

struct QuizQuestion: Identifiable {
    let id = UUID()
    let wordID: UUID
    let prompt: String
    let expectedAnswer: String
    let hint: String
}

struct QuizAnswer {
    let question: QuizQuestion
    let userAnswer: String
    let isCorrect: Bool
}

enum QuizBuilder {

    static func build(from words: [Word], mode: QuizMode, sampleSize: Int?) -> [QuizQuestion] {
        var questions: [QuizQuestion] = []

        for word in words.shuffled() {
            if let n = sampleSize, n > 0, questions.count >= n { break }

            let enabledSenses = word.senses.filter { $0.isEnabled }
            let candidates = mode == .translationToEn
                ? enabledSenses.filter { !$0.translation.isEmpty }
                : enabledSenses
            guard let sense = candidates.randomElement() else { continue }

            let (prompt, expected): (String, String)
            switch mode {
            case .enToTranslation:
                (prompt, expected) = (word.lemma, sense.translation.isEmpty ? sense.definition : sense.translation)
            case .translationToEn:
                (prompt, expected) = (sense.translation, word.lemma)
            case .definitionToEn:
                (prompt, expected) = (sense.definition, word.lemma)
            }

            questions.append(QuizQuestion(
                wordID: word.id,
                prompt: prompt,
                expectedAnswer: expected,
                hint: sense.partOfSpeech
            ))
        }

        return questions
    }

    static func isCorrect(userAnswer: String, expected: String) -> Bool {
        func normalize(_ s: String) -> String {
            s.lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: .punctuationCharacters)
        }
        return normalize(userAnswer) == normalize(expected) && !expected.isEmpty
    }
}
