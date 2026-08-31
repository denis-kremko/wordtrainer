import SwiftUI
import SwiftData

struct GroupDetailView: View {
    @Environment(\.modelContext) private var context
    @Bindable var group: WordGroup

    @Query(filter: #Predicate<SenseStats> { $0.status != "" }) private var progressed: [SenseStats]

    @State private var showingAddWord = false
    @State private var showingQuizConfig = false

    var body: some View {
        ZStack(alignment: .bottom) {
            List {
                if group.words.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No words yet",
                            systemImage: "text.book.closed",
                            description: Text("Tap Add word to add your first word. The app will pull its meanings from the offline dictionary.")
                        )
                    }
                } else {
                    let done = Set(progressed.map { $0.definition })
                    let learnedCount = group.words.filter { word in
                        !word.senses.isEmpty && word.senses.allSatisfy { done.contains($0.definition) }
                    }.count

                    Section {
                        let total = group.words.count
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Progress").font(.headline)
                                Spacer()
                                Text("\(learnedCount)/\(total) learned")
                                    .font(.subheadline)
                                    .foregroundStyle(learnedCount > 0 ? Color.green : Color.secondary)
                            }
                            ProgressView(value: Double(learnedCount), total: Double(max(total, 1)))
                                .tint(.green)
                        }
                        .listRowBackground(RowGlow(color: learnedCount == total ? .green : nil))
                    }

                    ForEach(Array(sortedWords.enumerated()), id: \.element.id) { index, word in
                        let learned = !word.senses.isEmpty
                            && word.senses.allSatisfy { done.contains($0.definition) }
                        Section {
                            NavigationLink(value: word) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(word.lemma).font(.headline)
                                    let total = word.senses.count
                                    let enabled = word.senses.lazy.filter { $0.isEnabled }.count
                                    let learnedSenses = word.senses.lazy.filter { done.contains($0.definition) }.count
                                    (Text("\(enabled)/\(total) senses enabled · ").foregroundStyle(Color.secondary)
                                        + Text("\(learnedSenses)/\(total) learned")
                                            .foregroundStyle(learnedSenses > 0 ? Color.green : Color.secondary))
                                        .font(.caption)
                                }
                            }
                            .listRowBackground(RowGlow(color: learned ? .green : nil))
                            .swipeActions {
                                Button(role: .destructive) {
                                    context.delete(word)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        } header: {
                            if index == 0 {
                                Text("Words")
                            }
                        }
                    }
                }

                Color.clear
                    .frame(height: 84)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listSectionSpacing(12)

            bottomCTAs
        }
        .navigationTitle(group.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    GroupStatsView(group: group)
                } label: {
                    Label("Stats", systemImage: "chart.bar.xaxis")
                }
            }
        }
        .navigationDestination(for: Word.self) { word in
            WordDetailView(word: word)
        }
        .sheet(isPresented: $showingAddWord) {
            WordLookupView(addingTo: group)
        }
        .sheet(isPresented: $showingQuizConfig) {
            QuizConfigSheet(group: group)
        }
    }

    private var bottomCTAs: some View {
        HStack(spacing: 12) {
            CapsuleButton(title: "Add word", systemImage: "plus.circle.fill",
                          isOn: false, isLarge: true) {
                showingAddWord = true
            }
            CapsuleButton(title: "Start quiz", systemImage: "play.fill",
                          isDisabled: group.words.isEmpty, isLarge: true) {
                showingQuizConfig = true
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var sortedWords: [Word] {
        group.words.sorted { $0.lemma.localizedCaseInsensitiveCompare($1.lemma) == .orderedAscending }
    }
}
