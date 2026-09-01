import XCTest
import SwiftData
@testable import WordAce

@MainActor
final class MergeLogicTests: XCTestCase {
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

    private func makeGroup(_ name: String) -> WordGroup {
        let group = WordGroup(name: name)
        context.insert(group)
        return group
    }

    private func entry(_ id: Int64, _ definition: String,
                       pos: String = "noun") -> DictionaryService.Entry {
        DictionaryService.Entry(id: id, partOfSpeech: pos, definition: definition, example: "")
    }

    private func definitions(_ word: Word) -> [String] {
        word.senses.sorted { $0.order < $1.order }.map { $0.definition }
    }

    // MARK: - findOrCreateWord

    func testSameLemmaMergesIntoExistingWord() throws {
        let group = makeGroup("g")
        let first = group.findOrCreateWord(lemma: "run", in: context)
        let second = group.findOrCreateWord(lemma: "run", in: context)
        try context.save()

        XCTAssertTrue(first === second)
        XCTAssertEqual(group.words.count, 1)
    }

    func testDifferentLemmasStaySeparate() throws {
        let group = makeGroup("g")
        _ = group.findOrCreateWord(lemma: "run", in: context)
        _ = group.findOrCreateWord(lemma: "walk", in: context)
        try context.save()

        XCTAssertEqual(Set(group.words.map { $0.lemma }), ["run", "walk"])
    }

    func testLemmaNormalizationEnforcedByModel() throws {
        let group = makeGroup("g")
        let first = group.findOrCreateWord(lemma: "run", in: context)
        let second = group.findOrCreateWord(lemma: "  RUN ", in: context)
        try context.save()

        XCTAssertTrue(first === second)
        XCTAssertEqual(Word(lemma: " MiXeD ").lemma, "mixed")
    }

    // MARK: - appendSenses dedup

    func testAppendSensesDedupsAgainstExistingAndWithinBatch() throws {
        let group = makeGroup("g")
        let word = group.findOrCreateWord(lemma: "run", in: context)
        word.appendSenses(entries: [entry(1, "To move fast.")], customs: [], in: context)
        word.appendSenses(entries: [entry(1, "To move fast."),
                                    entry(2, "To move fast."),
                                    entry(3, "To operate.")],
                          customs: [], in: context)
        try context.save()

        XCTAssertEqual(definitions(word), ["To move fast.", "To operate."])
        XCTAssertEqual(word.senses.map { $0.order }.sorted(), [0, 1])
    }

    func testAppendSensesDedupsCustomAgainstDictionary() throws {
        let group = makeGroup("g")
        let word = group.findOrCreateWord(lemma: "run", in: context)
        let custom = CustomSense(lemma: "run", definition: "To move fast.")
        context.insert(custom)
        word.appendSenses(entries: [entry(1, "To move fast.")], customs: [custom], in: context)
        try context.save()

        XCTAssertEqual(definitions(word), ["To move fast."])
        XCTAssertFalse(word.senses[0].isCustom)
    }

    // MARK: - absorb (move into an existing twin)

    func testAbsorbMergesMissingSensesAndDeletesDonor() throws {
        let source = makeGroup("source")
        let target = makeGroup("target")

        let donor = source.findOrCreateWord(lemma: "run", in: context)
        donor.appendSenses(entries: [entry(1, "To move fast."), entry(2, "To operate.")],
                           customs: [], in: context)
        let twin = target.findOrCreateWord(lemma: "run", in: context)
        twin.appendSenses(entries: [entry(1, "To move fast.")], customs: [], in: context)

        twin.absorb(donor, in: context)
        try context.save()

        XCTAssertEqual(definitions(twin), ["To move fast.", "To operate."])
        XCTAssertTrue(source.words.isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Word>()).count, 1)
        // The donor's duplicate sense must not survive as an orphan.
        XCTAssertEqual(try context.fetch(FetchDescriptor<WordSense>()).count, 2)
    }

    func testAbsorbKeepsSenseSettings() throws {
        let source = makeGroup("source")
        let target = makeGroup("target")

        let donor = source.findOrCreateWord(lemma: "run", in: context)
        donor.appendSenses(entries: [entry(2, "To operate.")], customs: [], in: context)
        donor.senses[0].isEnabled = false

        let twin = target.findOrCreateWord(lemma: "run", in: context)
        twin.appendSenses(entries: [entry(1, "To move fast.")], customs: [], in: context)
        twin.absorb(donor, in: context)
        try context.save()

        let moved = try XCTUnwrap(twin.senses.first { $0.definition == "To operate." })
        XCTAssertFalse(moved.isEnabled)
    }

    // MARK: - cloneSenses (copy)

    func testCloneSensesCopiesEverythingAndKeepsSource() throws {
        let source = makeGroup("source")
        let target = makeGroup("target")

        let original = source.findOrCreateWord(lemma: "run", in: context)
        original.appendSenses(entries: [entry(1, "To move fast.")], customs: [], in: context)
        original.senses[0].isEnabled = false

        let copy = target.findOrCreateWord(lemma: "run", in: context)
        copy.cloneSenses(from: original, in: context)
        try context.save()

        XCTAssertEqual(definitions(original), ["To move fast."])
        XCTAssertEqual(definitions(copy), ["To move fast."])
        XCTAssertFalse(copy.senses[0].isEnabled)
        XCTAssertEqual(try context.fetch(FetchDescriptor<WordSense>()).count, 2)
    }

    func testCloneTwiceIsIdempotent() throws {
        let source = makeGroup("source")
        let target = makeGroup("target")

        let original = source.findOrCreateWord(lemma: "run", in: context)
        original.appendSenses(entries: [entry(1, "To move fast."), entry(2, "To operate.")],
                              customs: [], in: context)

        let copy = target.findOrCreateWord(lemma: "run", in: context)
        copy.cloneSenses(from: original, in: context)
        copy.cloneSenses(from: original, in: context)
        try context.save()

        XCTAssertEqual(definitions(copy), ["To move fast.", "To operate."])
    }

    func testCloneIntoWordWithOverlapAppendsOnlyMissing() throws {
        let source = makeGroup("source")
        let target = makeGroup("target")

        let original = source.findOrCreateWord(lemma: "run", in: context)
        original.appendSenses(entries: [entry(1, "To move fast."), entry(2, "To operate.")],
                              customs: [], in: context)
        let copy = target.findOrCreateWord(lemma: "run", in: context)
        copy.appendSenses(entries: [entry(2, "To operate."), entry(3, "A journey.")],
                          customs: [], in: context)

        copy.cloneSenses(from: original, in: context)
        try context.save()

        XCTAssertEqual(Set(definitions(copy)), ["To move fast.", "To operate.", "A journey."])
        XCTAssertEqual(copy.senses.count, 3)
        XCTAssertEqual(copy.senses.map { $0.order }.sorted(), [0, 1, 2])
    }

    // MARK: - end-to-end: ready-list merge into an existing group

    func testRepeatedConvertStyleMergeIsIdempotent() throws {
        let group = makeGroup("g")
        for _ in 0..<2 {
            for (lemma, def) in [("alien", "Extraterrestrial life form."),
                                 ("orbit", "The path of a body around another.")] {
                group.findOrCreateWord(lemma: lemma, in: context)
                    .appendSenses(entries: [entry(Int64(def.count), def)], customs: [], in: context)
            }
        }
        try context.save()

        XCTAssertEqual(group.words.count, 2)
        XCTAssertTrue(group.words.allSatisfy { $0.senses.count == 1 })
    }
}
