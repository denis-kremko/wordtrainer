import SwiftUI
import SwiftData

// Every stage of the lookup flow is a real navigation push, so the system
// back swipe and transitions work everywhere. The shell below only hosts the
// search stage; word pages and sense-selection pages are standalone views.
struct WordLookupView: View {
    enum Mode {
        case addTo(WordGroup)
        case extend(Word)
        case browse(String)
        case dictionary
    }

    @Environment(\.dismiss) private var dismiss

    let mode: Mode

    init(addingTo group: WordGroup) {
        mode = .addTo(group)
    }

    init(extending word: Word) {
        mode = .extend(word)
    }

    init(browsing lemma: String) {
        mode = .browse(lemma)
    }

    init() {
        mode = .dictionary
    }

    @State private var lemma: String = ""
    @State private var lookup: DictionaryService.LookupResult? = nil
    @State private var searchedKey: String = ""
    @State private var isSearching: Bool = false
    @State private var pushedPage: WordPage? = nil

    var body: some View {
        switch mode {
        case .dictionary:
            searchContent { page in
                WordPageView(lemma: page.lemma)
            }
        case .browse(let lemma):
            NavigationStack {
                WordPageView(lemma: DictionaryService.normalize(lemma))
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
            }
        case .addTo(let group):
            NavigationStack {
                searchContent { page in
                    SenseSelectionView(lemma: page.lemma, target: .group(group)) { dismiss() }
                }
                .navigationTitle("New Word")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        case .extend(let word):
            NavigationStack {
                SenseSelectionView(lemma: DictionaryService.normalize(word.lemma),
                                   target: .word(word)) { dismiss() }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { dismiss() }
                        }
                    }
            }
        }
    }

    // MARK: - Search stage

    private func searchContent<Destination: View>(
        @ViewBuilder destination: @escaping (WordPage) -> Destination
    ) -> some View {
        Form {
            Section("Word") {
                HStack {
                    TextField("e.g. run", text: $lemma)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if isSearching {
                        ProgressView()
                    }
                    if !lemma.isEmpty {
                        Button {
                            lemma = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .cardSurfaceRow()

            if let result = lookup {
                candidatesContent(result)
            } else if !DictionaryService.shared.isAvailable {
                Section {
                    Text("Offline dictionary is not bundled. See README, step “Build the dictionary”.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .cardSurfaceRow()
            }
        }
        .listSectionSpacing(12)
        .appScreen()
        .task(id: lemma) { await performSearch() }
        .navigationDestination(item: $pushedPage, destination: destination)
    }

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
            }
            .cardSurfaceRow()
            Section {
                useAnywayButton
            }
            .cardSurfaceRow()
        } else {
            ForEach(Array(candidates.enumerated()), id: \.element) { index, candidate in
                Section {
                    DisclosureRow(title: candidate) { open(candidate) }
                } header: {
                    if index == 0 {
                        Text("Results")
                    }
                }
                .cardSurfaceRow()
            }
            // Prefix completions alone must not hide the escape hatch:
            // the typed word itself is still absent from the dictionary.
            if result.exact.isEmpty && result.formMatches.isEmpty
                && result.substringMatches.isEmpty {
                Section {
                    useAnywayButton
                }
                .cardSurfaceRow()
            }
        }
    }

    private var useAnywayButton: some View {
        Button {
            open(searchedKey)
        } label: {
            Label("Use “\(searchedKey)” anyway", systemImage: "square.and.pencil")
        }
    }

    private func open(_ word: String) {
        let key = DictionaryService.normalize(word)
        guard !key.isEmpty else { return }
        pushedPage = WordPage(lemma: key)
    }

    // .task(id: lemma) cancels the previous run per keystroke; the sleep is the debounce.
    private func performSearch() async {
        let key = DictionaryService.normalize(lemma)
        guard !key.isEmpty else {
            lookup = nil
            searchedKey = ""
            isSearching = false
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }

        isSearching = true
        let result = await DictionaryService.shared.search(key)
        // Bail before touching state: a cancelled run must not clear the
        // spinner its successor has already turned on.
        guard !Task.isCancelled else { return }
        isSearching = false
        lookup = result
        searchedKey = key
    }
}

// MARK: - Sense selection page (add to group / extend a word)

struct SenseSelectionView: View {
    enum Target {
        case group(WordGroup)
        case word(Word)
    }

    @Environment(\.modelContext) private var context

    let lemma: String
    let target: Target
    let onFinished: () -> Void

    @State private var lookup: DictionaryService.LookupResult? = nil
    @State private var loadedLemma: String? = nil
    @State private var translations: [String] = []
    @State private var selected: Set<Int64> = []
    // Keyed by the stored UUID: persistentModelID changes on autosave.
    @State private var selectedCustom: Set<UUID> = []
    @State private var addFormExpanded: Bool = false
    @State private var newCustomDefinition: String = ""
    @State private var newCustomExample: String = ""
    @State private var editingEntry: DictionaryService.Entry? = nil
    @State private var pushedSelection: WordPage? = nil
    @State private var pushedBrowse: WordPage? = nil

    @Query(sort: \CustomSense.createdAt) private var allCustomSenses: [CustomSense]

    private var customSenses: [CustomSense] {
        allCustomSenses.filter { $0.lemma == lemma }
    }

    var body: some View {
        Form {
            WordHeaderSection(lemma: lemma, isLoading: lookup == nil, translations: translations)

            if let result = lookup {
                if result.exact.isEmpty {
                    NoSensesNote(lemma: lemma)
                } else {
                    ForEach(Array(result.exact.enumerated()), id: \.element.id) { index, entry in
                        Section {
                            senseRow(entry)
                        } header: {
                            if index == 0 {
                                Text("Dict senses")
                            }
                        }
                        .cardSurfaceRow()
                    }
                }

                customSensesSection

                ContainsSection(lemma: lemma, matches: result.substringMatches) { drill($0) }
            }
        }
        .navigationTitle(lemma)
        .navigationBarTitleDisplayMode(.inline)
        .listSectionSpacing(12)
        .appScreen()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    add()
                    onFinished()
                }
                .disabled(!canAdd)
            }
        }
        // id: the pushed item binding can be replaced in flight; stale senses
        // must never be addable under the new lemma. The task also re-fires on
        // pop-back from a drill-down — reload (and drop the in-progress
        // selection) only when the lemma really changed.
        .task(id: lemma) {
            guard loadedLemma != lemma else { return }
            lookup = nil
            selected = []
            selectedCustom = []
            translations = []
            let result = await DictionaryService.shared.search(lemma)
            let russian = await DictionaryService.shared.russianTranslations(for: lemma)
            guard !Task.isCancelled else { return }
            loadedLemma = lemma
            lookup = result
            translations = russian
            if result.exact.isEmpty && customSenses.isEmpty {
                addFormExpanded = true
            }
        }
        .navigationDestination(item: $pushedSelection) { page in
            SenseSelectionView(lemma: page.lemma, target: target, onFinished: onFinished)
        }
        .navigationDestination(item: $pushedBrowse) { page in
            WordPageView(lemma: page.lemma)
        }
        .sheet(item: $editingEntry) { entry in
            ModifySenseSheet(entry: entry) { definition, example in
                let sense = CustomSense.findOrInsert(lemma: lemma, definition: definition,
                                                     example: example, in: context)
                selectedCustom.insert(sense.id)
            }
            .presentationDetents([.medium, .large])
        }
    }

    // In add-to-group mode a contained phrase is addable itself; while
    // extending a word, other lemmas are read-only (Add is bound to the word).
    private func drill(_ lemma: String) {
        let page = WordPage(lemma: lemma)
        if case .group = target {
            pushedSelection = page
        } else {
            pushedBrowse = page
        }
    }

    private func senseRow(_ entry: DictionaryService.Entry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                selected.toggle(entry.id)
            } label: {
                checkRow(isOn: selected.contains(entry.id),
                         definition: entry.definition,
                         example: entry.example,
                         pos: PartOfSpeech.displayName(entry.partOfSpeech, lemma: lemma))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                editingEntry = entry
            } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(.tint)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderless)
        }
    }

    private var customSensesSection: some View {
        CustomSensesSection(senses: customSenses,
                            isExpanded: $addFormExpanded,
                            definition: $newCustomDefinition,
                            example: $newCustomExample,
                            onAdd: { definition, example in
                                let sense = CustomSense.findOrInsert(
                                    lemma: lemma, definition: definition,
                                    example: example, in: context)
                                selectedCustom.insert(sense.id)
                            },
                            onDelete: deleteCustomSense) { sense in
            Button {
                selectedCustom.toggle(sense.id)
            } label: {
                checkRow(isOn: selectedCustom.contains(sense.id),
                         definition: sense.definition,
                         example: sense.example)
            }
            .buttonStyle(.plain)
        }
    }

    private func checkRow(isOn: Bool, definition: String, example: String,
                          pos: String? = nil) -> some View {
        HStack(alignment: .top) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
            SenseTextView(definition: definition, example: example, linkedExcluding: nil,
                          pos: pos)
        }
        .padding(.vertical, 2)
    }

    private func deleteCustomSense(_ sense: CustomSense) {
        selectedCustom.remove(sense.id)
        context.delete(sense)
    }

    // MARK: - Add

    private var draftDefinition: String {
        newCustomDefinition.trimmed
    }

    private var chosenEntries: [DictionaryService.Entry] {
        (lookup?.exact ?? []).filter { selected.contains($0.id) }
    }

    private var chosenCustoms: [CustomSense] {
        customSenses.filter { selectedCustom.contains($0.id) }
    }

    private var canAdd: Bool {
        if case .word(let word) = target {
            // Only senses the word doesn't already have, so Add can't be an
            // enabled no-op (appendSenses would skip them).
            let existing = Set(word.senses.map { $0.definition })
            return chosenEntries.contains { !existing.contains($0.definition) }
                || chosenCustoms.contains { !existing.contains($0.definition) }
                || (!draftDefinition.isEmpty && !existing.contains(draftDefinition))
        }
        return !chosenEntries.isEmpty || !chosenCustoms.isEmpty || !draftDefinition.isEmpty
    }

    private func add() {
        guard canAdd else { return }

        var customs = chosenCustoms
        if !draftDefinition.isEmpty {
            let draft = CustomSense.findOrInsert(
                lemma: lemma, definition: draftDefinition,
                example: newCustomExample.trimmed,
                in: context)
            if !customs.contains(where: { $0.id == draft.id }) {
                customs.append(draft)
            }
        }

        switch target {
        case .word(let word):
            // appendSenses skips definitions the word already has.
            word.appendSenses(entries: chosenEntries, customs: customs, in: context)
        case .group(let group):
            group.findOrCreateWord(lemma: lemma, in: context)
                .appendSenses(entries: chosenEntries, customs: customs, in: context)
        }
    }
}

