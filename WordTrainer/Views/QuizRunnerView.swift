import SwiftUI
import SwiftData

struct QuizRunnerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    let questions: [QuizQuestion]
    let mode: QuizMode
    let groupName: String

    @State private var index = 0
    @State private var userAnswer = ""
    @State private var revealed = false
    @State private var results: [QuizAnswer] = []

    var body: some View {
        Group {
            if questions.isEmpty {
                ContentUnavailableView(
                    "Nothing to test",
                    systemImage: "questionmark.folder",
                    description: Text("The selected mode has no valid questions. For example, “Translation → EN” needs at least one sense to have a translation.")
                )
            } else if index >= questions.count {
                QuizSummaryView(
                    results: results,
                    onSave: {
                        saveStats()
                        dismiss()
                    },
                    onDiscard: { dismiss() }
                )
            } else {
                questionView(questions[index])
            }
        }
        .navigationTitle("Quiz: \(mode.shortTitle)")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func questionView(_ q: QuizQuestion) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ProgressView(value: Double(index), total: Double(questions.count))

            VStack(alignment: .leading, spacing: 8) {
                Text(mode.promptLabel)
                    .font(.caption).foregroundStyle(.secondary)
                Text(q.prompt)
                    .font(.title2).bold()
                    .fixedSize(horizontal: false, vertical: true)
                if !q.hint.isEmpty {
                    Text(q.hint).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if mode == .enToTranslation {
                TextField("What does it mean? (for yourself)", text: $userAnswer, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
                    .disabled(revealed)

                if revealed {
                    answerCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Expected:")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(q.expectedAnswer).font(.body)
                        }
                    }

                    HStack {
                        Button {
                            recordSelfCheck(isCorrect: false, for: q)
                        } label: {
                            Label("Got it wrong", systemImage: "xmark.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)

                        Button {
                            recordSelfCheck(isCorrect: true, for: q)
                        } label: {
                            Label("Knew it", systemImage: "checkmark.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }
                } else {
                    Button("Show answer") { revealed = true }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                }
            } else {
                TextField("Your answer", text: $userAnswer)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(revealed)
                    .onSubmit { if !revealed { submit(q) } }

                if revealed {
                    let ok = results.last?.isCorrect ?? false
                    answerCard {
                        HStack {
                            Image(systemName: ok ? "checkmark.seal.fill" : "xmark.seal.fill")
                                .foregroundStyle(ok ? .green : .red)
                            Text(ok ? "Correct" : "Expected: \(q.expectedAnswer)")
                        }
                    }
                    Button("Next") { advance() }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                } else {
                    Button("Check") { submit(q) }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                        .disabled(userAnswer.isBlank)
                }
            }

            Spacer()
        }
        .padding()
    }

    private func answerCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding()
            .background(Color(.tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func submit(_ q: QuizQuestion) {
        let ok = QuizBuilder.isCorrect(userAnswer: userAnswer, expected: q.expectedAnswer)
        results.append(QuizAnswer(question: q, userAnswer: userAnswer, isCorrect: ok))
        revealed = true
    }

    private func recordSelfCheck(isCorrect: Bool, for q: QuizQuestion) {
        results.append(QuizAnswer(question: q, userAnswer: userAnswer, isCorrect: isCorrect))
        advance()
    }

    private func advance() {
        userAnswer = ""
        revealed = false
        index += 1
    }

    // Nothing is persisted during the run; stats are written only here, when the
    // user chooses to keep this quiz.
    private func saveStats() {
        let session = QuizSession(
            mode: mode.rawValue,
            groupName: groupName,
            totalCount: results.count,
            correctCount: results.filter { $0.isCorrect }.count
        )
        context.insert(session)
        for answer in results {
            let q = answer.question
            let result = QuizResult(
                lemma: q.lemma,
                senseDefinition: q.sense.definition,
                prompt: q.prompt,
                expected: q.expectedAnswer,
                userAnswer: answer.userAnswer,
                isCorrect: answer.isCorrect
            )
            context.insert(result)
            result.session = session
            let stats = SenseStats.findOrInsert(lemma: q.lemma, definition: q.sense.definition, in: context)
            stats.timesSeen += 1
            if answer.isCorrect { stats.timesCorrect += 1 }
        }
    }
}

struct QuizSummaryView: View {
    let results: [QuizAnswer]
    let onSave: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        let correct = results.filter { $0.isCorrect }.count
        let total = results.count

        VStack(spacing: 16) {
            Text("Done")
                .font(.largeTitle).bold()
            Text("\(correct) of \(total) correct")
                .font(.title2)
                .foregroundStyle(.secondary)

            List {
                ForEach(results.indices, id: \.self) { i in
                    let r = results[i]
                    HStack(alignment: .top) {
                        Image(systemName: r.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(r.isCorrect ? .green : .red)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(r.question.prompt).font(.subheadline).bold()
                            Text("Answer: \(r.question.expectedAnswer)")
                                .font(.caption).foregroundStyle(.secondary)
                            if !r.isCorrect, !r.userAnswer.isEmpty {
                                Text("You typed: \(r.userAnswer)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            VStack(spacing: 8) {
                BottomCTA(title: "Save to statistics", systemImage: "chart.bar.fill", action: onSave)

                Button("Don't save") { onDiscard() }
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom)
        }
        .padding(.top)
    }
}
