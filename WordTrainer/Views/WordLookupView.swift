import SwiftUI
import SwiftData

struct WordLookupView: View {
    enum Mode {
        case addTo(WordGroup)
        case browse(String)
        case dictionary
    }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let mode: Mode

    init(addingTo group: WordGroup) {
        mode = .addTo(group)
    }

    init(browsing lemma: String) {
        mode = .browse(lemma)
        _lemma = State(initialValue: lemma)
        _picked = State(initialValue: DictionaryService.normalize(lemma))
    }

    init() {
        mode = .dictionary
    }

    private var group: WordGroup? {
        if case .addTo(let g) = mode { return g }
        return nil
    }

    private var lockedLemma: String? {
        if case .browse(let l) = mode { return l }
        return nil
    }

    private var showsSelection: Bool { group != nil }

    private var isEmbedded: Bool {
        if case .dictionary = mode { return true }
        return false
    }

    @State private var lemma: String = ""
    @State private var picked: String? = nil
    @State private var lookup: DictionaryService.LookupResult? = nil
    @State private var searchedKey: String = ""
    @State private var selected: Set<Int64> = []
    // Keyed by the stored UUID: persistentModelID changes on autosave.
    @State private var selectedCustom: Set<UUID> = []
    @State private var isSearching: Bool = false

    @State private var addFormExpanded: Bool = false
    @State private var newCustomDefinition: String = ""
    @State private var newCustomExample: String = ""
    @State private var editingEntry: DictionaryService.Entry? = nil

    @Query(sort: \CustomSense.createdAt) private var allCustomSenses: [CustomSense]

    private var customSenses: [CustomSense] {
        guard !searchedKey.isEmpty else { return [] }
        return allCustomSenses.filter { $0.lemma == searchedKey }
    }

