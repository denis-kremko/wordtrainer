import XCTest
import SwiftData
@testable import WordAce

@MainActor
final class AutoLearnTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let schema = Schema([
            WordGroup.self, Word.self, WordSense.self, CustomSense.self,
            QuizSession.self, QuizResult.self, SenseStats.self,
        ])
        container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    private func entry(_ id: Int64, _ definition: String) -> DictionaryService.Entry {
        DictionaryService.Entry(id: id, partOfSpeech: "noun", definition: definition, example: "")
    }

    @discardableResult
    private func wordInGroup(_ groupName: String, lemma: String, definition: String) -> Word {
        let group = WordGroup(name: groupName)
        context.insert(group)
        let word = group.findOrCreateWord(lemma: lemma, in: context)
        word.appendSenses(entries: [entry(Int64(definition.count), definition)],
                          customs: [], in: context)
        return word
    }

    private func stats(_ lemma: String, _ definition: String,
                       points: Int, status: LearnStatus = .none) -> SenseStats {
        let stats = SenseStats.findOrInsert(lemma: lemma, definition: definition, in: context)
        stats.points = points
        stats.learnStatus = status
        return stats
    }

    // MARK: - Points thresholds

    func testCrossingThresholdLearnsAndDisablesEveryCopy() throws {
        let first = wordInGroup("a", lemma: "run", definition: "To move fast.")
        let second = wordInGroup("b", lemma: "run", definition: "To move fast.")

        let row = stats("run", "To move fast.", points: 1000)
        row.applyAutoLearn(threshold: 1000, in: context)
        try context.save()

        XCTAssertEqual(row.learnStatus, .learned)
        XCTAssertFalse(first.senses[0].isEnabled)
        XCTAssertFalse(second.senses[0].isEnabled)
    }

    func testBelowThresholdDoesNothing() throws {
        let word = wordInGroup("a", lemma: "run", definition: "To move fast.")
        let row = stats("run", "To move fast.", points: 999)
        row.applyAutoLearn(threshold: 1000, in: context)

        XCTAssertEqual(row.learnStatus, .none)
        XCTAssertTrue(word.senses[0].isEnabled)
    }

    func testRaisingThresholdUnlearns() throws {
        let word = wordInGroup("a", lemma: "run", definition: "To move fast.")
        word.senses[0].isEnabled = false
        stats("run", "To move fast.", points: 500, status: .learned)

        SenseStats.recomputeAutoLearned(threshold: 1000, in: context)
        try context.save()

        let row = try context.fetch(FetchDescriptor<SenseStats>())[0]
        XCTAssertEqual(row.learnStatus, .none)
        XCTAssertTrue(word.senses[0].isEnabled)
    }

    func testLoweringThresholdLearnsQualifiedRows() throws {
        let word = wordInGroup("a", lemma: "run", definition: "To move fast.")
        stats("run", "To move fast.", points: 400)

        SenseStats.recomputeAutoLearned(threshold: 200, in: context)
        try context.save()

        let row = try context.fetch(FetchDescriptor<SenseStats>())[0]
        XCTAssertEqual(row.learnStatus, .learned)
        XCTAssertFalse(word.senses[0].isEnabled)
    }

    func testKnewStatusIsNeverTouched() throws {
        stats("run", "To move fast.", points: 5000, status: .knew)
        SenseStats.recomputeAutoLearned(threshold: 200, in: context)

        let row = try context.fetch(FetchDescriptor<SenseStats>())[0]
        XCTAssertEqual(row.learnStatus, .knew)
    }

    // MARK: - Reset points

    func testResetPointsUnlearnsAndReenables() throws {
        let word = wordInGroup("a", lemma: "run", definition: "To move fast.")
        word.senses[0].isEnabled = false
        let row = stats("run", "To move fast.", points: 1200, status: .learned)

        row.resetPoints(in: context)
        try context.save()

        XCTAssertEqual(row.points, 0)
        XCTAssertEqual(row.learnStatus, .none)
        XCTAssertTrue(word.senses[0].isEnabled)
    }

    func testResetPointsOnKnewKeepsKnew() throws {
        let row = stats("run", "To move fast.", points: 300, status: .knew)
        row.resetPoints(in: context)

        XCTAssertEqual(row.points, 0)
        XCTAssertEqual(row.learnStatus, .knew)
    }

    func testClearingKnewResetsBankedPoints() throws {
        // Points can pile past the threshold while knew (include-learned
        // quizzes); un-knewing must not auto-learn on the next save.
        let row = stats("run", "To move fast.", points: 1500, status: .knew)
        row.clearStatusManually(in: context)

        XCTAssertEqual(row.points, 0)
        XCTAssertEqual(row.learnStatus, .none)
        row.applyAutoLearn(threshold: 1000, in: context)
        XCTAssertEqual(row.learnStatus, .none)
    }

    func testIsCorrectCollapsesInternalWhitespace() {
        XCTAssertTrue(QuizBuilder.isCorrect(userAnswer: "give up", expected: "give  up"))
    }

    // MARK: - Scoring

    func testScoringPlaintext() {
        XCTAssertEqual(QuizBuilder.points(isCorrect: true, usedBoxes: false,
                                          hintedLetters: 0, totalLetters: 0), 100)
        XCTAssertEqual(QuizBuilder.points(isCorrect: false, usedBoxes: false,
                                          hintedLetters: 0, totalLetters: 0), 0)
    }

    func testScoringBoxes() {
        XCTAssertEqual(QuizBuilder.points(isCorrect: true, usedBoxes: true,
                                          hintedLetters: 0, totalLetters: 10), 70)
        // 2 of 10 letters hinted: 70 * 0.8 = 56.
        XCTAssertEqual(QuizBuilder.points(isCorrect: true, usedBoxes: true,
                                          hintedLetters: 2, totalLetters: 10), 56)
        // Every letter revealed is worth nothing.
        XCTAssertEqual(QuizBuilder.points(isCorrect: true, usedBoxes: true,
                                          hintedLetters: 10, totalLetters: 10), 0)
        XCTAssertEqual(QuizBuilder.points(isCorrect: false, usedBoxes: true,
                                          hintedLetters: 0, totalLetters: 10), 0)
    }

    // MARK: - AnswerSlots (letter-boxes quiz)

    func testAnswerSlotsSingleWord() {
        let slots = AnswerSlots("run")
        XCTAssertEqual(slots.letterCount, 3)
        XCTAssertEqual(slots.rows.count, 1)
        XCTAssertFalse(slots.isFilled(typed: "ru", hinted: []))
        XCTAssertTrue(slots.isFilled(typed: "run", hinted: []))
        XCTAssertEqual(slots.composite(typed: "run", hinted: []), "run")
    }

    func testAnswerSlotsPhrasalVerbAndSeparators() {
        let slots = AnswerSlots("come up with")
        XCTAssertEqual(slots.rows.count, 3)
        XCTAssertEqual(slots.letterCount, 10)
        XCTAssertEqual(slots.composite(typed: "comeupwith", hinted: []), "come up with")

        let hyphen = AnswerSlots("self-esteem")
        XCTAssertEqual(hyphen.letterCount, 10)
        XCTAssertEqual(hyphen.composite(typed: "selfesteem", hinted: []), "self-esteem")
    }

    func testAnswerSlotsHintsFillFromAnswer() {
        let slots = AnswerSlots("run")
        XCTAssertTrue(slots.isFilled(typed: "rn", hinted: [1]))
        XCTAssertEqual(slots.composite(typed: "rn", hinted: [1]), "run")
        let filled = slots.filledCharacters(typed: "", hinted: [0, 1, 2])
        XCTAssertEqual(filled.compactMap { $0 }, ["r", "u", "n"])
    }

    func testAnswerSlotsApostropheIsTypable() {
        let slots = AnswerSlots("o'clock")
        XCTAssertEqual(slots.letterCount, 7)
        XCTAssertEqual(slots.composite(typed: "o'clock", hinted: []), "o'clock")
    }

    func testCurlyApostropheGradesAsStraight() {
        XCTAssertTrue(QuizBuilder.isCorrect(userAnswer: "o\u{2019}clock", expected: "o'clock"))
    }

    func testHintKeepsTypedLettersInTheirBoxes() {
        let slots = AnswerSlots("cat")
        // Fully typed, hint reveals slot 0: its typed occupant is displaced,
        // "a" and "t" stay in their boxes and the answer remains correct.
        XCTAssertEqual(slots.typedAfterHint("cat", revealing: 0, hinted: []), "at")
        XCTAssertEqual(slots.composite(typed: "at", hinted: [0]), "cat")
        // Partial typing, hint lands on an occupied middle slot.
        XCTAssertEqual(slots.typedAfterHint("ca", revealing: 1, hinted: []), "c")
        XCTAssertEqual(slots.composite(typed: "c", hinted: [1]), "ca")
        // Hint on an empty slot leaves typed letters alone.
        XCTAssertEqual(slots.typedAfterHint("c", revealing: 2, hinted: []), "c")
        XCTAssertTrue(slots.isFilled(typed: "ca", hinted: [2]))
    }

    // MARK: - Quiz builder with learned words

    func testBuilderIncludesLearnedOnlyWhenAsked() throws {
        let word = wordInGroup("a", lemma: "run", definition: "To move fast.")
        stats("run", "To move fast.", points: 1000, status: .learned)
        word.senses[0].isEnabled = false
        let keys = SenseStats.statusKeys(try context.fetch(FetchDescriptor<SenseStats>()))

        XCTAssertTrue(QuizBuilder.build(from: [word], sampleSize: nil).isEmpty)
        XCTAssertEqual(QuizBuilder.build(from: [word], sampleSize: nil,
                                         includeLearned: true, statusedKeys: keys).count, 1)
    }

    func testTranslationModeSkipsUntranslatedSenses() throws {
        let group = WordGroup(name: "a")
        context.insert(group)
        let bare = group.findOrCreateWord(lemma: "run", in: context)
        bare.appendSenses(entries: [entry(1, "To move fast.")], customs: [], in: context)
        let translated = group.findOrCreateWord(lemma: "walk", in: context)
        translated.appendSenses(
            entries: [DictionaryService.Entry(id: 2, partOfSpeech: "verb",
                                              definition: "To move on foot.", example: "",
                                              translation: "ходить")],
            customs: [], in: context)

        let questions = QuizBuilder.build(from: [bare, translated], sampleSize: nil,
                                          mode: .translationToEn)
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(questions[0].lemma, "walk")
        XCTAssertEqual(questions[0].prompt, "ходить")
        XCTAssertEqual(questions[0].expectedAnswer, "walk")
    }

    func testCustomSenseCarriesTranslationIntoWord() throws {
        let group = WordGroup(name: "a")
        context.insert(group)
        let custom = CustomSense(lemma: "hazelnut", definition: "A round nut.",
                                 translation: "фундук")
        context.insert(custom)
        let word = group.findOrCreateWord(lemma: "hazelnut", in: context)
        word.appendSenses(entries: [], customs: [custom], in: context)

        XCTAssertEqual(word.senses[0].translation, "фундук")
    }

    func testBuilderNeverRevivesManuallyExcludedSense() throws {
        let word = wordInGroup("a", lemma: "run", definition: "To move fast.")
        word.senses[0].isEnabled = false  // no status: a deliberate exclusion

        XCTAssertTrue(QuizBuilder.build(from: [word], sampleSize: nil,
                                        includeLearned: true, statusedKeys: []).isEmpty)
    }

    // MARK: - Medals

    func testMedalPercentRegradesWithGroupSize() {
        XCTAssertEqual(Medal.percent(points: 1000, wordCount: 10), 100)
        // A word was added: gold is always taken away.
        XCTAssertEqual(Medal.percent(points: 1000, wordCount: 11), 90)
        // A word was deleted: percents rise, capped at 100.
        XCTAssertEqual(Medal.percent(points: 1000, wordCount: 9), 100)
        XCTAssertEqual(Medal.percent(points: 1000, wordCount: 0), 0)
    }

    func testMedalDenominatorSkipsUnquizzableWords() throws {
        let enabled = wordInGroup("a", lemma: "run", definition: "To move fast.")
        let paused = wordInGroup("a", lemma: "walk", definition: "To move on foot.")
        paused.senses[0].isEnabled = false            // manual pause, no status
        let learned = wordInGroup("a", lemma: "sing", definition: "To make music.")
        learned.senses[0].isEnabled = false
        stats("sing", "To make music.", points: 1000, status: .learned)
        let empty = wordInGroup("a", lemma: "husk", definition: "The dry outside.")
        empty.senses[0].word = nil                    // zero-sense word

        let keys = SenseStats.statusKeys(try context.fetch(FetchDescriptor<SenseStats>()))
        XCTAssertTrue(enabled.isQuizzable(byStatused: keys))
        XCTAssertFalse(paused.isQuizzable(byStatused: keys))
        XCTAssertTrue(learned.isQuizzable(byStatused: keys))   // rejoins via include-learned
        XCTAssertFalse(empty.isQuizzable(byStatused: keys))

        // Perfect run over the two quizzable words = gold, despite the
        // paused and empty ones sitting in the group.
        XCTAssertEqual(Medal.percent(points: 200, wordCount: 2), 100)
    }

    func testMedalThresholds() {
        XCTAssertEqual(Medal.bronze.threshold, 70)
        XCTAssertEqual(Medal.silver.threshold, 85)
        XCTAssertEqual(Medal.gold.threshold, 100)
    }

    // MARK: - Copies

    func testAppendSensesKeepsLearnedCopiesOutOfTheQuiz() throws {
        stats("run", "To move fast.", points: 1000, status: .learned)

        let word = wordInGroup("late", lemma: "run", definition: "To move fast.")
        try context.save()

        XCTAssertFalse(word.senses[0].isEnabled)
    }
}
