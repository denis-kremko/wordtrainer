import SwiftUI
import SwiftData

struct QuizConfigSheet: View {
    @Environment(\.dismiss) private var dismiss
    let group: WordGroup

    @AppStorage("quizIncludeLearned") private var includeLearned = false
    @AppStorage("quizPromptMode") private var promptModeRaw = QuizMode.definitionToEn.rawValue
    @State private var sampleSize: Double = 10
    @State private var useAll: Bool = false
    @State private var startQuiz = false
    // Built once on Start: the navigationDestination closure re-runs on parent
    // re-renders and would silently reshuffle the quiz mid-session.
    @State private var questions: [QuizQuestion] = []

    @Query(filter: SenseStats.statusedPredicate) private var statused: [SenseStats]

    private var statusedKeys: Set<String> {
        SenseStats.statusKeys(statused)
    }

    private var promptMode: QuizMode {
        QuizMode(rawValue: promptModeRaw) ?? .definitionToEn
    }

    // Words QuizBuilder would actually accept. Cached in state: the full
    // walk must not re-run on every slider tick.
    @State private var eligible = 0

    private func refreshEligible() {
        let keys = statusedKeys
        let mode = promptMode
        eligible = group.words.filter { word in
            !word.quizCandidates(mode: mode, includeLearned: includeLearned,
                                 statused: keys).isEmpty
        }.count
        sampleSize = min(sampleSize, Double(max(eligible, 1)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Quiz by") {
                    HStack(spacing: 12) {
                        CapsuleButton(title: "Definitions",
                                      isOn: promptMode == .definitionToEn) {
                            promptModeRaw = QuizMode.definitionToEn.rawValue
                        }
                        CapsuleButton(title: "Translations",
                                      isOn: promptMode == .translationToEn) {
                            promptModeRaw = QuizMode.translationToEn.rawValue
                        }
                    }
                }
                .cardSurfaceRow()

                if eligible == 0 {
                    Section {
                        Text(promptMode == .translationToEn
                             ? "Nothing to quiz by translations: no sense in this group has one."
                             : "Nothing to quiz: every sense in this group is turned off or already learned.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .cardSurfaceRow()
                } else {
                    Section("How many words") {
                        CapsuleButton(title: "All words in group", isOn: useAll) {
                            useAll.toggle()
                        }
                        if !useAll && eligible > 1 {
                            VStack(alignment: .leading) {
                                Text("Random sample: \(Int(sampleSize)) of \(eligible)")
                                Slider(value: $sampleSize,
                                       in: 1...Double(eligible),
                                       step: 1)
                            }
                        } else if !useAll {
                            Text("There's only one quizzable word — it will be the whole quiz.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .cardSurfaceRow()
                }

                Section("Options") {
                    CapsuleButton(title: "Include learned words", isOn: includeLearned) {
                        includeLearned.toggle()
                    }
                    Text("Learned senses rejoin — win the gold medal!")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .cardSurfaceRow()
            }
            .appScreen()
            // initial: covers first presentation; the change side covers the
            // "Include learned words" toggle shrinking eligibility mid-sheet.
            .onChange(of: includeLearned, initial: true) { refreshEligible() }
            .onChange(of: promptModeRaw) { refreshEligible() }
            .navigationTitle("Quiz Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if eligible > 0 {
                    BottomCTA(title: "Start quiz", systemImage: "play.fill") {
                        let size: Int? = useAll ? nil : Int(sampleSize)
                        questions = QuizBuilder.build(from: group.words, sampleSize: size,
                                                      mode: promptMode,
                                                      includeLearned: includeLearned,
                                                      statusedKeys: statusedKeys)
                        startQuiz = true
                    }
                }
            }
            .navigationDestination(isPresented: $startQuiz) {
                QuizRunnerView(questions: questions, mode: promptMode,
                               groupName: group.name, groupID: group.id.uuidString,
                               onFinished: { dismiss() })
            }
        }
    }
}
