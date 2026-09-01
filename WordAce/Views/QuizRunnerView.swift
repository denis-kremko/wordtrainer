import SwiftUI
import SwiftData

struct QuizRunnerView: View {
    @Environment(\.modelContext) private var context

    let questions: [QuizQuestion]
    let mode: QuizMode
    let groupName: String
    let groupID: String
    // Closes the whole quiz cover: a plain dismiss() here would only pop back
    // to the setup form.
    let onFinished: () -> Void

    @State private var index = 0
    @State private var userAnswer = ""
    @State private var revealed = false
    @State private var finished = false
    @State private var results: [QuizAnswer] = []

    // Per-question downgrade state: boxes and hints trade points for help.
    @State private var usedBoxes = false
    @State private var typedLetters = ""
    @State private var hintedSlots: Set<Int> = []
    @State private var boxesWidth: CGFloat = 0
    @FocusState private var boxesFocused: Bool
    @FocusState private var answerFocused: Bool

    var body: some View {
        Group {
            if questions.isEmpty {
                ContentUnavailableView(
                    "Nothing to test",
                    systemImage: "questionmark.folder",
                    description: Text("No enabled senses to quiz in this group.")
                )
            } else if index >= questions.count {
                QuizSummaryView(
                    results: results,
                    onSave: {
                        guard !finished else { return }
                        finished = true
                        saveStats()
                        onFinished()
                    },
                    onDiscard: {
                        guard !finished else { return }
                        finished = true
                        onFinished()
                    }
                )
            } else {
                questionView(questions[index])
            }
        }
        .navigationTitle("Quiz")
        .navigationBarTitleDisplayMode(.inline)
        .appScreen()
        .onAppear { Keyboard.suppressTapDismiss = true }
        .onDisappear { Keyboard.suppressTapDismiss = false }
    }

