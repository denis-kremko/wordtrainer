import SwiftUI
import SwiftData

struct GroupDetailView: View {
    @Environment(\.modelContext) private var context
    @Bindable var group: WordGroup

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
                        ForEach(sortedWords) { word in
                            NavigationLink(value: word) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(word.lemma).font(.headline)
                                    let enabled = word.senses.lazy.filter { $0.isEnabled }.count
                                    Text("\(enabled) of \(word.senses.count) senses enabled")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
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
            Button {
                showingAddWord = true
            } label: {
                Label("Add word", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button {
                showingQuizConfig = true
            } label: {
                Label("Start quiz", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(group.words.isEmpty)
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
