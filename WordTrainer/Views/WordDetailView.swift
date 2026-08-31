import SwiftUI
import SwiftData

struct WordDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var word: Word
    // Live so counters recorded by a later quiz show up; one fetch shared by
    // every sense section instead of a per-section, per-render fetch.
    @Query private var allSenseStats: [SenseStats]

    private enum ResetTarget: Identifiable {
        case sense(WordSense)
        case all

        var id: String {
            switch self {
            case .sense(let sense): return sense.definition
            case .all: return "all"
            }
        }
    }

    @State private var showingAddSense = false
    @State private var resetTarget: ResetTarget? = nil
    @State private var browsing: BrowseTarget? = nil
    @State private var isDeletingWord = false

    var body: some View {
        // Once the word is deleted, never touch it again: autosave can
        // invalidate the model mid-pop and any read of it would crash.
        if isDeletingWord {
            Color.clear
        } else {
            detail
        }
    }

    @ViewBuilder
    private var detail: some View {
        let statsByDefinition = SenseStats.byDefinition(allSenseStats, lemma: word.lemma)
        Form {
            Section("Word") {
                Text(word.lemma).font(.largeTitle).bold()
            }

            ForEach(word.senses.sorted(by: { $0.order < $1.order })) { sense in
                SenseSection(
                    sense: sense,
                    stats: statsByDefinition[sense.definition],
                    onDelete: { context.delete(sense) },
                    onResetStats: { resetTarget = .sense(sense) },
                    onSetStatus: { status in
                        SenseStats.findOrInsert(lemma: word.lemma, definition: sense.definition,
                                                in: context).learnStatus = status
                        // A learned/known sense leaves the quiz rotation;
                        // clearing the status puts it back.
                        sense.isEnabled = status == .none
                    }
                )
            }

            Section {
                Button {
                    showingAddSense = true
                } label: {
                    Label("Add senses", systemImage: "plus")
                }
            }

            Section {
                Button("Reset statistics for all senses") {
                    resetTarget = .all
                }
                .disabled(!word.senses.contains { (statsByDefinition[$0.definition]?.timesSeen ?? 0) > 0 })
                Button("Delete word from group", role: .destructive) {
                    isDeletingWord = true
                    context.delete(word)
                    dismiss()
                }
            }
        }
        .navigationTitle(word.lemma)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.openURL, WordLink.openURLAction { lemma in
            browsing = BrowseTarget(id: lemma)
        })
        .sheet(item: $browsing) { target in
            WordLookupView(browsing: target.id)
        }
        .alert(
            "Reset statistics?",
            isPresented: Binding(
                get: { resetTarget != nil },
                set: { if !$0 { resetTarget = nil } }
            ),
            presenting: resetTarget
        ) { target in
            Button("Reset", role: .destructive) {
                let statsByDefinition = SenseStats.byDefinition(allSenseStats, lemma: word.lemma)
                switch target {
                case .sense(let sense):
                    resetStats(for: sense, in: statsByDefinition)
                case .all:
                    for sense in word.senses {
                        resetStats(for: sense, in: statsByDefinition)
                    }
                }
                resetTarget = nil
            }
            Button("Cancel", role: .cancel) { resetTarget = nil }
        } message: { target in
            switch target {
            case .sense:
                Text("Asked and correct counters for this sense will be lost.")
            case .all:
                Text("Asked and correct counters for every sense of “\(word.lemma)” will be lost.")
            }
        }
        .sheet(isPresented: $showingAddSense) {
            WordLookupView(extending: word)
        }
    }
}

extension WordDetailView {
    // Zero the counters instead of deleting the row: launch-time
    // backfillSenseStats treats an empty SenseStats table as a pre-migration
    // store and would rebuild every deleted counter from saved QuizResults.
    private func resetStats(for sense: WordSense, in statsByDefinition: [String: SenseStats]) {
        if let stats = statsByDefinition[sense.definition] {
            context.delete(stats)
        }
    }
}

struct BrowseTarget: Identifiable {
    let id: String
}

// Row background that observes the status itself: List repaints row
// backgrounds only when the background VIEW invalidates, not when the
// enclosing section recomputes its value.
private struct SenseGlow: View {
    let stats: SenseStats?
    let sense: WordSense

    var body: some View {
        ZStack {
            Color(.secondarySystemGroupedBackground)
            if let color {
                color.opacity(0.10)
                border(color)
            } else if sense.isEnabled {
                border(.orange)
            }
        }
    }

    private func border(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .strokeBorder(color, lineWidth: 2)
    }

    private var color: Color? {
        switch stats?.learnStatus ?? .none {
        case .learned: return .green
        case .knew: return .orange
        case .none: return nil
        }
    }
}

private struct SenseSection: View {
    @Bindable var sense: WordSense
    let stats: SenseStats?
    let onDelete: () -> Void
    let onResetStats: () -> Void
    let onSetStatus: (LearnStatus) -> Void

    private var excludedLemma: String {
        DictionaryService.normalize(sense.word?.lemma ?? "")
    }

    private var currentStatus: LearnStatus { stats?.learnStatus ?? .none }

    private func capsuleButton(_ title: String,
                               isOn: Bool,
                               color: Color,
                               selectedText: Color = .white,
                               isDisabled: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isDisabled ? Color.secondary : (isOn ? selectedText : color))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(isDisabled ? Color(.systemGray5) : (isOn ? color : color.opacity(0.15)))
                .clipShape(Capsule())
        }
        .buttonStyle(.borderless)
        .scaleEffect(isOn && !isDisabled ? 0.94 : 1)
        .animation(.spring(duration: 0.25), value: isOn)
        .disabled(isDisabled)
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
            capsuleButton("Learn this sense",
                          isOn: sense.isEnabled,
                          color: .orange) {
                if sense.isEnabled {
                    sense.isEnabled = false
                } else {
                    sense.isEnabled = true
                    if currentStatus != .none { onSetStatus(.none) }
                }
            }
            capsuleButton("Learned",
                          isOn: currentStatus == .learned,
                          color: .green) {
                onSetStatus(currentStatus == .learned ? .none : .learned)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(sense.isCustom
                     ? "Definition"
                     : "Definition · \(PartOfSpeech.displayName(sense.partOfSpeech, lemma: sense.word?.lemma ?? ""))")
                    .font(.caption).foregroundStyle(.secondary)
                LinkedText(text: sense.definition, color: .primary, excluding: excludedLemma)
                    .font(.subheadline)
            }
            if !sense.example.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Example").font(.caption).foregroundStyle(.secondary)
                    LinkedText(text: "“\(sense.example)”", color: .primary, excluding: excludedLemma)
                        .font(.footnote)
                        .italic()
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Translation").font(.caption).foregroundStyle(.secondary)
                TextField("your translation or mnemonic", text: $sense.translation, axis: .vertical)
                    .lineLimit(1...4)
            }
            SenseStatsLine(stats: stats)
            if (stats?.timesSeen ?? 0) > 0 {
                capsuleButton("Reset statistics", isOn: false, color: .blue, action: onResetStats)
            }
            capsuleButton("Delete sense", isOn: false, color: .red, action: onDelete)
            }
        } header: {
            HStack {
                Text("Sense \(sense.order + 1)")
                if sense.isCustom {
                    TagBadge(text: "CUSTOM", tint: .accentColor)
                }
            }
        }
        .listRowBackground(SenseGlow(stats: stats, sense: sense))
    }
}
