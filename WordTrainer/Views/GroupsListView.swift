import SwiftUI
import SwiftData

struct GroupsListView: View {
    private enum Tab { case my, ready, dict }

    @Environment(\.modelContext) private var context
    @Query(sort: \WordGroup.createdAt, order: .reverse) private var groups: [WordGroup]

    @State private var tab: Tab = .my
    @State private var path = NavigationPath()
    @State private var showingNewGroup = false
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
                    ReadyGroupsListView().tag(Tab.ready)
                    WordLookupView().tag(Tab.dict)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: WordGroup.self) { group in
                GroupDetailView(group: group)
            }
            .navigationDestination(for: ReadyGroup.self) { ready in
                ReadyGroupDetailView(ready: ready) { created in
                    tab = .my
                    path = NavigationPath([created])
                }
            }
            .sheet(isPresented: $showingNewGroup) { newGroupSheet }
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
                            NavigationLink(value: group) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(group.name).font(.headline)
                                    HStack(spacing: 8) {
                                        Text("^[\(group.words.count) word](inflect: true)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
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
                        }
                        .onDelete(perform: delete)

                        ListBottomSpacer()
                    }
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

    private func delete(at offsets: IndexSet) {
        for i in offsets {
            context.delete(groups[i])
        }
    }
}
