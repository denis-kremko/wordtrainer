import SwiftUI
import SwiftData

struct GroupsListView: View {
    private enum Tab { case my, ready, dict, profile }

    @Environment(\.modelContext) private var context
    // Prefetched words: the launch list reads counts from every group, and a
    // lazy to-many fault per group is an N+1 on the main thread.
    @Query(GroupsListView.groupsDescriptor) private var groups: [WordGroup]
    @Query(filter: SenseStats.statusedPredicate) private var progressed: [SenseStats]
    @Query private var allSessions: [QuizSession]

    @State private var tab: Tab = .my
    @State private var myPath = NavigationPath()
    @State private var showingNewGroup = false
    @State private var groupPendingDelete: WordGroup? = nil
    @State private var newGroupName = ""
    @State private var newGroupDesc = ""

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $myPath) {
                myGroupsTab
                    .navigationTitle("My Groups")
                    .navigationDestination(for: WordGroup.self) { group in
                        GroupDetailView(group: group)
                    }
                    .sheet(isPresented: $showingNewGroup) { newGroupSheet }
                    .alert(
                        "Delete group?",
                        isPresented: Binding(isPresent: $groupPendingDelete),
                        presenting: groupPendingDelete
                    ) { group in
                        Button("Delete “\(group.name)”", role: .destructive) {
                            group.deleteWithHistory(in: context)
                            groupPendingDelete = nil
                        }
                        Button("Cancel", role: .cancel) { groupPendingDelete = nil }
                    } message: { group in
                        Text("This removes the group, all \(group.words.count) of its words, and its quiz history.")
                    }
            }
            .tabItem { Label("My Groups", systemImage: "folder.fill") }
            .tag(Tab.my)

            NavigationStack {
                ReadyThemesView()
                    .navigationTitle("Library")
                    .navigationDestination(for: ReadyTheme.self) { theme in
                        ReadyThemeView(theme: theme)
                    }
                    .navigationDestination(for: ReadyGroup.self) { ready in
                        ReadyGroupDetailView(ready: ready) { created in
                            tab = .my
                            myPath = NavigationPath([created])
                        }
                    }
            }
            .tabItem { Label("Library", systemImage: "books.vertical.fill") }
            .tag(Tab.ready)

            NavigationStack {
                WordLookupView()
                    .navigationTitle("Dictionary")
            }
            .tabItem { Label("Dict", systemImage: "character.book.closed.fill") }
            .tag(Tab.dict)

            NavigationStack {
                ProfileView()
            }
            .tabItem { Label("Profile", systemImage: "person.crop.circle.fill") }
            .tag(Tab.profile)
        }
        .onChange(of: tab) { Keyboard.dismiss() }
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
                    let done = SenseStats.statusKeys(progressed)
                    let bestPoints = bestPointsByGroup
                    List {
                        ForEach(groups) { group in
                            let learned = group.words.filter { $0.isLearned(byStatused: done) }.count
                            let quizzable = group.words.filter { $0.isQuizzable(byStatused: done) }.count
                            Section {
                                CardLinkRow(value: group,
                                            color: !group.words.isEmpty && learned == group.words.count ? .green : nil) {
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
                                                    Text("•").foregroundStyle(.secondary)
                                                    MedalRow(bestPercent: Medal.percent(
                                                                points: bestPoints[group.id.uuidString] ?? 0,
                                                                wordCount: quizzable),
                                                             font: .caption2)
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
                                }
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
        .appScreen()
    }

    private var newGroupSheet: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. SAT vocab", text: $newGroupName)
                }
                .cardSurfaceRow()
                Section("Description (optional)") {
                    TextField("what this group is for", text: $newGroupDesc, axis: .vertical)
                        .lineLimit(1...4)
                }
                .cardSurfaceRow()
            }
            .listSectionSpacing(12)
            .appScreen()
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingNewGroup = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        guard showingNewGroup else { return }
                        let g = WordGroup(
                            name: newGroupName.trimmed,
                            groupDescription: newGroupDesc.trimmed
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

    // One pass over the whole history for the whole list: with a fixed
    // denominator the best attempt is simply the one with the most points.
    private var bestPointsByGroup: [String: Int] {
        allSessions.reduce(into: [:]) { best, session in
            best[session.groupID] = max(best[session.groupID] ?? 0, session.points)
        }
    }

    private static var groupsDescriptor: FetchDescriptor<WordGroup> {
        var descriptor = FetchDescriptor<WordGroup>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.relationshipKeyPathsForPrefetching = [\.words]
        return descriptor
    }

    private var bottomCTA: some View {
        BottomCTA(title: "Create group", systemImage: "plus.circle.fill") {
            newGroupName = ""
            newGroupDesc = ""
            showingNewGroup = true
        }
    }
}

private struct ProfileView: View {
    @Environment(\.modelContext) private var context
    @AppStorage(LearnSettings.pointsToLearnKey) private var pointsToLearn = LearnSettings.defaultPoints
    @Query(filter: SenseStats.statusedPredicate) private var progressed: [SenseStats]
    @Query(filter: #Predicate<SenseStats> { $0.points > 0 }) private var allPoints: [SenseStats]

    var body: some View {
            Form {
                Section("Stats") {
                    statTiles
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                Section("Settings") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Points to learn")
                        HStack(spacing: 8) {
                            ForEach(LearnSettings.pointsOptions, id: \.self) { value in
                                let selected = pointsToLearn == value
                                Button {
                                    pointsToLearn = value
                                } label: {
                                    Text("\(value)")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(selected ? Color.white : Color.primary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .background(selected ? Color.accentColor : Color.appBackground)
                                        .clipShape(Capsule())
                                        .overlay(
                                            Capsule().strokeBorder(Color.white.opacity(0.15),
                                                                   lineWidth: selected ? 0 : 1)
                                        )
                                        .overlay(alignment: .topTrailing) {
                                            if value == LearnSettings.defaultPoints {
                                                Image(systemName: "star.fill")
                                                    .font(.system(size: 13))
                                                    .foregroundStyle(.yellow)
                                                    .offset(x: 3, y: -5)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .animation(.spring(duration: 0.2), value: pointsToLearn)
                    }
                    Text("A sense is marked Learned when its points reach this. A plain-text answer earns \(QuizBuilder.maxPoints); switching to letter boxes costs \(QuizBuilder.boxesCost) and each hint eats a share of the rest. Changing this recomputes every studied word.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .cardSurfaceRow()
            }
            .listSectionSpacing(12)
            .appScreen()
            .navigationTitle("Profile")
            .onChange(of: pointsToLearn) {
                SenseStats.recomputeAutoLearned(threshold: pointsToLearn, in: context)
            }
    }

    private var statTiles: some View {
        HStack(spacing: 12) {
            StatTile(value: "\(progressed.filter { $0.learnStatus == .learned }.count)",
                     label: "senses learned", icon: "checkmark.seal.fill", tint: .green)
            StatTile(value: "\(allPoints.reduce(0) { $0 + $1.points })",
                     label: "total points", icon: "star.fill", tint: .yellow)
        }
    }
}
