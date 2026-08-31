import SwiftUI
import SwiftData

struct WordDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var word: Word
    // Live so counters recorded by a later quiz show up; one fetch shared by
    // every sense section instead of a per-section, per-render fetch.
    @Query private var allSenseStats: [SenseStats]

    @State private var showingAddSense = false
    @State private var browsing: BrowseTarget? = nil
    @State private var newDefinition = ""
    @State private var newExample = ""

    var body: some View {
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
                    onResetStats: { resetStats(for: sense, in: statsByDefinition) }
                )
            }

            Section {
                Button {
                    newDefinition = ""; newExample = ""
                    showingAddSense = true
                } label: {
                    Label("Add my own sense", systemImage: "plus")
                }
            }

            Section {
                Button("Reset statistics for all senses") {
                    for sense in word.senses {
                        resetStats(for: sense, in: statsByDefinition)
                    }
                }
                .disabled(!word.senses.contains { (statsByDefinition[$0.definition]?.timesSeen ?? 0) > 0 })
                Button("Delete word from group", role: .destructive) {
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
        .sheet(isPresented: $showingAddSense) {
            NavigationStack {
                Form {
                    Section("Definition") {
                        TextField("definition", text: $newDefinition, axis: .vertical)
                            .lineLimit(2...5)
                    }
                    Section("Example (optional)") {
                        TextField("example sentence", text: $newExample, axis: .vertical)
                            .lineLimit(1...3)
                    }
                }
                .navigationTitle("New Sense")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingAddSense = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            let custom = CustomSense.findOrInsert(
                                lemma: word.lemma,
                                definition: newDefinition.trimmingCharacters(in: .whitespacesAndNewlines),
                                example: newExample.trimmingCharacters(in: .whitespacesAndNewlines),
                                in: context
                            )
                            word.appendSenses(entries: [], customs: [custom], in: context)
                            showingAddSense = false
                        }
                        .disabled(newDefinition.isBlank)
                    }
                }
                .presentationDetents([.medium, .large])
            }
        }
    }
}

extension WordDetailView {
    private func resetStats(for sense: WordSense, in statsByDefinition: [String: SenseStats]) {
        if let stats = statsByDefinition[sense.definition] {
            context.delete(stats)
        }
    }
}

struct BrowseTarget: Identifiable {
    let id: String
}

private struct SenseSection: View {
    @Bindable var sense: WordSense
    let stats: SenseStats?
    let onDelete: () -> Void
    let onResetStats: () -> Void

    private var excludedLemma: String {
        DictionaryService.normalize(sense.word?.lemma ?? "")
    }

    var body: some View {
        Section {
            Toggle("Learn this sense", isOn: $sense.isEnabled)
            LabeledContent("Part of speech",
                           value: PartOfSpeech.displayName(sense.partOfSpeech, lemma: sense.word?.lemma ?? ""))
            VStack(alignment: .leading, spacing: 4) {
                Text("Definition").font(.caption).foregroundStyle(.secondary)
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
                Button("Reset statistics", action: onResetStats)
            }
            Button("Delete sense", role: .destructive, action: onDelete)
        } header: {
            HStack {
                Text("Sense \(sense.order + 1)")
                if sense.isCustom {
                    TagBadge(text: "CUSTOM", tint: .accentColor)
                }
            }
        }
    }
}