    private func questionView(_ q: QuizQuestion) -> some View {
        let slots = AnswerSlots(q.expectedAnswer)
        return VStack(alignment: .leading, spacing: 16) {
            ProgressView(value: Double(index), total: Double(questions.count))

            VStack(alignment: .leading, spacing: 8) {
                Text(mode.promptLabel)
                    .font(.caption).foregroundStyle(.secondary)
                // Long definitions scroll inside the plate: with the keyboard
                // permanently up, the answer controls below must stay reachable.
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(q.prompt)
                            .font(.title2).bold()
                            .fixedSize(horizontal: false, vertical: true)
                        if !q.hint.isEmpty {
                            Text(q.hint).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if usedBoxes {
                letterBoxes(for: q, slots: slots)
            } else {
                TextField("Your answer", text: $userAnswer)
                    .font(.title2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.cardSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($answerFocused)
                    .onSubmit {
                        if !revealed && !userAnswer.isBlank {
                            submit(q, slots: slots)
                        } else if !revealed {
                            // Return must not kill the always-on quiz keyboard.
                            Task { answerFocused = true }
                        }
                    }
            }

            if revealed {
                let ok = results.last?.isCorrect ?? false
                HStack {
                    Image(systemName: ok ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .foregroundStyle(ok ? .green : .red)
                    Text(ok ? "Correct" : "Expected: \(q.expectedAnswer)")
                    if ok, let last = results.last, last.points > 0 {
                        Spacer()
                        Label {
                            Text("+\(last.points) pts")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                        }
                    }
                }
                .padding()
                .background(Color.cardSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                CapsuleButton(title: "Next", isLarge: true) { advance() }
            } else if usedBoxes {
                CapsuleButton(title: "Check",
                              isDisabled: !slots.isFilled(typed: typedLetters, hinted: hintedSlots),
                              isLarge: true) {
                    userAnswer = slots.composite(typed: typedLetters, hinted: hintedSlots)
                    submit(q, slots: slots)
                }
                hintOffer(for: slots)
            } else {
                CapsuleButton(title: "Check", isDisabled: userAnswer.isBlank, isLarge: true) {
                    submit(q, slots: slots)
                }
                // No letters, no boxes: an all-digit answer would soft-lock
                // the question (nothing to type, nothing to hint).
                if slots.letterCount > 0 {
                    CapsuleButton(title: "Letter boxes (−\(QuizBuilder.boxesCost))",
                                  systemImage: "square.grid.3x3",
                                  isOn: false, color: .orange, isLarge: true) {
                        usedBoxes = true
                        userAnswer = ""
                        typedLetters = ""
                        boxesFocused = true
                    }
                }
            }

        }
        .padding()
        .task(id: index) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            if usedBoxes { boxesFocused = true } else { answerFocused = true }
        }
    }

    // MARK: - Letter boxes

    @ViewBuilder
    private func hintOffer(for slots: AnswerSlots) -> some View {
        let current = QuizBuilder.points(isCorrect: true, usedBoxes: true,
                                         hintedLetters: hintedSlots.count,
                                         totalLetters: slots.letterCount)
        let next = QuizBuilder.points(isCorrect: true, usedBoxes: true,
                                      hintedLetters: hintedSlots.count + 1,
                                      totalLetters: slots.letterCount)
        CapsuleButton(title: "Hint (−\(current - next))", systemImage: "lightbulb.fill",
                      isOn: false, color: .orange,
                      isDisabled: hintedSlots.count >= slots.letterCount,
                      isLarge: true) {
            let available = Set(0..<slots.letterCount).subtracting(hintedSlots)
            guard let pick = available.randomElement() else { return }
            typedLetters = slots.typedAfterHint(typedLetters, revealing: pick, hinted: hintedSlots)
            hintedSlots.insert(pick)
        }
    }

    @ViewBuilder
    private func letterBoxes(for q: QuizQuestion, slots: AnswerSlots) -> some View {
        let filled = slots.filledCharacters(typed: typedLetters, hinted: hintedSlots)
        let width = fittedBoxWidth(for: slots)

        VStack(spacing: 14) {
            VStack(spacing: 8) {
                ForEach(slots.rows.indices, id: \.self) { rowIndex in
                    HStack(spacing: 5) {
                        ForEach(slots.rows[rowIndex], id: \.position) { slot in
                            if let letterIndex = slot.letterIndex {
                                letterBox(char: filled[letterIndex],
                                          isHint: hintedSlots.contains(letterIndex),
                                          width: width)
                            } else {
                                Text(String(slot.character))
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxesWidth = $0 }
            .contentShape(Rectangle())
            .onTapGesture { boxesFocused = true }
            .background(
                TextField("", text: $typedLetters)
                    .focused($boxesFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .opacity(0.02)
                    .frame(width: 1, height: 1)
                    .onSubmit {
                        guard !revealed else { return }
                        if slots.isFilled(typed: typedLetters, hinted: hintedSlots) {
                            userAnswer = slots.composite(typed: typedLetters, hinted: hintedSlots)
                            submit(q, slots: slots)
                        } else {
                            // Return must not kill the always-on quiz keyboard.
                            Task { boxesFocused = true }
                        }
                    }
            )
            .onChange(of: typedLetters) {
                let allowed = slots.letterCount - hintedSlots.count
                let cleaned = typedLetters.lowercased().straightApostrophes
                    .filter { $0.isLetter || $0 == "'" }
                typedLetters = String(cleaned.prefix(allowed))
            }

        }
    }

    // Boxes shrink to fit the longest word row on screen.
    private func fittedBoxWidth(for slots: AnswerSlots) -> CGFloat {
        let longest = slots.rows.map(\.count).max() ?? 1
        guard boxesWidth > 0, longest > 0 else { return 33 }
        let fit = (boxesWidth - 5 * CGFloat(longest - 1)) / CGFloat(longest)
        return max(14, min(33, fit))
    }

    private func letterBox(char: Character?, isHint: Bool, width: CGFloat) -> some View {
        Button {
            boxesFocused = true
        } label: {
            Text(char.map { String($0).uppercased() } ?? "")
                .font(.system(.title3, design: .monospaced).weight(.bold))
                .foregroundStyle(isHint ? Color.orange : Color.primary)
                .frame(width: width, height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.cardSurface)
                )
        }
        .buttonStyle(.plain)
    }


    private func submit(_ q: QuizQuestion, slots: AnswerSlots) {
        let ok = QuizBuilder.isCorrect(userAnswer: userAnswer, expected: q.expectedAnswer)
        let points = QuizBuilder.points(isCorrect: ok, usedBoxes: usedBoxes,
                                        hintedLetters: hintedSlots.count,
                                        totalLetters: usedBoxes ? slots.letterCount : 0)
        results.append(QuizAnswer(question: q, userAnswer: userAnswer, isCorrect: ok, points: points))
        revealed = true
    }

    private func advance() {
        userAnswer = ""
        usedBoxes = false
        typedLetters = ""
        hintedSlots = []
        revealed = false
        index += 1
        answerFocused = true
    }

    // Nothing is persisted during the run; stats are written only here, when the
    // user chooses to keep this quiz.
    private func saveStats() {
        let session = QuizSession(
            mode: mode.rawValue,
            groupName: groupName,
            groupID: groupID,
            totalCount: results.count,
            correctCount: results.filter { $0.isCorrect }.count,
            points: results.reduce(0) { $0 + $1.points }
        )
        context.insert(session)
        for (order, answer) in results.enumerated() {
            let q = answer.question
            let result = QuizResult(
                order: order,
                lemma: q.lemma,
                // The asked prompt: a translation-mode attempt must not
                // display definitions the user never saw.
                senseDefinition: q.prompt,
                userAnswer: answer.userAnswer,
                isCorrect: answer.isCorrect
            )
            context.insert(result)
            result.session = session
            let stats = SenseStats.findOrInsert(lemma: q.lemma, definition: q.sense.definition, in: context)
            stats.points += answer.points
            stats.applyAutoLearn(threshold: LearnSettings.pointsToLearn, in: context)
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
        let points = results.reduce(0) { $0 + $1.points }

        VStack(spacing: 16) {
            Text("Done")
                .font(.largeTitle).bold()
            Text("\(correct) of \(total) correct")
                .font(.title2)
                .foregroundStyle(.secondary)
            Label {
                Text("+\(points) pts")
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
            }
            .font(.headline)

            List {
                ForEach(results.indices, id: \.self) { i in
                    let r = results[i]
                    Section {
                        AnswerRow(isCorrect: r.isCorrect,
                                  title: r.question.prompt,
                                  subtitle: "Answer: \(r.question.expectedAnswer)",
                                  typed: r.userAnswer)
                    }
                }
            }

            VStack(spacing: 8) {
                BottomCTA(title: "Save to statistics", systemImage: "chart.bar.fill", action: onSave)

                CapsuleButton(title: "Don't save", isOn: false, color: .secondary) { onDiscard() }
                    .padding(.horizontal)
            }
            .padding(.bottom)
        }
        .padding(.top)
    }
}
