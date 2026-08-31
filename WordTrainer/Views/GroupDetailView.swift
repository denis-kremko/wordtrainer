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
                    Section("Words (\(group.words.count))") {
                        let done = Set(progressed.map { $0.definition })
                        ForEach(sortedWords) { word in
                            let learned = !word.senses.isEmpty
                                && word.senses.allSatisfy { done.contains($0.definition) }
                            NavigationLink(value: word) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(word.lemma).font(.headline)
                                    let enabled = word.senses.lazy.filter { $0.isEnabled }.count
                                    Text("\(enabled) of \(word.senses.count) senses enabled")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .listRowBackground(ZStack {
                                Color(.secondarySystemGroupedBackground)
                                if learned {
                                    Color.green.opacity(0.12)
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(Color.green, lineWidth: 2)
                                        .padding(4)
                                }
                            })
                        }
                        .onDelete(perform: deleteWords)
                    }
                }

                Color.clear
                    .frame(height: 84)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

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

    private func deleteWords(at offsets: IndexSet) {
        let items = sortedWords
        for i in offsets {
            context.delete(items[i])
        }
    }
}
