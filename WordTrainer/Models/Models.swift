import Foundation
import SwiftData

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

@Model
final class WordGroup {
    var name: String
    var groupDescription: String
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Word.group)
    var words: [Word] = []

    init(name: String, groupDescription: String = "") {
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
    var timesSeen: Int
    var timesCorrect: Int

    var group: WordGroup?

    @Relationship(deleteRule: .cascade, inverse: \WordSense.word)
    var senses: [WordSense] = []

    init(lemma: String) {
        self.id = UUID()
        self.lemma = lemma
        self.createdAt = Date()
        self.timesSeen = 0
        self.timesCorrect = 0
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
