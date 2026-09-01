import SwiftUI
import SwiftData

// MARK: - Catalog (bundled ready_groups.json)

struct ReadyWord: Decodable, Hashable, Identifiable {
    let w: String
    let pos: String?
    let hint: [String]?

    var id: String { w }

    // Normalized once at decode: progress math touches every catalog word
    // per row render, and normalize is not free.
    let key: String

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let s = try? single.decode(String.self) {
            w = s
            pos = nil
            hint = nil
            key = DictionaryService.normalize(s)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        w = try container.decode(String.self, forKey: .w)
        pos = try container.decodeIfPresent(String.self, forKey: .pos)
        hint = try container.decodeIfPresent([String].self, forKey: .hint)
        key = DictionaryService.normalize(w)
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
            assertionFailure("ready_groups.json missing or invalid")
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

    func isKnown(_ lemma: String) -> Bool { known.contains(lemma) }
    func isClosed(_ lemma: String) -> Bool { closed.contains(lemma) }

    func of(_ ready: ReadyGroup) -> (done: Int, remaining: Int) {
        count(Set(ready.words.map { $0.key }))
    }

    // Theme progress runs over the UNIQUE lemmas of all its levels: overlaps
    // between levels count once.
    func of(_ theme: ReadyTheme) -> (done: Int, remaining: Int) {
        count(Set(theme.levels.flatMap { $0.words.map { $0.key } }))
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

private struct ProgressLine: View {
    let done: Int
    let remaining: Int

    var body: some View {
        if done > 0 && remaining > 0 {
            HStack(spacing: 6) {
                ProgressView(value: Double(done), total: Double(remaining))
                    .tint(.green)
                Text("\(done)/\(remaining)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }
}

// MARK: - Themes

struct ReadyThemesView: View {
    @Query(filter: SenseStats.statusedPredicate) private var progressed: [SenseStats]

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
                                .background(Color.accentColor.opacity(0.2))
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
                                ProgressLine(done: prog.done, remaining: prog.remaining)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowBackground(RowGlow(
                        color: !theme.levels.isEmpty && prog.done == prog.remaining ? .green : nil))
                }
            }
        }
        .appScreen()
    }
}

// MARK: - List

struct ReadyThemeView: View {
    let theme: ReadyTheme

    @Query private var groups: [WordGroup]
    @Query(filter: SenseStats.statusedPredicate) private var progressed: [SenseStats]

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
                            ProgressLine(done: prog.done, remaining: prog.remaining)
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowBackground(RowGlow(
                        color: !ready.words.isEmpty && prog.done == prog.remaining ? .green : nil))
                }
            }
        }
        .appScreen()
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
    // Bound definition per word, resolved once after the lookup lands: rows
    // must not rescan the dictionary on every body evaluation (swipes re-render
    // the list per frame).
    @State private var definitions: [String: String] = [:]
    @Query(filter: SenseStats.statusedPredicate) private var progressed: [SenseStats]
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
                .cardSurfaceRow()
                let progress = ReadyProgress(progressed)
                ForEach(Array(ready.words.enumerated()), id: \.element.id) { index, word in
                    let known = progress.isKnown(word.key)
                    Section {
                        DisclosureRow(title: word.w,
                                      subtitle: definitions[word.w] ?? "—",
                                      titleIsHeadline: true) {
                            browsingWord = word
                        }
                        .cardRow(color: known ? .orange
                                      : progress.isClosed(word.key) ? .green : nil)
                        .swipeActions(edge: .leading) {
                            // No action while definitions load: setKnown would
                            // silently no-op.
                            if entriesByWord != nil {
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
                        }
                    } header: {
                        if index == 0 {
                            Text("Words")
                        }
                    }
                }

                ListBottomSpacer()
            }
            .appScreen()

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
            let entries = await DictionaryService.shared.entriesByLemma(ready.words.map { $0.w })
            entriesByWord = entries
            definitions = Dictionary(uniqueKeysWithValues: ready.words.map {
                ($0.w, boundSense(of: $0, in: entries, group: ready)?.definition ?? "\u{2014}")
            })
        }
        .sheet(isPresented: $showingConvert, onDismiss: {
            // Navigate only after the sheet is fully gone: swapping the
            // navigation path mid-dismissal can drop the push.
            if let created = createdGroup {
                createdGroup = nil
                onCreated(created)
            }
        }) {
            ConvertReadyGroupSheet(ready: ready, entriesByWord: entriesByWord ?? [:],
                                   definitions: definitions) { created in
                createdGroup = created
            }
        }
        .sheet(item: $browsingWord) { word in
            WordLookupView(browsing: word.w)
        }
        .alert(
            "Already being learned",
            isPresented: Binding(isPresent: $blockedLemma)
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("“\(blockedLemma ?? "")” is in your groups and already has learned progress — manage it from the word page instead.")
        }
    }

    // "Knew already" marks the one sense this list teaches; unmarking only
    // clears knew statuses so real learned progress survives a stray swipe.
    private func setKnown(_ word: ReadyWord, _ on: Bool) {
        let lemma = word.key
        if on {
            // Only a word that is BOTH in a group and already has learned
            // progress is off limits: that progress must be managed from the
            // word page, not overwritten by a swipe.
            let inGroup = context.first(
                matching: #Predicate<Word> { $0.lemma == lemma && $0.group != nil }) != nil
            let hasLearned = progressed.contains { $0.lemma == lemma && $0.learnStatus == .learned }
            if inGroup && hasLearned {
                blockedLemma = word.w
                return
            }
            guard let entry = boundSense(of: word, in: entriesByWord ?? [:], group: ready) else { return }
            let stats = SenseStats.findOrInsert(lemma: lemma, definition: entry.definition, in: context)
            if stats.learnStatus == .none {
                stats.markKnew(in: context)
            }
        } else {
            for stats in progressed where stats.lemma == lemma && stats.learnStatus == .knew {
                stats.clearStatusManually(in: context)
            }
        }
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
    // Parent's resolved plate texts: rows must not re-run sense resolution
    // on every selection tap.
    let definitions: [String: String]
    let onCreated: (WordGroup) -> Void

    private enum Destination: Hashable {
        case new
        case existing(WordGroup)
    }

    @State private var excluded: Set<String> = []
    @State private var groupName: String
    @State private var destination: Destination = .new
    @State private var isCreating = false

    @Query(filter: SenseStats.statusedPredicate) private var progressed: [SenseStats]
    @Query(sort: \WordGroup.createdAt, order: .reverse) private var allGroups: [WordGroup]

    init(ready: ReadyGroup,
         entriesByWord: [String: [DictionaryService.Entry]],
         definitions: [String: String],
         onCreated: @escaping (WordGroup) -> Void) {
        self.ready = ready
        self.entriesByWord = entriesByWord
        self.definitions = definitions
        self.onCreated = onCreated
        _groupName = State(initialValue: ready.name)
    }

    private var selectedCount: Int { ready.words.count - excluded.count }

    // Swiped "knew already" in the list: permanently out of the conversion.
    private var knownIDs: Set<String> {
        let progress = ReadyProgress(progressed)
        return Set(ready.words.filter { progress.isKnown($0.key) }.map { $0.id })
    }

    var body: some View {
        let knownIDs = knownIDs
        NavigationStack {
            List {
                Section("Add to") {
                    if !allGroups.isEmpty {
                        Picker("Destination", selection: $destination) {
                            Text("New group").tag(Destination.new)
                            ForEach(allGroups) { group in
                                Text(group.name).tag(Destination.existing(group))
                            }
                        }
                    }
                    if destination == .new {
                        TextField("name", text: $groupName)
                    }
                }
                .cardSurfaceRow()

                ForEach(Array(ready.words.enumerated()), id: \.element.id) { index, word in
                    let isKnown = knownIDs.contains(word.id)
                    let chosen = !excluded.contains(word.id)
                    Section {
                        Button {
                            excluded.toggle(word.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(word.w)
                                        .font(.headline)
                                        .foregroundStyle(isKnown ? Color.secondary : Color.primary)
                                    if let def = definitions[word.w] {
                                        Text(def)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isKnown)
                        .cardRow(color: chosen ? .accentColor : (isKnown ? .gray : nil))
                    } header: {
                        if index == 0 {
                            VStack(alignment: .leading, spacing: 4) {
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
                                Text("Tap the words you already know to leave them out.")
                                    .font(.footnote)
                                    .textCase(nil)
                            }
                        }
                    }
                }
            }
            .appScreen()
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
                    Button(destination == .new ? "Create" : "Add") { create() }
                        .disabled(selectedCount == 0
                                  || (destination == .new && groupName.isBlank))
                }
            }
        }
    }

    private func create() {
        guard !isCreating else { return }
        isCreating = true

        let target: WordGroup
        switch destination {
        case .new:
            target = WordGroup(name: groupName.trimmed, groupDescription: ready.description)
            target.sourceReadyGroupID = ready.id
            context.insert(target)
        case .existing(let group):
            target = group
        }

        var resolved = false
        let statusedKeys = SenseStats.statusKeys(progressed)
        for word in ready.words where !excluded.contains(word.id) {
            guard let entry = boundSense(of: word, in: entriesByWord, group: ready) else { continue }
            resolved = true
            target.findOrCreateWord(lemma: word.key, in: context)
                .appendSenses(entries: [entry], customs: [], in: context,
                              statusedKeys: statusedKeys)
        }

        // Every selected word can fail sense resolution (dictionary gaps):
        // never hand back an empty group, and don't jump cross-tab to a group
        // nothing was even attempted into.
        if case .new = destination, target.words.isEmpty {
            context.delete(target)
            dismiss()
            return
        }
        if resolved {
            onCreated(target)
        }
        dismiss()
    }
}
