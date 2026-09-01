import SwiftUI
import SwiftData

struct WordDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var word: Word
    // Live so counters recorded by a later quiz show up; scoped to this lemma
    // so the all-time stats table is never walked whole per render.
    @Query private var allSenseStats: [SenseStats]

    init(word: Word) {
        self.word = word
        let lemma = word.lemma
        _allSenseStats = Query(filter: #Predicate<SenseStats> { $0.lemma == lemma })
    }

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
    @State private var browsing: WordPage? = nil
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
                HStack(spacing: 12) {
                    Text(word.lemma).font(.largeTitle).bold()
                    SpeakButton(text: word.lemma)
                    Spacer()
                }
            }
            .cardSurfaceRow()

            ProgressPlateSection(
                learned: word.senses.filter {
                    (statsByDefinition[$0.definition]?.learnStatus ?? .none) != .none
                }.count,
                total: word.senses.count)

            let sortedSenses = word.senses.sorted(by: { $0.order < $1.order })
            ForEach(Array(sortedSenses.enumerated()), id: \.element.id) { index, sense in
                SenseSection(
                    number: index + 1,
                    sense: sense,
                    stats: statsByDefinition[sense.definition],
                    onDelete: { context.delete(sense) },
                    onResetPoints: { resetTarget = .sense(sense) },
                    onClearKnew: {
                        statsByDefinition[sense.definition]?.clearStatusManually(in: context)
                    }
                )
            }

            Section {
                CapsuleButton(title: "Add senses", systemImage: "plus", isOn: false) {
                    showingAddSense = true
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                CapsuleButton(title: "Reset points for all senses",
                              isOn: false,
                              color: .accentColor,
                              isDisabled: !word.senses.contains {
                                  let stats = statsByDefinition[$0.definition]
                                  return (stats?.points ?? 0) > 0 || stats?.learnStatus == .learned
                              }) {
                    resetTarget = .all
                }
                .listRowSeparator(.hidden)
                deleteWordButton
            }
            .listRowBackground(Color.clear)
        }
        .appScreen()
        .navigationTitle(word.lemma)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.openURL, WordLink.openURLAction { lemma in
            browsing = WordPage(lemma: lemma)
        })
        .sheet(item: $browsing) { target in
            WordLookupView(browsing: target.lemma)
        }
        .alert(
            "Reset points?",
            isPresented: Binding(isPresent: $resetTarget),
            presenting: resetTarget
        ) { target in
            Button("Reset", role: .destructive) {
                let statsByDefinition = SenseStats.byDefinition(allSenseStats, lemma: word.lemma)
                switch target {
                case .sense(let sense):
                    statsByDefinition[sense.definition]?.resetPoints(in: context)
                case .all:
                    for sense in word.senses {
                        statsByDefinition[sense.definition]?.resetPoints(in: context)
                    }
                }
                resetTarget = nil
            }
            Button("Cancel", role: .cancel) { resetTarget = nil }
        } message: { target in
            switch target {
            case .sense:
                Text("Points for this sense go back to zero and its learned mark is removed.")
            case .all:
                Text("Points for every sense of “\(word.lemma)” go back to zero; learned marks are removed.")
            }
        }
        .sheet(isPresented: $showingAddSense) {
            WordLookupView(extending: word)
        }
    }
}

extension WordDetailView {
    private var deleteWordButton: some View {
        CapsuleButton(title: "Delete word from group", isOn: false, color: .red) {
            isDeletingWord = true
            context.delete(word)
            dismiss()
        }
        .listRowSeparator(.hidden)
    }


}

// Row background that observes the status itself: List repaints row
// backgrounds only when the background VIEW invalidates, not when the
// enclosing section recomputes its value.
private struct SenseGlow: View {
    let stats: SenseStats?
    let sense: WordSense

    var body: some View {
        ZStack {
            Color.cardSurface
            if let color {
                CardGlow(color: color)
            } else if sense.isEnabled {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(Color.orange, lineWidth: 2)
            }
        }
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
    let number: Int
    @Bindable var sense: WordSense
    @AppStorage(LearnSettings.pointsToLearnKey) private var pointsToLearn = 1000
    let stats: SenseStats?
    let onDelete: () -> Void
    let onResetPoints: () -> Void
    let onClearKnew: () -> Void

    private var excludedLemma: String {
        DictionaryService.normalize(sense.word?.lemma ?? "")
    }

    private var currentStatus: LearnStatus { stats?.learnStatus ?? .none }

    // A capsule gauge with exactly the buttons' metrics, filling with gold.
    private var pointsProgress: some View {
        let points = stats?.points ?? 0
        let learned = currentStatus == .learned
        let fraction = min(1.0, Double(points) / Double(max(pointsToLearn, 1)))
        let label = Text(learned ? "Learned" : "\(points)/\(pointsToLearn)")
            .font(.subheadline.weight(.semibold))
        return ZStack {
            label.foregroundStyle(learned ? Color.white : Color.primary)
            // A black copy clipped to the gold fill: white-on-yellow past
            // ~50% progress is unreadable.
            if !learned {
                label.foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .mask(alignment: .leading) {
                        GeometryReader { geo in
                            Rectangle().frame(width: geo.size.width * fraction)
                        }
                    }
            }
        }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(learned ? Color.green.opacity(0.15) : Color.yellow.opacity(0.18))
                        Rectangle()
                            .fill(learned ? Color.green : Color.yellow)
                            .frame(width: geo.size.width * (learned ? 1 : fraction))
                    }
                    .clipShape(Capsule())
                }
            }
            .animation(.spring(duration: 0.3), value: points)
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
            CapsuleButton(title: "Learn this sense",
                          isOn: sense.isEnabled,
                          color: .orange,
                          isDisabled: currentStatus == .learned) {
                if sense.isEnabled {
                    sense.isEnabled = false
                } else {
                    sense.isEnabled = true
                    if currentStatus == .knew { onClearKnew() }
                }
            }
            pointsProgress
            VStack(alignment: .leading, spacing: 4) {
                Text(sense.isCustom
                     ? "Definition"
                     : "Definition · \(PartOfSpeech.displayName(sense.partOfSpeech, lemma: sense.word?.lemma ?? ""))")
                    .font(.caption).foregroundStyle(.secondary)
                LinkedText(text: sense.definition, color: .primary, excluding: excludedLemma)
                    .font(.subheadline)
            }
            TranslationRow(translation: sense.translation)
            if !sense.example.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Example").font(.caption).foregroundStyle(.secondary)
                    LinkedText(text: "“\(sense.example)”", color: .primary, excluding: excludedLemma)
                        .font(.footnote)
                        .italic()
                }
            }
            if (stats?.points ?? 0) > 0 || currentStatus == .learned {
                CapsuleButton(title: "Reset points", isOn: false, color: .accentColor, action: onResetPoints)
            }
            CapsuleButton(title: "Delete sense", isOn: false, color: .red, action: onDelete)
            }
        } header: {
            HStack {
                Text("Sense \(number)")
                if sense.isCustom {
                    TagBadge(text: "CUSTOM", tint: .accentColor)
                }
            }
        }
        .listRowBackground(SenseGlow(stats: stats, sense: sense))
    }
}