// MARK: - Word page (dictionary/browse): read-only senses with links

struct WordPage: Identifiable, Hashable {
    let lemma: String
    var id: String { lemma }
}

struct WordPageView: View {
    @Environment(\.modelContext) private var context

    let lemma: String

    @State private var lookup: DictionaryService.LookupResult? = nil
    @State private var loadedLemma: String? = nil
    @State private var translations: [String] = []
    @State private var pushedWord: WordPage? = nil
    @State private var addFormExpanded: Bool = false
    @State private var newCustomDefinition: String = ""
    @State private var newCustomExample: String = ""
    @State private var editingEntry: DictionaryService.Entry? = nil
    @State private var newGroupFor: DictionaryService.Entry? = nil

    @Query(sort: \WordGroup.createdAt, order: .reverse) private var groups: [WordGroup]
    @Query(sort: \CustomSense.createdAt) private var allCustomSenses: [CustomSense]

    private var customSenses: [CustomSense] {
        allCustomSenses.filter { $0.lemma == lemma }
    }

    var body: some View {
        Form {
            WordHeaderSection(lemma: lemma, isLoading: lookup == nil, translations: translations)

            if let result = lookup {
                let added = addedDefinitions
                if result.exact.isEmpty {
                    NoSensesNote(lemma: lemma)
                } else {
                    ForEach(Array(result.exact.enumerated()), id: \.element.id) { index, entry in
                        Section {
                            senseRow(entry, added: added)
                        } header: {
                            if index == 0 {
                                Text("Dict senses")
                            }
                        }
                        .cardSurfaceRow()
                    }
                }

                customSensesSection

                ContainsSection(lemma: lemma, matches: result.substringMatches) {
                    pushedWord = WordPage(lemma: $0)
                }
            }
        }
        .navigationTitle(lemma)
        .navigationBarTitleDisplayMode(.inline)
        .listSectionSpacing(12)
        .appScreen()
        // Reload only for a real lemma change, not on pop-back re-appearance.
        .task(id: lemma) {
            guard loadedLemma != lemma else { return }
            lookup = nil
            translations = []
            let result = await DictionaryService.shared.search(lemma)
            let russian = await DictionaryService.shared.russianTranslations(for: lemma)
            guard !Task.isCancelled else { return }
            loadedLemma = lemma
            lookup = result
            translations = russian
            if result.exact.isEmpty && customSenses.isEmpty {
                addFormExpanded = true
            }
        }
        .navigationDestination(item: $pushedWord) { page in
            WordPageView(lemma: page.lemma)
        }
        .environment(\.openURL, WordLink.openURLAction { word in
            pushedWord = WordPage(lemma: DictionaryService.normalize(word))
        })
        .sheet(item: $editingEntry) { entry in
            ModifySenseSheet(entry: entry) { definition, example in
                CustomSense.findOrInsert(lemma: lemma, definition: definition,
                                         example: example, in: context)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $newGroupFor) { entry in
            QuickAddGroupSheet(lemma: lemma, entry: entry)
        }
    }

    // Live membership, not a tap memo: the checkmark survives navigation and
    // honestly reverts when the containing group, word, or sense is deleted.
    // One walk per body evaluation — not one per sense row.
    private var addedDefinitions: Set<String> {
        var out: Set<String> = []
        for group in groups {
            for word in group.words where word.lemma == lemma {
                out.formUnion(word.senses.lazy.map { $0.definition })
            }
        }
        return out
    }

    private func senseRow(_ entry: DictionaryService.Entry, added: Set<String>) -> some View {
        HStack(alignment: .top, spacing: 8) {
            SenseTextView(definition: entry.definition, example: entry.example,
                          linkedExcluding: lemma,
                          pos: PartOfSpeech.displayName(entry.partOfSpeech, lemma: lemma))
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 10) {
                Button {
                    editingEntry = entry
                } label: {
                    Image(systemName: "pencil")
                        .foregroundStyle(.tint)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderless)
                quickAddMenu(for: entry, isAdded: added.contains(entry.definition))
            }
        }
    }

