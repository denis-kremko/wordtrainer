import SwiftUI
import SwiftData

struct AddWordSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let group: WordGroup

    @State private var lemma: String = ""
    @State private var lookup: DictionaryService.LookupResult? = nil
    @State private var selected: Set<Int64> = []
    @State private var customDefinition: String = ""
    @State private var customExpanded: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Word") {
                    HStack {
                        TextField("e.g. run", text: $lemma)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { performLookup() }
                        Button("Look up") { performLookup() }
                            .disabled(lemma.isBlank)
                    }
                    if lookup == nil {
                        Button {
                            lookup = DictionaryService.LookupResult(exact: [], formMatches: [], substringMatches: [])
                            customExpanded = true
                        } label: {
                            Label("Add without looking up", systemImage: "square.and.pencil")
                                .font(.footnote)
                        }
                    }
                }

                if let result = lookup {
                    lookupContent(result)
                } else if !DictionaryService.shared.isAvailable {
                    Section {
                        Text("Offline dictionary is not bundled. See README, step “Build the dictionary”.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("New Word")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { addWord() }
                        .disabled(!canAdd)
                }
            }
        }
    }

    @ViewBuilder
    private func lookupContent(_ result: DictionaryService.LookupResult) -> some View {
        if result.exact.isEmpty {
            Section {
                if result.formMatches.isEmpty && result.substringMatches.isEmpty {
                    Text("Not found in the offline dictionary. You can add your own definition below.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No exact match. Did you mean one of these? Tap to look it up.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Section("Pick the senses to learn") {
                ForEach(result.exact) { entry in
                    senseRow(entry)
                }
            }
        }

        if !result.formMatches.isEmpty {
            Section("Base forms") {
                ForEach(result.formMatches, id: \.self) { candidate in
                    Button(candidate) {
                        lemma = candidate
                        performLookup()
                    }
                }
            }
        }
        if !result.substringMatches.isEmpty {
            Section("Contains \"\(lemma.trimmingCharacters(in: .whitespacesAndNewlines))\"") {
                ForEach(result.substringMatches, id: \.self) { candidate in
                    Button(candidate) {
                        lemma = candidate
                        performLookup()
                    }
                }
            }
        }

        Section {
            DisclosureGroup(isExpanded: $customExpanded) {
                TextField("Definition", text: $customDefinition, axis: .vertical)
                    .lineLimit(2...5)
            } label: {
                Label(result.exact.isEmpty ? "My definition" : "Add my own definition",
                      systemImage: "pencil")
            }
        }
    }

    @ViewBuilder
    private func senseRow(_ entry: DictionaryService.Entry) -> some View {
        Button {
            if selected.contains(entry.id) { selected.remove(entry.id) }
            else { selected.insert(entry.id) }
        } label: {
            HStack(alignment: .top) {
                Image(systemName: selected.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected.contains(entry.id) ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.partOfSpeech)
                        .font(.caption).foregroundStyle(.secondary)
                    Text(entry.definition)
                        .font(.body)
                        .foregroundStyle(.primary)
                    if !entry.example.isEmpty {
                        Text("“\(entry.example)”")
                            .font(.caption).italic()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var canAdd: Bool {
        if lemma.isBlank { return false }
        let hasDictionaryPick = !selected.isEmpty
        let hasCustom = !customDefinition.isBlank
        return hasDictionaryPick || hasCustom
    }

    private func performLookup() {
        let key = lemma.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let result = DictionaryService.shared.search(key)
        lookup = result
        selected = Set(result.exact.map { $0.id })
        if result.exact.isEmpty { customExpanded = true }
    }

    private func addWord() {
        let trimmed = lemma.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let word = Word(lemma: trimmed)
        context.insert(word)
        word.group = group

        var order = 0

        let chosen = (lookup?.exact ?? []).filter { selected.contains($0.id) }
        for entry in chosen {
            let sense = WordSense(
                partOfSpeech: entry.partOfSpeech,
                definition: entry.definition,
                example: entry.example,
                isCustom: false,
                order: order
            )
            context.insert(sense)
            sense.word = word
            order += 1
        }

        let customDef = customDefinition.trimmingCharacters(in: .whitespacesAndNewlines)
        if !customDef.isEmpty {
            let sense = WordSense(
                partOfSpeech: WordSense.customPartOfSpeech,
                definition: customDef,
                isCustom: true,
                order: order
            )
            context.insert(sense)
            sense.word = word
        }

        dismiss()
    }
}
