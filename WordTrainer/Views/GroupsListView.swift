import SwiftUI
import SwiftData

struct GroupsListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \WordGroup.createdAt, order: .reverse) private var groups: [WordGroup]

    @State private var showingNewGroup = false
    @State private var newGroupName = ""
    @State private var newGroupDesc = ""

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Group {
                    if groups.isEmpty {
                        ContentUnavailableView(
                            "No groups yet",
                            systemImage: "folder.badge.plus",
                            description: Text("Create your first word group to start learning.")
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

                            Color.clear
                                .frame(height: 72)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    }
                }

                bottomCTA
            }
            .navigationTitle("Word Groups")
            .navigationDestination(for: WordGroup.self) { group in
                GroupDetailView(group: group)
            }
            .sheet(isPresented: $showingNewGroup) {
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
                                showingNewGroup = false
                            }
                            .disabled(newGroupName.isBlank)
                        }
                    }
                }
                .presentationDetents([.medium])
            }
        }
    }

    private var bottomCTA: some View {
        Button {
            newGroupName = ""
            newGroupDesc = ""
            showingNewGroup = true
        } label: {
            Label("Create group", systemImage: "plus.circle.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func delete(at offsets: IndexSet) {
        for i in offsets {
            context.delete(groups[i])
        }
    }
}