    // One-tap add of this exact sense into a group.
    private func quickAddMenu(for entry: DictionaryService.Entry, isAdded: Bool) -> some View {
        Menu {
            ForEach(groups) { group in
                Button(group.name) { quickAdd(entry, to: group) }
            }
            if !groups.isEmpty {
                Divider()
            }
            Button {
                newGroupFor = entry
            } label: {
                Label("New group…", systemImage: "plus")
            }
        } label: {
            Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle")
                .foregroundStyle(isAdded ? Color.green : Color.accentColor)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderless)
    }

    private func quickAdd(_ entry: DictionaryService.Entry, to group: WordGroup) {
        group.findOrCreateWord(lemma: lemma, in: context)
            .appendSenses(entries: [entry], customs: [], in: context)
    }

    private var customSensesSection: some View {
        CustomSensesSection(senses: customSenses,
                            isExpanded: $addFormExpanded,
                            definition: $newCustomDefinition,
                            example: $newCustomExample,
                            onAdd: { definition, example in
                                CustomSense.findOrInsert(lemma: lemma, definition: definition,
                                                         example: example, in: context)
                            },
                            onDelete: { context.delete($0) }) { sense in
            SenseTextView(definition: sense.definition, example: sense.example,
                          linkedExcluding: lemma)
        }
    }
}

