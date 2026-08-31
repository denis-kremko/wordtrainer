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
    let level: String
    let levelSubtitle: String
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

struct ReadyTheme: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    let description: String
    let levels: [ReadyGroup]

    static func == (lhs: ReadyTheme, rhs: ReadyTheme) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum ReadyGroupsCatalog {
    static let themes: [ReadyTheme] = {
        struct File: Decodable {
            let version: Int
            let themes: [ReadyTheme]
        }
        guard let url = Bundle.main.url(forResource: "ready_groups", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else {
            NSLog("[WordTrainer] ready_groups.json missing or invalid")
            return []
        }
        return file.themes
    }()
}

// A list word counts as closed once any sense of its lemma has a status;
// words swiped as "knew already" drop out of the denominator entirely.
struct ReadyProgress {
    private let known: Set<String>
    private let closed: Set<String>

    init(_ progressed: [SenseStats]) {
        known = Set(progressed.filter { $0.learnStatus == .knew }.map { $0.lemma })
        closed = Set(progressed.map { $0.lemma })
    }

    func of(_ ready: ReadyGroup) -> (done: Int, remaining: Int) {
        count(Set(ready.words.map { DictionaryService.normalize($0.w) }))
    }

    // Theme progress runs over the UNIQUE lemmas of all its levels: overlaps
    // between levels count once.
    func of(_ theme: ReadyTheme) -> (done: Int, remaining: Int) {
        count(Set(theme.levels.flatMap { $0.words.map { DictionaryService.normalize($0.w) } }))
    }

    private func count(_ lemmas: Set<String>) -> (done: Int, remaining: Int) {
        var done = 0
        var remaining = 0
        for lemma in lemmas {
            if known.contains(lemma) { continue }
            remaining += 1
            if closed.contains(lemma) { done += 1 }
        }
        return (done, remaining)
    }
}

// MARK: - Themes

struct ReadyThemesView: View {
    @Query(filter: #Predicate<SenseStats> { $0.status != "" }) private var progressed: [SenseStats]

    var body: some View {
        let progress = ReadyProgress(progressed)
        List {
            ForEach(ReadyGroupsCatalog.themes) { theme in
                let prog = progress.of(theme)
                Section {
                    NavigationLink(value: theme) {
                        HStack(spacing: 12) {
                            Image(systemName: theme.icon)
                                .font(.title3)
                                .foregroundStyle(.tint)
                                .frame(width: 34, height: 34)
                                .background(Color.accentColor.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(theme.name).font(.headline)
                                HStack(spacing: 6) {
                                    ForEach(theme.levels) { level in
                                        TagBadge(text: level.level, tint: .accentColor)
                                    }
                                }
                                Text(theme.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                if prog.done > 0 && prog.remaining > 0 {
                                    HStack(spacing: 6) {
                                        ProgressView(value: Double(prog.done), total: Double(prog.remaining))
                                            .tint(.green)
                                        Text("\(prog.done)/\(prog.remaining)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .fixedSize()
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowBackground(RowGlow(
                        color: !theme.levels.isEmpty && prog.done == prog.remaining ? .green : nil))
                }
            }
        }
        .listSectionSpacing(12)
    }
}

// MARK: - List

struct ReadyThemeView: View {
    let theme: ReadyTheme

    @Query private var groups: [WordGroup]
    @Query(filter: #Predicate<SenseStats> { $0.status != "" }) private var progressed: [SenseStats]

    private var addedIDs: Set<String> {
        Set(groups.compactMap { $0.sourceReadyGroupID })
    }

    var body: some View {
        let added = addedIDs  // one Set for the whole list, not one per row
        let progress = ReadyProgress(progressed)
        List {
            ForEach(theme.levels) { ready in
                let prog = progress.of(ready)
                Section {
                    NavigationLink(value: ready) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(ready.level).font(.headline)
                                TagBadge(text: ready.levelSubtitle.uppercased(), tint: .accentColor)
                                if added.contains(ready.id) {
                                    TagBadge(text: "ADDED", tint: .green)
                                }
                            }
                            Text("^[\(ready.words.count) word](inflect: true) • \(ready.description)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            if prog.done > 0 && prog.remaining > 0 {
                                HStack(spacing: 6) {
                                    ProgressView(value: Double(prog.done), total: Double(prog.remaining))
                                        .tint(.green)
                                    Text("\(prog.done)/\(prog.remaining)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize()
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowBackground(RowGlow(
                        color: !ready.words.isEmpty && prog.done == prog.remaining ? .green : nil))
                }
            }
        }
        .listSectionSpacing(12)
        .navigationTitle(theme.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Detail

struct ReadyGroupDetailView: View {
    let ready: ReadyGroup
    let onCreated: (WordGroup) -> Void

    @Environment(\.modelContext) private var context
    @State private var entriesByWord: [String: [DictionaryService.Entry]]? = nil
    @Query(filter: #Predicate<SenseStats> { $0.status != "" }) private var progressed: [SenseStats]
    @Query private var allWords: [Word]
    @State private var showingConvert = false
    @State private var browsingWord: ReadyWord? = nil
    @State private var createdGroup: WordGroup? = nil
    @State private var blockedLemma: String? = nil

    var body: some View {
        ZStack(alignment: .bottom) {
            List {
                Section {
                    Text(ready.description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                let progressedLemmas = Set(progressed.map { $0.lemma })
                let knownLemmas = Set(progressed.filter { $0.learnStatus == .knew }.map { $0.lemma })
                ForEach(Array(ready.words.enumerated()), id: \.element.id) { index, word in
                    let lemma = DictionaryService.normalize(word.w)
                    let known = knownLemmas.contains(lemma)
                    Section {
                        DisclosureRow(title: word.w,
                                      subtitle: firstDefinition(for: word) ?? "—",
                                      titleIsHeadline: true) {
                            browsingWord = word
                        }
                        .padding(.vertical, 1)
                        .listRowBackground(RowGlow(
                            color: known ? .orange
                                 : progressedLemmas.contains(lemma) ? .green : nil))
                        .swipeActions(edge: .leading) {
                            if known {
                                Button {
                                    setKnown(word, false)
                                } label: {
                                    Label("Unmark", systemImage: "arrow.uturn.backward")
                                }
                                .tint(.gray)
                            } else {
                                Button {
                                    setKnown(word, true)
                                } label: {
                                    Label("Knew already", systemImage: "checkmark.seal.fill")
                                }
                                .tint(.orange)
                            }
                        }
                    } header: {
                        if index == 0 {
                            Text("Words")
                        }
                    }
                }

                ListBottomSpacer()
            }
            .listSectionSpacing(12)

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
            WordLookupView(browsing: word.w)
        }
        .alert(
            "Already being learned",
            isPresented: Binding(
                get: { blockedLemma != nil },
                set: { if !$0 { blockedLemma = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("“\(blockedLemma ?? "")” is in one of your groups. Mark its senses as Learned on the word page instead.")
        }
    }

    // "Knew already" marks the one sense this list teaches; unmarking only
    // clears knew statuses so real learned progress survives a stray swipe.
    private func setKnown(_ word: ReadyWord, _ on: Bool) {
        let lemma = DictionaryService.normalize(word.w)
        if on {
            guard !allWords.contains(where: { $0.lemma == lemma && $0.group != nil }) else {
                blockedLemma = word.w
                return
            }
            guard let entry = boundSense(of: word, in: entriesByWord ?? [:], group: ready) else { return }
            let stats = SenseStats.findOrInsert(lemma: lemma, definition: entry.definition, in: context)
            if stats.learnStatus == .none {
                stats.learnStatus = .knew
            }
        } else {
            for stats in progressed where stats.lemma == lemma && stats.learnStatus == .knew {
                stats.learnStatus = .none
            }
        }
    }

    private func firstDefinition(for word: ReadyWord) -> String? {
        boundSense(of: word, in: entriesByWord ?? [:], group: ready)?.definition
    }
}

// The single sense a ready word stands for: first topical one, else the top-
// ranked sense of the list's POS. Everything (row card, "knew already",
// conversion) binds to this definition.
private func boundSense(of word: ReadyWord,
                        in entriesByWord: [String: [DictionaryService.Entry]],
                        group: ReadyGroup) -> DictionaryService.Entry? {
    let all = entriesByWord[word.w] ?? []
    var list = all
    if let pos = group.effectivePOS(for: word) {
        let filtered = all.filter { $0.partOfSpeech == pos }
        if !filtered.isEmpty { list = filtered }
    }
    return list.first(where: { word.isTopical($0.definition) }) ?? list.first
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

    @Query(filter: #Predicate<SenseStats> { $0.status != "" }) private var progressed: [SenseStats]

    init(ready: ReadyGroup,
         entriesByWord: [String: [DictionaryService.Entry]],
         onCreated: @escaping (WordGroup) -> Void) {
        self.ready = ready
        self.entriesByWord = entriesByWord
        self.onCreated = onCreated
        _groupName = State(initialValue: ready.name)
    }

    private var selectedCount: Int { ready.words.count - excluded.count }

    // Swiped "knew already" in the list: permanently out of the conversion.
    private var knownIDs: Set<String> {
        let known = Set(progressed.filter { $0.learnStatus == .knew }.map { $0.lemma })
        return Set(ready.words
            .filter { known.contains(DictionaryService.normalize($0.w)) }
            .map { $0.id })
    }

    var body: some View {
        let knownIDs = knownIDs
        NavigationStack {
            Form {
                Section("Group name") {
                    TextField("name", text: $groupName)
                }

                Section {
                    ForEach(ready.words) { word in
                        let isKnown = knownIDs.contains(word.id)
                        Button {
                            if excluded.contains(word.id) { excluded.remove(word.id) }
                            else { excluded.insert(word.id) }
                        } label: {
                            HStack(alignment: .top) {
                                Image(systemName: excluded.contains(word.id) ? "circle" : "checkmark.circle.fill")
                                    .foregroundStyle(excluded.contains(word.id) ? Color.secondary : Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(word.w)
                                        .foregroundStyle(isKnown ? Color.secondary : Color.primary)
                                    if let def = boundSense(of: word, in: entriesByWord, group: ready)?.definition {
                                        Text(def)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isKnown)
                        .opacity(isKnown ? 0.45 : 1)
                    }
                } header: {
                    HStack {
                        Text("Learning \(selectedCount) of \(ready.words.count - knownIDs.count)")
                        Spacer()
                        let allSelected = excluded.subtracting(knownIDs).isEmpty
                        Button(allSelected ? "Deselect all" : "Select all") {
                            excluded = allSelected ? Set(ready.words.map { $0.id }) : knownIDs
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
            .onAppear {
                excluded.formUnion(knownIDs)
            }
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

        for word in ready.words where !excluded.contains(word.id) {
            guard let entry = boundSense(of: word, in: entriesByWord, group: ready) else { continue }
            let w = Word(lemma: DictionaryService.normalize(word.w))
            context.insert(w)
            w.group = group
            w.appendSenses(entries: [(entry, true)], customs: [], in: context)
        }

        onCreated(group)
        dismiss()
    }
}