    var body: some View {
        if isEmbedded {
            content
        } else {
            NavigationStack {
                content
                    .navigationTitle(lockedLemma != nil ? (picked ?? lockedLemma!) : "New Word")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        if showsSelection {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { dismiss() }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Add") { addWord() }
                                    .disabled(!canAdd)
                            }
                        } else {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { dismiss() }
                            }
                        }
                    }
            }
        }
    }

    private var content: some View {
        Form {
            if lockedLemma == nil {
                Section("Word") {
                    HStack {
                        TextField("e.g. run", text: $lemma)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if isSearching {
                            ProgressView()
                        }
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
        .task(id: lemma) { await performSearch() }
        .sheet(item: $editingEntry) { entry in
            ModifySenseSheet(entry: entry) { definition, example in
                let sense = findOrInsertCustomSense(definition: definition, example: example)
                selectedCustom.insert(sense.id)
            }
            .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private func lookupContent(_ result: DictionaryService.LookupResult) -> some View {
        if picked != nil {
            detailContent(result)
        } else {
            candidatesContent(result)
        }
    }

    // MARK: - Stage 1: pick a word

    private func candidateList(_ result: DictionaryService.LookupResult) -> [String] {
        var out: [String] = []
        if !result.exact.isEmpty { out.append(searchedKey) }
        for f in result.formMatches where !out.contains(f) { out.append(f) }
        for p in result.prefixMatches where !out.contains(p) { out.append(p) }
        for m in result.substringMatches where !out.contains(m) { out.append(m) }
        return out
    }

    @ViewBuilder
    private func candidatesContent(_ result: DictionaryService.LookupResult) -> some View {
        let candidates = candidateList(result)
        if candidates.isEmpty {
            Section {
                Text("Not found in the offline dictionary.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    pick(searchedKey)
                } label: {
                    Label("Use “\(searchedKey)” anyway", systemImage: "square.and.pencil")
                }
            }
        } else {
            Section("Results") {
                ForEach(candidates, id: \.self) { candidate in
                    candidateRow(candidate)
                }
            }
        }
    }

    private func candidateRow(_ candidate: String) -> some View {
        DisclosureRow(title: candidate) { pick(candidate) }
    }

    private func pick(_ word: String) {
        let key = DictionaryService.normalize(word)
        guard !key.isEmpty else { return }
        picked = key
        if DictionaryService.normalize(lemma) != key {
            lemma = word  // restarts .task(id: lemma); performSearch handles the rest
        } else {
            expandAddFormIfNoSenses(exactIsEmpty: lookup?.exact.isEmpty ?? true)
        }
    }

    private func expandAddFormIfNoSenses(exactIsEmpty: Bool) {
        if exactIsEmpty && customSenses.isEmpty {
            addFormExpanded = true
        }
    }

    // MARK: - Stage 2: senses of the picked word

    @ViewBuilder
    private func detailContent(_ result: DictionaryService.LookupResult) -> some View {
        if result.exact.isEmpty {
            Section {
                Text("No dictionary senses for “\(searchedKey)”. You can add your own below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            Section("Dict senses") {
                ForEach(posGroups(result.exact), id: \.name) { group in
                    posHeader(group.name)
                    ForEach(group.entries) { entry in
                        senseRow(entry)
                    }
                }
            }
        }

        customSensesSection

        if !result.substringMatches.isEmpty {
            Section("Contains “\(searchedKey)”") {
                ForEach(result.substringMatches, id: \.self) { candidate in
                    candidateRow(candidate)
                }
            }
        }
    }

    // MARK: - Dictionary senses

    private func posGroups(_ entries: [DictionaryService.Entry]) -> [(name: String, entries: [DictionaryService.Entry])] {
        var order: [String] = []
        var grouped: [String: [DictionaryService.Entry]] = [:]
        for entry in entries {
            let name = PartOfSpeech.displayName(entry.partOfSpeech, lemma: searchedKey)
            if grouped[name] == nil { order.append(name) }
            grouped[name, default: []].append(entry)
        }
        return order.map { (name: $0, entries: grouped[$0] ?? []) }
    }

    private func posHeader(_ name: String) -> some View {
        Text(name)
            .font(.footnote.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.tint)
            .padding(.top, 4)
            .listRowSeparator(.hidden, edges: .top)
    }

    @ViewBuilder
    private func senseRow(_ entry: DictionaryService.Entry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if !showsSelection {
                senseText(definition: entry.definition, example: entry.example)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Button {
                    if selected.contains(entry.id) { selected.remove(entry.id) }
                    else { selected.insert(entry.id) }
                } label: {
                    checkRow(isOn: selected.contains(entry.id),
                             definition: entry.definition,
                             example: entry.example)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Button {
                editingEntry = entry
            } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Custom senses

    @ViewBuilder
    private var customSensesSection: some View {
        Section("Custom senses") {
            if customSenses.isEmpty {
                Text("No custom senses yet")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(customSenses) { sense in
                    if !showsSelection {
                        senseText(definition: sense.definition, example: sense.example)
                    } else {
                        Button {
                            if selectedCustom.contains(sense.id) { selectedCustom.remove(sense.id) }
                            else { selectedCustom.insert(sense.id) }
                        } label: {
                            checkRow(isOn: selectedCustom.contains(sense.id),
                                     definition: sense.definition,
                                     example: sense.example)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .onDelete(perform: deleteCustomSenses)
            }

            DisclosureGroup("Add my own definition", isExpanded: $addFormExpanded) {
                TextField("Definition", text: $newCustomDefinition, axis: .vertical)
                    .lineLimit(2...5)
                TextField("Example (optional)", text: $newCustomExample, axis: .vertical)
                    .lineLimit(1...3)
                Button {
                    addCustomSense()
                } label: {
                    Text("Add")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .disabled(newCustomDefinition.isBlank)
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
            }
        }
    }

    private func checkRow(isOn: Bool, definition: String, example: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
            senseText(definition: definition, example: example)
        }
        .padding(.vertical, 2)
    }

    private func senseText(definition: String, example: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(definition)
                .font(.body)
                .foregroundStyle(.primary)
            if !example.isEmpty {
                Text("“\(example)”")
                    .font(.caption).italic()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func findOrInsertCustomSense(definition: String, example: String) -> CustomSense {
        CustomSense.findOrInsert(lemma: searchedKey, definition: definition, example: example, in: context)
    }

    private func addCustomSense() {
        guard !draftDefinition.isEmpty, !searchedKey.isEmpty else { return }
        let sense = findOrInsertCustomSense(definition: draftDefinition, example: draftExample)
        selectedCustom.insert(sense.id)
        newCustomDefinition = ""
        newCustomExample = ""
    }

    private func deleteCustomSenses(at offsets: IndexSet) {
        let items = customSenses
        for i in offsets {
            selectedCustom.remove(items[i].id)
            context.delete(items[i])
        }
    }

    // MARK: - Search

    // .task(id: lemma) cancels the previous run per keystroke; the sleep is the debounce.
    private func performSearch() async {
        let key = DictionaryService.normalize(lemma)
        // Searches for the just-picked word (pick(), browse init) skip the debounce;
        // for genuine typing, picked has already been reset by an earlier run.
        let isPickedSearch = picked == key
        if let p = picked, p != key {
            picked = nil
        }
        guard !key.isEmpty else {
            lookup = nil
            searchedKey = ""
            selected = []
            selectedCustom = []
            isSearching = false
            return
        }

        if !isPickedSearch {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
        }

        isSearching = true
        let result = await DictionaryService.shared.search(key)
        // Bail before touching state: a cancelled run must not clear the
        // spinner its successor has already turned on.
        guard !Task.isCancelled else { return }
        isSearching = false

        let newIDs = Set(result.exact.map { $0.id })
        let oldIDs = Set(lookup?.exact.map { $0.id } ?? [])
        lookup = result
        if newIDs != oldIDs {
            selected = []
        }
        if key != searchedKey {
            searchedKey = key
            selectedCustom = []
        }
        if picked == key {
            expandAddFormIfNoSenses(exactIsEmpty: result.exact.isEmpty)
        }
    }

    // MARK: - Add

    private var draftDefinition: String {
        newCustomDefinition.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var draftExample: String {
        newCustomExample.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAdd: Bool {
        picked != nil && !searchedKey.isEmpty
            && (!chosenEntries.isEmpty || !chosenCustoms.isEmpty || !draftDefinition.isEmpty)
    }

    private var chosenEntries: [DictionaryService.Entry] {
        (lookup?.exact ?? []).filter { selected.contains($0.id) }
    }

    private var chosenCustoms: [CustomSense] {
        customSenses.filter { selectedCustom.contains($0.id) }
    }

    private func addWord() {
        guard canAdd, let group else { return }

        let word = Word(lemma: searchedKey)
        context.insert(word)
        word.group = group

        var customs = chosenCustoms
        if !draftDefinition.isEmpty {
            let draft = findOrInsertCustomSense(definition: draftDefinition, example: draftExample)
            if !customs.contains(where: { $0.id == draft.id }) {
                customs.append(draft)
            }
        }
        word.appendSenses(entries: chosenEntries.map { ($0, true) }, customs: customs, in: context)

        dismiss()
    }
}

private struct ModifySenseSheet: View {
    @Environment(\.dismiss) private var dismiss

    let entry: DictionaryService.Entry
    let onSave: (String, String) -> Void

    @State private var definition: String
    @State private var example: String

    init(entry: DictionaryService.Entry, onSave: @escaping (String, String) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _definition = State(initialValue: entry.definition)
        _example = State(initialValue: entry.example)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Definition") {
                    TextField("definition", text: $definition, axis: .vertical)
                        .lineLimit(2...6)
                }
                Section("Example (optional)") {
                    TextField("example sentence", text: $example, axis: .vertical)
                        .lineLimit(1...4)
                }
                Section {
                    Text("Saved as a custom sense; the dictionary entry stays unchanged.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Modify sense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save to custom") {
                        onSave(
                            definition.trimmingCharacters(in: .whitespacesAndNewlines),
                            example.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        dismiss()
                    }
                    .disabled(definition.isBlank)
                }
            }
        }
    }
}