// MARK: - Shared pieces

private struct WordHeaderSection: View {
    let lemma: String
    let isLoading: Bool
    var translations: [String] = []

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(lemma)
                        .font(.title2).bold()
                        .foregroundStyle(.primary)
                    SpeakButton(text: lemma)
                    if isLoading {
                        ProgressView()
                            .padding(.leading, 4)
                    }
                    Spacer()
                }
                if !translations.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        TagBadge(text: "RU", tint: .accentColor)
                        Text(translations.joined(separator: ", "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .cardSurfaceRow()
    }
}

private struct NoSensesNote: View {
    let lemma: String

    var body: some View {
        Section {
            Text("No dictionary senses for “\(lemma)”. You can add your own below.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .cardSurfaceRow()
    }
}

private struct ContainsSection: View {
    let lemma: String
    let matches: [String]
    let onOpen: (String) -> Void

    var body: some View {
        ForEach(Array(matches.enumerated()), id: \.element) { index, candidate in
            Section {
                DisclosureRow(title: candidate) {
                    onOpen(DictionaryService.normalize(candidate))
                }
            } header: {
                if index == 0 {
                    Text("Contains “\(lemma)”")
                }
            }
            .cardSurfaceRow()
        }
    }
}

// One "Custom senses" block for both word pages; only the row body and the
// delete behavior differ. A card per sense; swipes need cardRow (a plain row
// background unmasks square corners mid-swipe).
private struct CustomSensesSection<Row: View>: View {
    let senses: [CustomSense]
    @Binding var isExpanded: Bool
    @Binding var definition: String
    @Binding var example: String
    let onAdd: (String, String) -> Void
    var onDelete: ((CustomSense) -> Void)? = nil
    @ViewBuilder let row: (CustomSense) -> Row

    var body: some View {
        ForEach(Array(senses.enumerated()), id: \.element.id) { index, sense in
            Section {
                row(sense)
                    .cardRow()
                    .swipeActions {
                        if let onDelete {
                            Button(role: .destructive) {
                                onDelete(sense)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
            } header: {
                if index == 0 {
                    Text("Custom senses")
                }
            }
        }

        Section {
            AddCustomSenseForm(isExpanded: $isExpanded,
                               definition: $definition,
                               example: $example,
                               onAdd: onAdd)
        } header: {
            if senses.isEmpty {
                Text("Custom senses")
            }
        }
        .cardSurfaceRow()
    }
}

private struct AddCustomSenseForm: View {
    @Binding var isExpanded: Bool
    @Binding var definition: String
    @Binding var example: String
    let onAdd: (String, String) -> Void

    var body: some View {
        DisclosureGroup("Add my own definition", isExpanded: $isExpanded) {
            TextField("Definition", text: $definition, axis: .vertical)
                .lineLimit(2...5)
            TextField("Example (optional)", text: $example, axis: .vertical)
                .lineLimit(1...3)
            CapsuleButton(title: "Add", isDisabled: definition.isBlank) {
                let trimmed = definition.trimmed
                guard !trimmed.isEmpty else { return }
                onAdd(trimmed, example.trimmed)
                definition = ""
                example = ""
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
        }
    }
}

// Word links only when linkedExcluding is set: in selection rows word taps
// would fight the checkbox.
private struct SenseTextView: View {
    let definition: String
    let example: String
    let linkedExcluding: String?
    var pos: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let pos {
                Text(pos)
                    .font(.caption2.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.tint)
            }
            line(definition, color: .primary)
                .font(.subheadline)
                .foregroundStyle(.primary)
            if !example.isEmpty {
                line("“\(example)”", color: .secondary)
                    .font(.footnote).italic()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func line(_ string: String, color: Color) -> some View {
        if let excluding = linkedExcluding {
            LinkedText(text: string, color: color, excluding: excluding)
        } else {
            Text(string)
        }
    }
}

private struct QuickAddGroupSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let lemma: String
    let entry: DictionaryService.Entry

    @State private var name = ""
    @State private var groupDescription = ""
    @State private var creating = false

    var body: some View {
        NavigationStack {
            Form {
                Section("New group") {
                    TextField("e.g. Hard words", text: $name)
                    TextField("description (optional)", text: $groupDescription, axis: .vertical)
                        .lineLimit(1...3)
                }
                .cardSurfaceRow()
                CapsuleButton(title: "Create and add “\(lemma)”", isDisabled: name.isBlank) {
                    guard !creating else { return }
                    creating = true
                    let group = WordGroup(name: name.trimmed,
                                          groupDescription: groupDescription.trimmed)
                    context.insert(group)
                    group.findOrCreateWord(lemma: lemma, in: context)
                        .appendSenses(entries: [entry], customs: [], in: context)
                    dismiss()
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                .listRowBackground(Color.clear)
            }
            .appScreen()
            .navigationTitle("Add to new group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
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
                .cardSurfaceRow()
                Section("Example (optional)") {
                    TextField("example sentence", text: $example, axis: .vertical)
                        .lineLimit(1...4)
                }
                .cardSurfaceRow()
                Section {
                    Text("Saved as a custom sense; the dictionary entry stays unchanged.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .cardSurfaceRow()
            }
            .appScreen()
            .navigationTitle("Modify sense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save to custom") {
                        onSave(
                            definition.trimmed,
                            example.trimmed
                        )
                        dismiss()
                    }
                    .disabled(definition.isBlank)
                }
            }
        }
    }
}
