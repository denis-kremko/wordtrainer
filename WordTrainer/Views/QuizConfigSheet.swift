import SwiftUI
import SwiftData

struct QuizConfigSheet: View {
    @Environment(\.dismiss) private var dismiss
    let group: WordGroup

    @State private var mode: QuizMode = .definitionToEn
    @State private var sampleSize: Double = 10
    @State private var useAll: Bool = false
    @State private var startQuiz = false
    // Built once on Start: the navigationDestination closure re-runs on parent
    // re-renders and would silently reshuffle the quiz mid-session.
    @State private var questions: [QuizQuestion] = []

    var body: some View {
        let wordCount = group.words.count
        NavigationStack {
            Form {
                Section("Mode") {
                    Picker("Direction", selection: $mode) {
                        ForEach(QuizMode.allCases) { m in
                            Text(m.title).tag(m)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("How many words") {
                    Toggle("All words in group (\(wordCount))", isOn: $useAll)
                    if !useAll && wordCount > 1 {
                        VStack(alignment: .leading) {
                            Text("Random sample: \(Int(sampleSize)) of \(wordCount)")
                            Slider(value: $sampleSize,
                                   in: 1...Double(wordCount),
                                   step: 1)
                        }
                    } else if !useAll {
                        Text("There's only one word in this group — it will be the whole quiz.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onAppear {
                sampleSize = min(sampleSize, Double(max(wordCount, 1)))
            }
            .navigationTitle("Quiz Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        let size: Int? = useAll ? nil : Int(sampleSize)
                        questions = QuizBuilder.build(from: group.words, mode: mode, sampleSize: size)
                        startQuiz = true
                    }
                    .disabled(wordCount == 0)
                }
            }
            .navigationDestination(isPresented: $startQuiz) {
                QuizRunnerView(questions: questions, mode: mode,
                               groupName: group.name, groupID: group.id.uuidString)
            }
        }
        .presentationDetents([.medium])
    }
}
