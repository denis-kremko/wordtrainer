import SwiftUI
import SwiftData

// MARK: - Catalog (bundled ready_groups.json)

struct ReadyWord: Decodable, Hashable, Identifiable {
    let w: String
    let pos: String?
    let hint: [String]?

    var id: String { w }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let s = try? single.decode(String.self) {
            w = s
            pos = nil
            hint = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        w = try container.decode(String.self, forKey: .w)
        pos = try container.decodeIfPresent(String.self, forKey: .pos)
        hint = try container.decodeIfPresent([String].self, forKey: .hint)
    }

    func isTopical(_ definition: String) -> Bool {
        guard let hint, !hint.isEmpty else { return true }
        let d = definition.lowercased()
        return hint.contains { d.contains($0) }
    }

    private enum CodingKeys: String, CodingKey { case w, pos, hint }
}

struct ReadyGroup: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    let description: String
    let pos: String?
    let words: [ReadyWord]

    func effectivePOS(for word: ReadyWord) -> String? {
        word.pos ?? pos
    }

    static func == (lhs: ReadyGroup, rhs: ReadyGroup) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum ReadyGroupsCatalog {
    static let groups: [ReadyGroup] = {
        struct File: Decodable {
            let version: Int
            let groups: [ReadyGroup]
        }
        guard let url = Bundle.main.url(forResource: "ready_groups", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else {
            NSLog("[WordTrainer] ready_groups.json missing or invalid")
            return []
        }
        return file.groups
    }()
}

// MARK: - List

struct ReadyGroupsListView: View {
    @Query private var groups: [WordGroup]
    @Query(filter: #Predicate<SenseStats> { $0.status != "" }) private var progressed: [SenseStats]

    private var addedIDs: Set<String> {
        Set(groups.compactMap { $0.sourceReadyGroupID })
    }

    // A list word counts as closed once any sense of its lemma has a status.
    private func progress(for ready: ReadyGroup) -> (Int, Int)? {
        let lemmas = Set(progressed.map { $0.lemma })
        let done = ready.words.filter { lemmas.contains(DictionaryService.normalize($0.w)) }.count
        return done > 0 ? (done, ready.words.count) : nil
    }

    var body: some View {
        let added = addedIDs  // one Set for the whole list, not one per row
        List {
            ForEach(ReadyGroupsCatalog.groups) { ready in
                NavigationLink(value: ready) {
                    HStack(spacing: 12) {
                        Image(systemName: ready.icon)
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 34, height: 34)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(ready.name).font(.headline)
                                if added.contains(ready.id) {
                                    TagBadge(text: "ADDED", tint: .green)
                                }
                            }
                            Text("^[\(ready.words.count) word](inflect: true) • \(ready.description)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            if let (done, total) = progress(for: ready) {
                                HStack(spacing: 6) {
                                    ProgressView(value: Double(done), total: Double(total))
                                        .tint(.green)
                                    Text("\(done)/\(total)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize()
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

// MARK: - Detail

struct ReadyGroupDetailView: View {
    let ready: ReadyGroup
    let onCreated: (WordGroup) -> Void

    @State private var entriesByWord: [String: [DictionaryService.Entry]]? = nil
    @Query(filter: #Predicate<SenseStats> { $0.status != "" }) private var progressed: [SenseStats]
    @State private var showingConvert = false
    @State private var browsingWord: ReadyWord? = nil
    @State private var createdGroup: WordGroup? = nil

    var body: some View {
        ZStack(alignment: .bottom) {
            List {
                Section {
                    Text(ready.description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Words (\(ready.words.count))") {
                    let progressedLemmas = Set(progressed.map { $0.lemma })
                    ForEach(ready.words) { word in
                        HStack(spacing: 8) {
                            DisclosureRow(title: word.w,
                                          subtitle: firstDefinition(for: word) ?? "—",
                                          titleIsHeadline: true) {
                                browsingWord = word
                            }
                            if progressedLemmas.contains(DictionaryService.normalize(word.w)) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }

                ListBottomSpacer()
            }

            BottomCTA(title: "Start learning", systemImage: "plus.circle.fill") {
                showingConvert = true
            }
            // Converting before the lookup finishes would silently create an
            // empty group (create() skips words with no senses).
            .disabled(entriesByWord == nil)
        }
        .navigationTitle(ready.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            entriesByWord = await DictionaryService.shared.entriesByLemma(ready.words.map { $0.w })
        }
        .sheet(isPresented: $showingConvert, onDismiss: {
            // Navigate only after the sheet is fully gone: swapping the
            // navigation path mid-dismissal can drop the push.
            if let created = createdGroup {
                createdGroup = nil
                onCreated(created)
            }
        }) {
            ConvertReadyGroupSheet(ready: ready, entriesByWord: entriesByWord ?? [:]) { created in
                createdGroup = created
            }
        }
        .sheet(item: $browsingWord) { word in
            WordLookupView(browsing: word.w, starring: starredSenseIDs(for: word))
        }
    }

    // The senses conversion would enable for this list: star them on the word page.
    private func starredSenseIDs(for word: ReadyWord) -> Set<Int64> {
        Set(enabledSenses(of: word, in: entriesByWord ?? [:], group: ready)
            .filter { $0.isEnabled }
            .map { $0.entry.id })
    }

    private func firstDefinition(for word: ReadyWord) -> String? {
        topicalFirstSense(of: word, in: entriesByWord ?? [:], group: ready)?.definition
    }
}

private func senses(of word: ReadyWord,
                    in entriesByWord: [String: [DictionaryService.Entry]],
                    group: ReadyGroup) -> [DictionaryService.Entry] {
    let all = entriesByWord[word.w] ?? []
    guard let pos = group.effectivePOS(for: word) else { return all }
    let filtered = all.filter { $0.partOfSpeech == pos }
    return filtered.isEmpty ? all : filtered
}

// Each kept sense paired with whether it should be enabled. When the hints
// match nothing, everything is enabled — a word with all senses disabled would
// silently vanish from every quiz.
private func enabledSenses(of word: ReadyWord,
                           in entriesByWord: [String: [DictionaryService.Entry]],
                           group: ReadyGroup) -> [(entry: DictionaryService.Entry, isEnabled: Bool)] {
    let list = senses(of: word, in: entriesByWord, group: group)
    let anyTopical = list.contains { word.isTopical($0.definition) }
    return list.map { ($0, !anyTopical || word.isTopical($0.definition)) }
}

private func topicalFirstSense(of word: ReadyWord,
                               in entriesByWord: [String: [DictionaryService.Entry]],
                               group: ReadyGroup) -> DictionaryService.Entry? {
    enabledSenses(of: word, in: entriesByWord, group: group).first(where: { $0.isEnabled })?.entry
}

// MARK: - Convert ("filter and start learning")

struct ConvertReadyGroupSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let ready: ReadyGroup
    let entriesByWord: [String: [DictionaryService.Entry]]
    let onCreated: (WordGroup) -> Void

    @State private var excluded: Set<String> = []
    @State private var groupName: String

    @Query(sort: \CustomSense.createdAt) private var allCustomSenses: [CustomSense]

    init(ready: ReadyGroup,
         entriesByWord: [String: [DictionaryService.Entry]],
         onCreated: @escaping (WordGroup) -> Void) {
        self.ready = ready
        self.entriesByWord = entriesByWord
        self.onCreated = onCreated
        _groupName = State(initialValue: ready.name)
    }

    private var selectedCount: Int { ready.words.count - excluded.count }

    var body: some View {
        NavigationStack {
            Form {
                Section("Group name") {
                    TextField("name", text: $groupName)
                }

                Section {
                    ForEach(ready.words) { word in
                        Button {
                            if excluded.contains(word.id) { excluded.remove(word.id) }
                            else { excluded.insert(word.id) }
                        } label: {
                            HStack(alignment: .top) {
                                Image(systemName: excluded.contains(word.id) ? "circle" : "checkmark.circle.fill")
                                    .foregroundStyle(excluded.contains(word.id) ? Color.secondary : Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(word.w)
                                        .foregroundStyle(.primary)
                                    if let def = topicalFirstSense(of: word, in: entriesByWord, group: ready)?.definition {
                                        Text(def)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text("Learning \(selectedCount) of \(ready.words.count)")
                        Spacer()
                        Button(excluded.isEmpty ? "Deselect all" : "Select all") {
                            excluded = excluded.isEmpty ? Set(ready.words.map { $0.id }) : []
                        }
                        .font(.caption)
                        .textCase(nil)
                    }
                } footer: {
                    Text("Uncheck the words you already know.")
                }
            }
            .navigationTitle("Filter words")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(groupName.isBlank || selectedCount == 0)
                }
            }
        }
    }

    private func create() {
        let group = WordGroup(
            name: groupName.trimmingCharacters(in: .whitespacesAndNewlines),
            groupDescription: ready.description
        )
        group.sourceReadyGroupID = ready.id
        context.insert(group)

        let customsByLemma = Dictionary(grouping: allCustomSenses, by: { $0.lemma })
        for word in ready.words where !excluded.contains(word.id) {
            let key = DictionaryService.normalize(word.w)
            let entries = enabledSenses(of: word, in: entriesByWord, group: ready)
            let customs = customsByLemma[key] ?? []
            guard !entries.isEmpty || !customs.isEmpty else { continue }

            let w = Word(lemma: key)
            context.insert(w)
            w.group = group
            w.appendSenses(entries: entries, customs: customs, in: context)
        }

        onCreated(group)
        dismiss()
    }
}
