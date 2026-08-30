import SwiftUI
import SwiftData

struct WordDetailView: View {
    @Environment(\.modelContext) private var context
    @Bindable var word: Word

    @State private var showingAddSense = false
    @State private var newDefinition = ""
    @State private var newExample = ""

    var body: some View {
        Form {
            Section("Word") {
                Text(word.lemma).font(.largeTitle).bold()
                if word.timesSeen > 0 {
                    Text("Seen \(word.timesSeen) times, correct \(word.timesCorrect)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(word.senses.sorted(by: { $0.order < $1.order })) { sense in
                SenseSection(sense: sense) {
                    context.delete(sense)
                }
            }

            Section {
                Button {
                    newDefinition = ""; newExample = ""
                    showingAddSense = true
                } label: {
                    Label("Add my own sense", systemImage: "plus")
                }
            }
        }
        .navigationTitle(word.lemma)
        .navigationBarTitleDisplayMode(.inline)
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
                            let order = (word.senses.map { $0.order }.max() ?? -1) + 1
                            let sense = WordSense(
                                partOfSpeech: WordSense.customPartOfSpeech,
                                definition: newDefinition.trimmingCharacters(in: .whitespacesAndNewlines),
                                example: newExample.trimmingCharacters(in: .whitespacesAndNewlines),
                                isCustom: true,
                                order: order
                            )
                            context.insert(sense)
                            sense.word = word
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

private struct SenseSection: View {
    @Bindable var sense: WordSense
    let onDelete: () -> Void

    var body: some View {
        Section {
            Toggle("Learn this sense", isOn: $sense.isEnabled)
            LabeledContent("Part of speech", value: sense.partOfSpeech)
            VStack(alignment: .leading, spacing: 4) {
                Text("Definition").font(.caption).foregroundStyle(.secondary)
                Text(sense.definition)
            }
            if !sense.example.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Example").font(.caption).foregroundStyle(.secondary)
                    Text("“\(sense.example)”").italic()
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Translation").font(.caption).foregroundStyle(.secondary)
                TextField("your translation or mnemonic", text: $sense.translation, axis: .vertical)
                    .lineLimit(1...4)
            }
            Button("Delete sense", role: .destructive, action: onDelete)
        } header: {
            HStack {
                Text("Sense \(sense.order + 1)")
                if sense.isCustom {
                    Text("CUSTOM")
                        .font(.caption2).bold()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Capsule())
                }
            }
        }
    }
}
