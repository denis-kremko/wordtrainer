import SwiftUI
import SwiftData

struct GroupsListView: View {
    private enum Tab { case my, ready, dict }

    @Environment(\.modelContext) private var context
    @Query(sort: \WordGroup.createdAt, order: .reverse) private var groups: [WordGroup]
    @Query(filter: #Predicate<SenseStats> { $0.status != "" }) private var progressed: [SenseStats]

    @State private var tab: Tab = .my
    @State private var path = NavigationPath()
    @State private var showingNewGroup = false
    @State private var groupPendingDelete: WordGroup? = nil
    @State private var newGroupName = ""
    @State private var newGroupDesc = ""

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                Picker("Tab", selection: $tab) {
                    Text("My Groups").tag(Tab.my)
                    Text("Ready Groups").tag(Tab.ready)
                    Text("Dict").tag(Tab.dict)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 6)

                TabView(selection: $tab) {
                    myGroupsTab.tag(Tab.my)
                    ReadyThemesView().tag(Tab.ready)
                    WordLookupView().tag(Tab.dict)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            // Bar hidden, but the title still feeds the back button and its
            // long-press history menu on pushed screens (else the menu shows
            // an empty row).
            .navigationTitle("Groups")
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: WordGroup.self) { group in
                GroupDetailView(group: group)
            }
            .navigationDestination(for: ReadyTheme.self) { theme in
                ReadyThemeView(theme: theme)
            }
            .navigationDestination(for: ReadyGroup.self) { ready in
                ReadyGroupDetailView(ready: ready) { created in
                    tab = .my
                    path = NavigationPath([created])
                }
            }
            .sheet(isPresented: $showingNewGroup) { newGroupSheet }
            .alert(
                "Delete group?",
                isPresented: Binding(
                    get: { groupPendingDelete != nil },
                    set: { if !$0 { groupPendingDelete = nil } }
                ),
                presenting: groupPendingDelete
            ) { group in
                Button("Delete “\(group.name)”", role: .destructive) {
                    context.delete(group)
                    groupPendingDelete = nil
                }
                Button("Cancel", role: .cancel) { groupPendingDelete = nil }
            } message: { group in
                Text("This removes the group and all \(group.words.count) of its words. Quiz history is kept.")
            }
        }
    }

    private var myGroupsTab: some View {
        ZStack(alignment: .bottom) {
            Group {
                if groups.isEmpty {
                    ContentUnavailableView(
                        "No groups yet",
                        systemImage: "folder.badge.plus",
                        description: Text("Create your first word group or pick a ready-made one.")
                    )
                } else {
                    List {
                        ForEach(groups) { group in
                            let learned = learnedWordCount(in: group)
                            Section {
                                NavigationLink(value: group) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(group.name).font(.headline)
                                        HStack(spacing: 8) {
                                            Text("^[\(group.words.count) word](inflect: true)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            if !group.words.isEmpty {
                                                Text("•").foregroundStyle(.secondary)
                                                Text("\(learned)/\(group.words.count) learned")
                                                    .font(.caption)
                                                    .foregroundStyle(learned > 0 ? .green : .secondary)
                                            }
                                            if !group.groupDescription.isEmpty {
                                                Text("•").foregroundStyle(.secondary)
                                                Text(group.groupDescription)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                                .listRowBackground(RowGlow(
                                    color: !group.words.isEmpty && learned == group.words.count ? .green : nil))
                                .swipeActions {
                                    Button {
                                        groupPendingDelete = group
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .tint(.red)
                                }
                            }
                        }

                        ListBottomSpacer()
                    }
                    .listSectionSpacing(12)
                }
            }

            bottomCTA
        }
    }

    private var newGroupSheet: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. SAT vocab", text: $newGroupName)
                }
                Section("Description (optional)") {
                    TextField("what this group is for", text: $newGroupDesc, axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingNewGroup = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let g = WordGroup(
                            name: newGroupName.trimmingCharacters(in: .whitespacesAndNewlines),
                            groupDescription: newGroupDesc.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        context.insert(g)
                        // Reset the draft so the next "New group" starts blank
                        // (Cancel intentionally keeps it).
                        newGroupName = ""
                        newGroupDesc = ""
                        showingNewGroup = false
                    }
                    .disabled(newGroupName.isBlank)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var bottomCTA: some View {
        BottomCTA(title: "Create group", systemImage: "plus.circle.fill") {
            newGroupName = ""
            newGroupDesc = ""
            showingNewGroup = true
        }
    }

    // A word is learned when every sense it carries IN THIS GROUP has a status.
    private func learnedWordCount(in group: WordGroup) -> Int {
        let done = Set(progressed.map { $0.definition })
        return group.words.filter { word in
            !word.senses.isEmpty && word.senses.allSatisfy { done.contains($0.definition) }
        }.count
    }
}
