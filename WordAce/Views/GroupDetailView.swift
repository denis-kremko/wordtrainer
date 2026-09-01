import SwiftUI
import SwiftData

struct GroupDetailView: View {
    @Environment(\.modelContext) private var context
    @Bindable var group: WordGroup

    @Query(filter: SenseStats.statusedPredicate) private var progressed: [SenseStats]
    @Query private var sessions: [QuizSession]

    init(group: WordGroup) {
        self.group = group
        let id = group.id.uuidString
        _sessions = Query(filter: #Predicate<QuizSession> { $0.groupID == id })
    }

    @State private var showingAddWord = false
    @State private var showingQuizConfig = false
    @State private var isSelecting = false
    @State private var selectedWords: Set<UUID> = []
    @State private var transfer: WordTransfer? = nil

    var body: some View {
        ZStack(alignment: .bottom) {
            List {
                if group.words.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No words yet",
                            systemImage: "text.book.closed",
                            description: Text("Tap Add word to add your first word. The app will pull its meanings from the offline dictionary.")
                        )
                        .listRowBackground(Color.clear)
                    }
                } else {
                    let done = SenseStats.statusKeys(progressed)
                    let learnedCount = group.words.filter { $0.isLearned(byStatused: done) }.count

                    medalsPlate(done: done)
                    ProgressPlateSection(learned: learnedCount, total: group.words.count)

                    ForEach(Array(sortedWords.enumerated()), id: \.element.id) { index, word in
                        let learned = word.isLearned(byStatused: done)
                        // Empty counts too: a zero-sense word is just as
                        // unquizzable as a fully paused one.
                        let allDisabled = word.senses.allSatisfy { !$0.isEnabled }
                        let baseColor: Color? = learned ? .green : (allDisabled ? .gray : nil)
                        let dimmed = allDisabled && !learned
                        Section {
                            if isSelecting {
                                let isChosen = selectedWords.contains(word.id)
                                Button {
                                    selectedWords.toggle(word.id)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                                            .font(.title3)
                                            .foregroundStyle(isChosen ? Color.accentColor : Color.secondary)
                                        wordRowContent(word, done: done, dimmed: dimmed)
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .cardRow(color: isChosen ? .accentColor : baseColor)
                            } else {
                                CardLinkRow(value: word, color: baseColor) {
                                    wordRowContent(word, done: done, dimmed: dimmed)
                                }
                                .swipeActions {
                                    Button(role: .destructive) {
                                        context.delete(word)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    // A learned word is out of rotation by
                                    // status: disabling it would change nothing.
                                    // With no senses there is nothing to toggle.
                                    if !learned && !word.senses.isEmpty {
                                        if allDisabled {
                                            Button {
                                                for sense in word.senses
                                                where !done.contains(SenseStats.key(word.lemma, sense.definition)) {
                                                    sense.isEnabled = true
                                                }
                                            } label: {
                                                Label("Enable", systemImage: "play.circle.fill")
                                            }
                                            .tint(.orange)
                                        } else {
                                            Button {
                                                for sense in word.senses {
                                                    sense.isEnabled = false
                                                }
                                            } label: {
                                                Label("Disable", systemImage: "pause.circle.fill")
                                            }
                                            .tint(.gray)
                                        }
                                    }
                                }
                            }
                        } header: {
                            if index == 0 {
                                Text("Words")
                            }
                        }
                    }
                }

                ListBottomSpacer(height: 84)
            }

            if isSelecting {
                selectionCTAs
            } else {
                bottomCTAs
            }
        }
        .appScreen()
        .navigationTitle(group.name)
        .toolbar {
            if !group.words.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSelecting ? "Done" : "Select") {
                        isSelecting.toggle()
                        selectedWords = []
                    }
                }
            }
            if !isSelecting {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        GroupStatsView(group: group)
                    } label: {
                        Label("Stats", systemImage: "chart.bar.xaxis")
                    }
                }
            }
        }
        .navigationDestination(for: Word.self) { word in
            WordDetailView(word: word)
        }
        .sheet(isPresented: $showingAddWord) {
            WordLookupView(addingTo: group)
        }
        .sheet(item: $transfer) { action in
            WordsDestinationSheet(action: action, words: chosenWords, from: group) {
                isSelecting = false
                selectedWords = []
            }
        }
        .fullScreenCover(isPresented: $showingQuizConfig) {
            QuizConfigSheet(group: group)
        }
    }

    private func bestMedalPercent(done: Set<String>) -> Int {
        // Medals grade the main discipline: definition quizzes. Translation
        // mode can't ask untranslated words, so its sessions never compare
        // fairly against the quizzable denominator.
        let bestPoints = sessions.lazy
            .filter { $0.mode == QuizMode.definitionToEn.rawValue }
            .map(\.points).max() ?? 0
        let quizzable = group.words.filter { $0.isQuizzable(byStatused: done) }.count
        return Medal.percent(points: bestPoints, wordCount: quizzable)
    }

    private func medalsPlate(done: Set<String>) -> some View {
        let best = bestMedalPercent(done: done)
        return Section {
            HStack {
                Text("Medals").font(.headline)
                Spacer()
                MedalRow(bestPercent: best, font: .title3)
            }
            .listRowBackground(RowGlow(color: best >= Medal.gold.threshold ? .yellow : nil))
        }
    }

    private func wordRowContent(_ word: Word, done: Set<String>,
                                dimmed: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(word.lemma)
                .font(.headline)
                .foregroundStyle(dimmed ? Color.secondary : Color.primary)
            let total = word.senses.count
            let enabled = word.senses.lazy.filter { $0.isEnabled }.count
            let learnedSenses = word.senses.lazy.filter {
                done.contains(SenseStats.key(word.lemma, $0.definition))
            }.count
            (Text("\(enabled)/\(total) senses enabled · ").foregroundStyle(Color.secondary)
                + Text("\(learnedSenses)/\(total) learned")
                    .foregroundStyle(learnedSenses > 0 ? Color.green : Color.secondary))
                .font(.caption)
        }
    }

    private var bottomCTAs: some View {
        HStack(spacing: 12) {
            CapsuleButton(title: "Add word", systemImage: "plus.circle.fill",
                          isOn: false, isLarge: true) {
                showingAddWord = true
            }
            CapsuleButton(title: "Start quiz", systemImage: "play.fill",
                          isDisabled: group.words.isEmpty, isLarge: true) {
                showingQuizConfig = true
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var selectionCTAs: some View {
        HStack(spacing: 10) {
            CapsuleButton(title: "Copy (\(selectedWords.count))",
                          isOn: false,
                          isDisabled: selectedWords.isEmpty, isLarge: true) {
                transfer = .copy
            }
            CapsuleButton(title: "Move (\(selectedWords.count))",
                          isDisabled: selectedWords.isEmpty, isLarge: true) {
                transfer = .move
            }
            CapsuleButton(title: "Delete (\(selectedWords.count))",
                          color: .red,
                          isDisabled: selectedWords.isEmpty, isLarge: true) {
                for word in chosenWords {
                    context.delete(word)
                }
                isSelecting = false
                selectedWords = []
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var chosenWords: [Word] {
        group.words.filter { selectedWords.contains($0.id) }
    }

    private var sortedWords: [Word] {
        group.words.sorted { $0.lemma.localizedCaseInsensitiveCompare($1.lemma) == .orderedAscending }
    }
}

enum WordTransfer: String, Identifiable {
    case move
    case copy

    var id: String { rawValue }
    var title: String { self == .move ? "Move" : "Copy" }
}

// Photos-style destination picker for the selected words: an existing group
// or a brand-new one. Copies share progress with the originals for free —
// learn statuses are global per (lemma, definition).
private struct WordsDestinationSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let action: WordTransfer
    let words: [Word]
    let from: WordGroup
    let onDone: () -> Void

    @Query(sort: \WordGroup.createdAt, order: .reverse) private var allGroups: [WordGroup]
    @State private var newGroupName = ""
    @State private var newGroupDesc = ""
    @State private var transferring = false

    private var otherGroups: [WordGroup] {
        allGroups.filter { $0.id != from.id }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("New group") {
                    TextField("e.g. Hard words", text: $newGroupName)
                    TextField("description (optional)", text: $newGroupDesc, axis: .vertical)
                        .lineLimit(1...3)
                    CapsuleButton(title: "Create and \(action.rawValue)",
                                  isDisabled: newGroupName.isBlank) {
                        // Guard BEFORE the insert: a double-tap must not leave
                        // a stray empty duplicate group behind.
                        guard !transferring else { return }
                        let target = WordGroup(name: newGroupName.trimmed,
                                               groupDescription: newGroupDesc.trimmed)
                        context.insert(target)
                        transfer(to: target)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                }
                .cardSurfaceRow()

                CardSections("Existing group", items: otherGroups, id: \.id) { target in
                    Button {
                        transfer(to: target)
                    } label: {
                        HStack {
                            Text(target.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("^[\(target.words.count) word](inflect: true)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .appScreen()
            .navigationTitle("\(action.title) ^[\(words.count) word](inflect: true)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func transfer(to target: WordGroup) {
        guard !transferring else { return }
        transferring = true
        for word in words {
            switch action {
            case .move: move(word, to: target)
            case .copy: copy(word, to: target)
            }
        }
        onDone()
        dismiss()
    }

    private func move(_ word: Word, to target: WordGroup) {
        if let twin = target.words.first(where: { $0.lemma == word.lemma }) {
            twin.absorb(word, in: context)
        } else {
            word.group = target
        }
    }

    private func copy(_ word: Word, to target: WordGroup) {
        target.findOrCreateWord(lemma: word.lemma, in: context)
            .cloneSenses(from: word, in: context)
    }
}
